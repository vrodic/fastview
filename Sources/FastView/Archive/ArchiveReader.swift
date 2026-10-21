import Foundation
import ZIPFoundation
import Unrar
#if os(macOS)
import Darwin
#endif

// MARK: - ZipArchiveCache

/// Keeps a small pool of open ZIPFoundation Archive handles so that the
/// central directory (located at the end of every ZIP file) is read from
/// disk only once per archive, regardless of how many individual entries are
/// subsequently extracted.
///
/// On a remote/network-backed disk each Archive init costs at least two
/// round-trips (backward seek to EOCD + forward seek + read of the central
/// directory).  Caching the handle reduces all thumbnail and full-image reads
/// for the same archive to a single seek + decompress per entry.
///
/// Thread-safety: all mutations are protected by `lock`.  ZIPFoundation's
/// Archive itself is not thread-safe, so callers must use `withArchive` which
/// serialises access through the same lock.
private final class ZipArchiveCache {
    static let shared = ZipArchiveCache()

    private struct CacheEntry {
        let archive: ZIPFoundation.Archive
        var lastUsed: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private let lock = NSLock()
    // Evict least-recently-used handle once we hold more than this many open.
    private let maxOpenArchives = 4

    /// Executes `block` with a cached (or freshly opened) Archive for
    /// `archivePath`.  Returns `nil` if the archive cannot be opened.
    func withArchive<T>(at archivePath: String, block: (ZIPFoundation.Archive) -> T?) -> T? {
        lock.lock()
        defer { lock.unlock() }

        if cache[archivePath] != nil {
            cache[archivePath]!.lastUsed = Date()
        } else {
            let url = URL(fileURLWithPath: archivePath)
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let archive = ZIPFoundation.Archive(data: data, accessMode: .read) else {
                return nil
            }
            evictIfNeeded()
            cache[archivePath] = CacheEntry(archive: archive, lastUsed: Date())
        }

        return block(cache[archivePath]!.archive)
    }

    /// Removes the cached handle for `archivePath`, forcing the next call to
    /// re-open the file.  Call this if the underlying file may have changed.
    func invalidate(archivePath: String) {
        lock.lock()
        cache.removeValue(forKey: archivePath)
        lock.unlock()
    }

    func invalidateAll() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    private func evictIfNeeded() {
        // lock is already held by the caller
        while cache.count >= maxOpenArchives {
            guard let lruKey = cache.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key else { break }
            cache.removeValue(forKey: lruKey)
        }
    }
}

// MARK: - RarArchiveCache

/// Caches open Unrar.Archive handles and parsed entry lists to prevent repeated
/// disk opens and full header scans on every thumbnail and full-image extraction.
/// Uses Darwin kernel advisories (F_READAHEAD, F_RDADVISE) to maximize disk I/O throughput.
private final class RarArchiveCache {
    static let shared = RarArchiveCache()

    private struct CacheEntry {
        let archive: Unrar.Archive
        let entries: [Unrar.Entry]
        var lastUsed: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private let lock = NSLock()
    private let maxOpenArchives = 4

    private func enableKernelReadAhead(for archivePath: String) {
        #if os(macOS)
        let url = URL(fileURLWithPath: archivePath).standardized
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        let fd = handle.fileDescriptor
        let fReadAheadCmd: Int32 = 45
        let fRdAdviseCmd: Int32 = 44

        _ = fcntl(fd, fReadAheadCmd, 1)

        if let attrs = try? FileManager.default.attributesOfItem(atPath: archivePath),
           let fileSize = attrs[.size] as? Int64, fileSize > 0 {
            let prefetchSize = min(fileSize, 256 * 1024 * 1024)
            var radv = radvisory(ra_offset: 0, ra_count: Int32(min(prefetchSize, Int64(Int32.max))))
            _ = fcntl(fd, fRdAdviseCmd, &radv)
        }
        #endif
    }

    func withArchive<T>(at archivePath: String, block: (Unrar.Archive, [Unrar.Entry]) -> T?) -> T? {
        lock.lock()
        defer { lock.unlock() }

        if let existing = cache[archivePath] {
            cache[archivePath]!.lastUsed = Date()
            return block(existing.archive, existing.entries)
        } else {
            enableKernelReadAhead(for: archivePath)
            let url = URL(fileURLWithPath: archivePath).standardized
            guard let archive = try? Unrar.Archive(fileURL: url),
                  let entries = try? archive.entries() else {
                return nil
            }
            evictIfNeeded()
            cache[archivePath] = CacheEntry(archive: archive, entries: entries, lastUsed: Date())
            return block(archive, entries)
        }
    }

    func invalidate(archivePath: String) {
        lock.lock()
        cache.removeValue(forKey: archivePath)
        lock.unlock()
    }

    func invalidateAll() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    private func evictIfNeeded() {
        while cache.count >= maxOpenArchives {
            guard let lruKey = cache.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key else { break }
            cache.removeValue(forKey: lruKey)
        }
    }
}

public enum FileType: Equatable {
    case image
    case archiveZip
    case archiveRar
    case directory
    case parentDirectory
    case unsupported
}

public struct FileItem: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let path: String
    public let type: FileType
    public let archivePath: String?
    public let isDirectory: Bool
    public let fileSize: UInt64
    public let entryParentDir: String? // Parent relative folder path inside an archive

    public init(id: String, name: String, path: String, type: FileType, archivePath: String? = nil, isDirectory: Bool = false, fileSize: UInt64 = 0, entryParentDir: String? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.type = type
        self.archivePath = archivePath
        self.isDirectory = isDirectory
        self.fileSize = fileSize
        self.entryParentDir = entryParentDir
    }

    public static func parentItem(for path: String) -> FileItem {
        return FileItem(
            id: "..",
            name: "(..)",
            path: (path as NSString).deletingLastPathComponent,
            type: .parentDirectory,
            isDirectory: true
        )
    }
}

public class ArchiveReader {
    public static var archiveBufferSize: Int = 4 * 1024 * 1024

    public static let supportedImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp", "ico"
    ]

    public static let supportedArchiveExtensions: Set<String> = [
        "zip", "rar"
    ]

    public static func fileType(for url: URL) -> FileType {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return .directory
        }

        let ext = url.pathExtension.lowercased()
        if supportedImageExtensions.contains(ext) {
            return .image
        } else if ext == "zip" {
            return .archiveZip
        } else if ext == "rar" {
            return .archiveRar
        }
        return .unsupported
    }

    public static func isImageExtension(_ ext: String) -> Bool {
        return supportedImageExtensions.contains(ext.lowercased())
    }

    public static func isArchiveExtension(_ ext: String) -> Bool {
        return supportedArchiveExtensions.contains(ext.lowercased())
    }

    public static func loadZipData(archivePath: String, entryPath: String, isCancelled: (() -> Bool)? = nil) -> Data? {
        let startTime = CFAbsoluteTimeGetCurrent()
        FileLogger.shared.log("READ_ZIP_ENTRY_START", path: "\(archivePath) -> \(entryPath)")

        let result = ZipArchiveCache.shared.withArchive(at: archivePath) { archive -> Data? in
            guard let entry = archive[entryPath] else { return nil }

            var data = Data()
            var aborted = false

            _ = try? archive.extract(entry, bufferSize: ArchiveReader.archiveBufferSize, consumer: { chunk in
                if isCancelled?() == true {
                    aborted = true
                    struct ZipCancelledError: Error {}
                    throw ZipCancelledError()
                }
                data.append(chunk)
            })

            if aborted {
                FileLogger.shared.log("READ_ZIP_ENTRY_CANCELLED", path: "\(archivePath) -> \(entryPath)")
                return nil
            }
            return data
        }

        guard let data = result else { return nil }
        let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        FileLogger.shared.log("READ_ZIP_ENTRY_END", path: "\(archivePath) -> \(entryPath)", durationMs: duration)
        return data
    }

    public static func loadRarData(archivePath: String, entryPath: String, isCancelled: (() -> Bool)? = nil) -> Data? {
        if isCancelled?() == true { return nil }
        let startTime = CFAbsoluteTimeGetCurrent()
        FileLogger.shared.log("READ_RAR_ENTRY_START", path: "\(archivePath) -> \(entryPath)")

        let result = RarArchiveCache.shared.withArchive(at: archivePath) { archive, entries -> Data? in
            if isCancelled?() == true { return nil }

            let normEntryPath = entryPath.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let entry = entries.first(where: {
                let norm = $0.fileName.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return norm == normEntryPath || norm.hasSuffix("/" + normEntryPath) || normEntryPath.hasSuffix("/" + norm)
            }) ?? entries.first(where: {
                ($0.fileName as NSString).lastPathComponent == (entryPath as NSString).lastPathComponent
            }) else {
                return nil
            }

            return try? archive.extract(entry)
        }

        guard let data = result else { return nil }
        let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        FileLogger.shared.log("READ_RAR_ENTRY_END", path: "\(archivePath) -> \(entryPath)", durationMs: duration)
        return data
    }

    public static func listZipContents(archivePath: String, subfolder: String = "", isCancelled: (() -> Bool)? = nil) -> [FileItem] {
        let cacheKey = "zip_\(archivePath)_\(subfolder)"
        if let cached = DirectoryCache.shared.get(key: cacheKey) {
            return cached
        }

        if isCancelled?() == true { return [] }

        let startTime = CFAbsoluteTimeGetCurrent()
        FileLogger.shared.log("LIST_ZIP_START", path: archivePath)

        let cleanSubfolder = subfolder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = cleanSubfolder.isEmpty ? "" : cleanSubfolder + "/"

        var items: [FileItem] = []

        let ok = ZipArchiveCache.shared.withArchive(at: archivePath) { archive -> Bool in
            var seenFolders = Set<String>()

            for entry in archive {
                if isCancelled?() == true {
                    FileLogger.shared.log("LIST_ZIP_CANCELLED", path: archivePath)
                    return false
                }

                let path = entry.path
                guard path != cleanSubfolder && path != cleanSubfolder + "/" else { continue }

                if !prefix.isEmpty && !path.hasPrefix(prefix) {
                    continue
                }

                let relativePath = prefix.isEmpty ? path : String(path.dropFirst(prefix.count))
                let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)

                guard let firstComponent = components.first else { continue }

                let itemName = String(firstComponent)
                let isSubDir = components.count > 1 || entry.type == .directory

                if isSubDir {
                    if !seenFolders.contains(itemName) {
                        seenFolders.insert(itemName)
                        let fullVirtualPath = prefix + itemName
                        items.append(FileItem(
                            id: fullVirtualPath,
                            name: itemName,
                            path: fullVirtualPath,
                            type: .directory,
                            archivePath: archivePath,
                            isDirectory: true
                        ))
                    }
                } else {
                    let ext = (itemName as NSString).pathExtension.lowercased()
                    if isImageExtension(ext) {
                        let innerParent = (path as NSString).deletingLastPathComponent
                        items.append(FileItem(
                            id: path,
                            name: itemName,
                            path: path,
                            type: .image,
                            archivePath: archivePath,
                            isDirectory: false,
                            fileSize: UInt64(entry.uncompressedSize),
                            entryParentDir: innerParent
                        ))
                    }
                }
            }
            return true
        } ?? false

        if !ok { return [] }

        if items.count == 1 && items[0].isDirectory {
            let all = listAllZipImages(archivePath: archivePath, isCancelled: isCancelled)
            if isCancelled?() == true { return [] }
            DirectoryCache.shared.set(key: cacheKey, items: all)
            let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            FileLogger.shared.log("LIST_ZIP_END", path: archivePath, durationMs: duration)
            return all
        }

        let sorted = sortItems(items)
        if isCancelled?() != true {
            DirectoryCache.shared.set(key: cacheKey, items: sorted)
        }
        let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        FileLogger.shared.log("LIST_ZIP_END", path: archivePath, durationMs: duration)
        return sorted
    }

    public static func listAllZipImages(archivePath: String, isCancelled: (() -> Bool)? = nil) -> [FileItem] {
        let cacheKey = "zip_all_\(archivePath)"
        if let cached = DirectoryCache.shared.get(key: cacheKey) {
            return cached
        }

        if isCancelled?() == true { return [] }

        var items: [FileItem] = []

        let ok = ZipArchiveCache.shared.withArchive(at: archivePath) { archive -> Bool in
            for entry in archive {
                if isCancelled?() == true { return false }
                guard entry.type == .file else { continue }
                let path = entry.path
                let ext = (path as NSString).pathExtension.lowercased()
                if isImageExtension(ext) {
                    let name = (path as NSString).lastPathComponent
                    let innerParent = (path as NSString).deletingLastPathComponent
                    items.append(FileItem(
                        id: path,
                        name: name,
                        path: path,
                        type: .image,
                        archivePath: archivePath,
                        isDirectory: false,
                        fileSize: UInt64(entry.uncompressedSize),
                        entryParentDir: innerParent
                    ))
                }
            }
            return true
        } ?? false

        if !ok { return [] }

        let sorted = sortItems(items)
        if isCancelled?() != true {
            DirectoryCache.shared.set(key: cacheKey, items: sorted)
        }
        return sorted
    }

    public static func listRarContents(archivePath: String, subfolder: String = "", isCancelled: (() -> Bool)? = nil) -> [FileItem] {
        let cacheKey = "rar_\(archivePath)_\(subfolder)"
        if let cached = DirectoryCache.shared.get(key: cacheKey) {
            return cached
        }

        if isCancelled?() == true { return [] }

        let startTime = CFAbsoluteTimeGetCurrent()
        FileLogger.shared.log("LIST_RAR_START", path: archivePath)

        let cleanSubfolder = subfolder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = cleanSubfolder.isEmpty ? "" : cleanSubfolder + "/"

        let result = RarArchiveCache.shared.withArchive(at: archivePath) { archive, entries -> [FileItem]? in
            var seenFolders = Set<String>()
            var list: [FileItem] = []

            for entry in entries {
                if isCancelled?() == true { return nil }

                let path = entry.fileName.replacingOccurrences(of: "\\", with: "/")
                guard !path.isEmpty && path != cleanSubfolder && path != cleanSubfolder + "/" else { continue }

                if !prefix.isEmpty && !path.hasPrefix(prefix) {
                    continue
                }

                let relativePath = prefix.isEmpty ? path : String(path.dropFirst(prefix.count))
                let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)

                guard let firstComponent = components.first else { continue }
                let itemName = String(firstComponent)
                let isSubDir = components.count > 1 || entry.directory

                if isSubDir {
                    if !seenFolders.contains(itemName) {
                        seenFolders.insert(itemName)
                        let fullVirtualPath = prefix + itemName
                        list.append(FileItem(
                            id: fullVirtualPath,
                            name: itemName,
                            path: fullVirtualPath,
                            type: .directory,
                            archivePath: archivePath,
                            isDirectory: true
                        ))
                    }
                } else {
                    let ext = (itemName as NSString).pathExtension.lowercased()
                    if isImageExtension(ext) {
                        let innerParent = (path as NSString).deletingLastPathComponent
                        list.append(FileItem(
                            id: path,
                            name: itemName,
                            path: path,
                            type: .image,
                            archivePath: archivePath,
                            isDirectory: false,
                            fileSize: entry.uncompressedSize,
                            entryParentDir: innerParent
                        ))
                    }
                }
            }
            return list
        }

        guard let finalItems = result else { return [] }

        if finalItems.isEmpty || (finalItems.count == 1 && finalItems[0].isDirectory) {
            let all = listAllRarImages(archivePath: archivePath, isCancelled: isCancelled)
            if isCancelled?() == true { return [] }
            if !all.isEmpty {
                DirectoryCache.shared.set(key: cacheKey, items: all)
                let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
                FileLogger.shared.log("LIST_RAR_END", path: archivePath, durationMs: duration)
                return all
            }
        }

        let sorted = sortItems(finalItems)
        if isCancelled?() != true {
            DirectoryCache.shared.set(key: cacheKey, items: sorted)
        }
        let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        FileLogger.shared.log("LIST_RAR_END", path: archivePath, durationMs: duration)
        return sorted
    }

    public static func listAllRarImages(archivePath: String, isCancelled: (() -> Bool)? = nil) -> [FileItem] {
        let cacheKey = "rar_all_\(archivePath)"
        if let cached = DirectoryCache.shared.get(key: cacheKey) {
            return cached
        }

        if isCancelled?() == true { return [] }

        let result = RarArchiveCache.shared.withArchive(at: archivePath) { archive, entries -> [FileItem]? in
            var list: [FileItem] = []

            for entry in entries {
                if isCancelled?() == true { return nil }
                if entry.directory { continue }

                let path = entry.fileName.replacingOccurrences(of: "\\", with: "/")
                let ext = (path as NSString).pathExtension.lowercased()
                if isImageExtension(ext) {
                    let name = (path as NSString).lastPathComponent
                    let innerParent = (path as NSString).deletingLastPathComponent
                    list.append(FileItem(
                        id: path,
                        name: name,
                        path: path,
                        type: .image,
                        archivePath: archivePath,
                        isDirectory: false,
                        fileSize: entry.uncompressedSize,
                        entryParentDir: innerParent
                    ))
                }
            }
            return list
        }

        guard let items = result else { return [] }

        let sorted = sortItems(items)
        if isCancelled?() != true {
            DirectoryCache.shared.set(key: cacheKey, items: sorted)
        }
        return sorted
    }

    public static func sortItems(_ items: [FileItem]) -> [FileItem] {
        return items.sorted { a, b in
            let aIsFolder = a.isDirectory || a.type == .archiveZip || a.type == .archiveRar
            let bIsFolder = b.isDirectory || b.type == .archiveZip || b.type == .archiveRar

            if aIsFolder != bIsFolder {
                return aIsFolder && !bIsFolder
            }

            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
