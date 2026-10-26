import Foundation
import CoreGraphics
import FastViewArchiveCore
#if os(macOS)
import Darwin
#endif

// MARK: - Load progress

/// Real progress of a long-running archive or file operation, measured from
/// the I/O loop itself (bytes read/decompressed or archive entries scanned).
public struct LoadProgress {
    public enum Unit {
        case bytes
        case entries
    }

    public let completed: Int64
    public let total: Int64
    public let unit: Unit

    public var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

/// Invoked from the background I/O thread; callers hop to the main queue.
public typealias LoadProgressHandler = (LoadProgress) -> Void

/// Rate-limits progress callbacks coming from tight per-chunk / per-entry
/// loops so at most ~30 updates per second reach the handler.  The final
/// update (completed == total) is always delivered.
final class ProgressThrottle {
    private let handler: LoadProgressHandler
    private let unit: LoadProgress.Unit
    private let minInterval: CFAbsoluteTime = 1.0 / 30.0
    private var lastReportTime: CFAbsoluteTime = 0

    init(_ handler: @escaping LoadProgressHandler, unit: LoadProgress.Unit) {
        self.handler = handler
        self.unit = unit
    }

    func report(_ completed: Int64, of total: Int64) {
        guard total > 0 else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard completed >= total || now - lastReportTime >= minInterval else { return }
        lastReportTime = now
        handler(LoadProgress(completed: min(completed, total), total: total, unit: unit))
    }
}

// MARK: - ArchiveIndexCache

/// Entry lists of recently listed archives.  The archives themselves stay in
/// the FastViewReader helper (see `ArchiveHelper`); FastView only keeps this
/// metadata, so listing a subfolder or matching an entry path needs no
/// request.
///
/// Thread-safety: all access goes through `withEntries`, serialised by `lock`.
private final class ArchiveIndexCache {
    static let shared = ArchiveIndexCache()

    private struct CacheEntry {
        let entries: [ArchiveEntryRecord]
        var lastUsed: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private let lock = NSLock()
    private let maxArchives = 64

    /// Executes `block` with the entry list of `archivePath`, asking the
    /// helper for it on a cache miss (with progress).  Returns `nil` if the
    /// archive cannot be listed or listing was cancelled.
    func withEntries<T>(at archivePath: String, kind: ArchiveRequest.Kind,
                        progress: LoadProgressHandler? = nil,
                        isCancelled: (() -> Bool)? = nil,
                        block: (_ entries: [ArchiveEntryRecord]) -> T?) -> T? {
        lock.lock()
        defer { lock.unlock() }

        if cache[archivePath] != nil {
            cache[archivePath]!.lastUsed = Date()
        } else {
            guard let entries = ArchiveHelper.shared.list(archivePath: archivePath, kind: kind,
                                                          progress: progress, isCancelled: isCancelled) else { return nil }
            while cache.count >= maxArchives,
                  let lruKey = cache.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
                cache.removeValue(forKey: lruKey)
            }
            cache[archivePath] = CacheEntry(entries: entries, lastUsed: Date())
        }
        return block(cache[archivePath]!.entries)
    }

    func contains(_ archivePath: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cache[archivePath] != nil
    }

    func store(_ entries: [ArchiveEntryRecord], for archivePath: String) {
        lock.lock()
        defer { lock.unlock() }
        cache[archivePath] = CacheEntry(entries: entries, lastUsed: Date())
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

    public static let supportedImageExtensions: Set<String> = ArchivePreview.imageExtensions

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

    /// `progress` reports a slow first read of the archive (e.g. a large
    /// archive opened at launch); extracting from an open archive is quick.
    public static func loadZipData(archivePath: String, entryPath: String, progress: LoadProgressHandler? = nil, isCancelled: (() -> Bool)? = nil) -> Data? {
        let startTime = CFAbsoluteTimeGetCurrent()
        FileLogger.shared.log("READ_ZIP_ENTRY_START", path: "\(archivePath) -> \(entryPath)")

        let result = ArchiveIndexCache.shared.withEntries(at: archivePath, kind: .zip, progress: progress, isCancelled: isCancelled) { entries -> Data? in
            let normEntryPath = entryPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let entry = entries.first(where: { $0.path == entryPath })
                    ?? entries.first(where: { $0.path == normEntryPath })
                    ?? entries.first(where: {
                        let p = $0.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        return p == normEntryPath || p.hasSuffix("/" + normEntryPath) || normEntryPath.hasSuffix("/" + p)
                    }) else { return nil }

            return ArchiveHelper.shared.extract(archivePath: archivePath, kind: .zip, entryPath: entry.path,
                                                entrySize: entry.uncompressedSize, progress: progress, isCancelled: isCancelled)
        }

        guard let data = result else { return nil }
        let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        FileLogger.shared.log("READ_ZIP_ENTRY_END", path: "\(archivePath) -> \(entryPath)", durationMs: duration)
        return data
    }

    public static func loadRarData(archivePath: String, entryPath: String, progress: LoadProgressHandler? = nil, isCancelled: (() -> Bool)? = nil) -> Data? {
        if isCancelled?() == true { return nil }
        let startTime = CFAbsoluteTimeGetCurrent()
        FileLogger.shared.log("READ_RAR_ENTRY_START", path: "\(archivePath) -> \(entryPath)")

        let result = ArchiveIndexCache.shared.withEntries(at: archivePath, kind: .rar, progress: progress, isCancelled: isCancelled) { entries -> Data? in
            if isCancelled?() == true { return nil }

            let normEntryPath = entryPath.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let entry = entries.first(where: {
                let norm = $0.path.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return norm == normEntryPath || norm.hasSuffix("/" + normEntryPath) || normEntryPath.hasSuffix("/" + norm)
            }) ?? entries.first(where: {
                ($0.path as NSString).lastPathComponent == (entryPath as NSString).lastPathComponent
            }) else {
                return nil
            }

            return ArchiveHelper.shared.extract(archivePath: archivePath, kind: .rar, entryPath: entry.path,
                                                entrySize: entry.uncompressedSize, progress: progress, isCancelled: isCancelled)
        }

        guard let data = result else { return nil }
        let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        FileLogger.shared.log("READ_RAR_ENTRY_END", path: "\(archivePath) -> \(entryPath)", durationMs: duration)
        return data
    }

    /// The preview image of an archive and, if not cached yet, its entry list
    /// (so the image count that follows needs no request), from a single
    /// helper request.  A thumbnail when `maxPixelSize` is set, else the
    /// image file.  `nil` if the archive cannot be read or the request was
    /// cancelled; an empty result if it has no images.
    public static func loadArchivePreview(archivePath: String, type: FileType, maxPixelSize: Int?,
                                          progress: LoadProgressHandler? = nil,
                                          isCancelled: (() -> Bool)? = nil) -> (thumbnail: CGImage?, imageData: Data?)? {
        guard type == .archiveZip || type == .archiveRar else { return nil }
        let startTime = CFAbsoluteTimeGetCurrent()
        let needsEntries = !ArchiveIndexCache.shared.contains(archivePath)

        guard let preview = ArchiveHelper.shared.preview(archivePath: archivePath, kind: type == .archiveZip ? .zip : .rar,
                                                         maxPixelSize: maxPixelSize, includeEntries: needsEntries,
                                                         progress: progress, isCancelled: isCancelled) else { return nil }
        if let entries = preview.entries {
            ArchiveIndexCache.shared.store(entries, for: archivePath)
        }
        FileLogger.shared.log("ARCHIVE_PREVIEW_END", path: archivePath, durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0)
        return (preview.thumbnail, preview.imageData)
    }

    public static var flattenArchiveDirectories: Bool {
        get {
            return UserDefaults.standard.bool(forKey: "FastViewFlattenArchiveDirectories")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "FastViewFlattenArchiveDirectories")
        }
    }

    public static func listZipContents(archivePath: String, subfolder: String = "", progress: LoadProgressHandler? = nil, isCancelled: (() -> Bool)? = nil) -> [FileItem] {
        let cacheKey = "zip_\(archivePath)_\(subfolder)"
        if let cached = DirectoryCache.shared.get(key: cacheKey) {
            return cached
        }

        if flattenArchiveDirectories {
            return listAllZipImages(archivePath: archivePath, progress: progress, isCancelled: isCancelled)
        }

        if isCancelled?() == true { return [] }

        let startTime = CFAbsoluteTimeGetCurrent()
        FileLogger.shared.log("LIST_ZIP_START", path: archivePath)

        let cleanSubfolder = subfolder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = cleanSubfolder.isEmpty ? "" : cleanSubfolder + "/"

        var items: [FileItem] = []

        let ok = ArchiveIndexCache.shared.withEntries(at: archivePath, kind: .zip, progress: progress, isCancelled: isCancelled) { entries -> Bool in
            var seenFolders = Set<String>()

            for entry in entries {
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
                let isSubDir = components.count > 1 || entry.kind == .directory

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
                            fileSize: entry.uncompressedSize,
                            entryParentDir: innerParent
                        ))
                    }
                }
            }
            return true
        } ?? false

        if !ok { return [] }


        let sorted = sortItems(items)
        if isCancelled?() != true {
            DirectoryCache.shared.set(key: cacheKey, items: sorted)
        }
        let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        FileLogger.shared.log("LIST_ZIP_END", path: archivePath, durationMs: duration)
        return sorted
    }

    public static func listAllZipImages(archivePath: String, progress: LoadProgressHandler? = nil, isCancelled: (() -> Bool)? = nil) -> [FileItem] {
        let cacheKey = "zip_all_\(archivePath)"
        if let cached = DirectoryCache.shared.get(key: cacheKey) {
            return cached
        }

        if isCancelled?() == true { return [] }

        let startTime = CFAbsoluteTimeGetCurrent()
        FileLogger.shared.log("LIST_ZIP_IMAGES_START", path: archivePath)

        var items: [FileItem] = []

        let ok = ArchiveIndexCache.shared.withEntries(at: archivePath, kind: .zip, progress: progress, isCancelled: isCancelled) { entries -> Bool in
            for entry in entries {
                if isCancelled?() == true { return false }
                guard entry.kind == .file else { continue }
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
                        fileSize: entry.uncompressedSize,
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
        let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        FileLogger.shared.log("LIST_ZIP_IMAGES_END", path: archivePath, durationMs: duration)
        return sorted
    }

    public static func listRarContents(archivePath: String, subfolder: String = "", progress: LoadProgressHandler? = nil, isCancelled: (() -> Bool)? = nil) -> [FileItem] {
        let cacheKey = "rar_\(archivePath)_\(subfolder)"
        if let cached = DirectoryCache.shared.get(key: cacheKey) {
            return cached
        }

        if flattenArchiveDirectories {
            return listAllRarImages(archivePath: archivePath, progress: progress, isCancelled: isCancelled)
        }

        if isCancelled?() == true { return [] }

        let startTime = CFAbsoluteTimeGetCurrent()
        FileLogger.shared.log("LIST_RAR_START", path: archivePath)

        let cleanSubfolder = subfolder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = cleanSubfolder.isEmpty ? "" : cleanSubfolder + "/"

        let result = ArchiveIndexCache.shared.withEntries(at: archivePath, kind: .rar, progress: progress, isCancelled: isCancelled) { entries -> [FileItem]? in
            var seenFolders = Set<String>()
            var list: [FileItem] = []

            for entry in entries {
                if isCancelled?() == true { return nil }

                let path = entry.path.replacingOccurrences(of: "\\", with: "/")
                guard !path.isEmpty && path != cleanSubfolder && path != cleanSubfolder + "/" else { continue }

                if !prefix.isEmpty && !path.hasPrefix(prefix) {
                    continue
                }

                let relativePath = prefix.isEmpty ? path : String(path.dropFirst(prefix.count))
                let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)

                guard let firstComponent = components.first else { continue }
                let itemName = String(firstComponent)
                let isSubDir = components.count > 1 || entry.kind == .directory

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

        if finalItems.isEmpty && cleanSubfolder.isEmpty {
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

    public static func listAllRarImages(archivePath: String, progress: LoadProgressHandler? = nil, isCancelled: (() -> Bool)? = nil) -> [FileItem] {
        let cacheKey = "rar_all_\(archivePath)"
        if let cached = DirectoryCache.shared.get(key: cacheKey) {
            return cached
        }

        if isCancelled?() == true { return [] }

        let startTime = CFAbsoluteTimeGetCurrent()
        FileLogger.shared.log("LIST_RAR_IMAGES_START", path: archivePath)

        let result = ArchiveIndexCache.shared.withEntries(at: archivePath, kind: .rar, progress: progress, isCancelled: isCancelled) { entries -> [FileItem]? in
            var list: [FileItem] = []

            for entry in entries {
                if isCancelled?() == true { return nil }
                if entry.kind == .directory { continue }

                let path = entry.path.replacingOccurrences(of: "\\", with: "/")
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
        let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        FileLogger.shared.log("LIST_RAR_IMAGES_END", path: archivePath, durationMs: duration)
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
