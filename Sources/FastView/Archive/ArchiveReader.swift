import Foundation
import ZIPFoundation
import UnrarC

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

        guard let archive = Archive(url: URL(fileURLWithPath: archivePath), accessMode: .read) else {
            return nil
        }
        guard let entry = archive[entryPath] else {
            return nil
        }

        var data = Data()
        var aborted = false

        _ = try? archive.extract(entry, consumer: { chunk in
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

        let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        FileLogger.shared.log("READ_ZIP_ENTRY_END", path: "\(archivePath) -> \(entryPath)", durationMs: duration)
        return data
    }

    public static func loadRarData(archivePath: String, entryPath: String, isCancelled: (() -> Bool)? = nil) -> Data? {
        if isCancelled?() == true { return nil }
        let startTime = CFAbsoluteTimeGetCurrent()
        FileLogger.shared.log("READ_RAR_ENTRY_START", path: "\(archivePath) -> \(entryPath)")

        guard let archive = unrar_open(archivePath) else { return nil }
        defer { unrar_close(archive) }

        if isCancelled?() == true { return nil }

        var size: Int = 0
        guard let buffer = unrar_extract_file_to_memory(archive, entryPath, &size), size > 0 else {
            return nil
        }
        let data = Data(bytes: buffer, count: size)
        free(buffer)

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

        guard let archive = Archive(url: URL(fileURLWithPath: archivePath), accessMode: .read) else {
            return []
        }

        var items: [FileItem] = []
        let cleanSubfolder = subfolder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = cleanSubfolder.isEmpty ? "" : cleanSubfolder + "/"

        var seenFolders = Set<String>()

        for entry in archive {
            if isCancelled?() == true {
                FileLogger.shared.log("LIST_ZIP_CANCELLED", path: archivePath)
                return []
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

        guard let archive = Archive(url: URL(fileURLWithPath: archivePath), accessMode: .read) else {
            return []
        }

        var items: [FileItem] = []
        for entry in archive {
            if isCancelled?() == true { return [] }
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

        guard let archive = unrar_open(archivePath) else { return [] }
        defer { unrar_close(archive) }

        guard let listPtr = unrar_list_files(archive) else { return [] }
        defer { unrar_free_entry_list(listPtr) }

        var items: [FileItem] = []
        let count = listPtr.pointee.count
        guard count > 0, let rawEntries = listPtr.pointee.entries else { return [] }

        let cleanSubfolder = subfolder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = cleanSubfolder.isEmpty ? "" : cleanSubfolder + "/"
        var seenFolders = Set<String>()

        for i in 0..<count {
            if isCancelled?() == true { return [] }
            var entry = rawEntries[i]
            let path = withUnsafeBytes(of: &entry.name) { ptr -> String in
                guard let base = ptr.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
                return String(cString: base)
            }
            guard !path.isEmpty && path != cleanSubfolder && path != cleanSubfolder + "/" else { continue }

            if !prefix.isEmpty && !path.hasPrefix(prefix) {
                continue
            }

            let relativePath = prefix.isEmpty ? path : String(path.dropFirst(prefix.count))
            let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)

            guard let firstComponent = components.first else { continue }
            let itemName = String(firstComponent)
            let isSubDir = components.count > 1 || entry.is_directory

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
                        fileSize: entry.uncompressed_size,
                        entryParentDir: innerParent
                    ))
                }
            }
        }

        if items.count == 1 && items[0].isDirectory {
            let all = listAllRarImages(archivePath: archivePath, isCancelled: isCancelled)
            if isCancelled?() == true { return [] }
            DirectoryCache.shared.set(key: cacheKey, items: all)
            let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            FileLogger.shared.log("LIST_RAR_END", path: archivePath, durationMs: duration)
            return all
        }

        let sorted = sortItems(items)
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

        guard let archive = unrar_open(archivePath) else { return [] }
        defer { unrar_close(archive) }

        guard let listPtr = unrar_list_files(archive) else { return [] }
        defer { unrar_free_entry_list(listPtr) }

        var items: [FileItem] = []
        let count = listPtr.pointee.count
        guard count > 0, let rawEntries = listPtr.pointee.entries else { return [] }

        for i in 0..<count {
            if isCancelled?() == true { return [] }
            var entry = rawEntries[i]
            if entry.is_directory { continue }
            let path = withUnsafeBytes(of: &entry.name) { ptr -> String in
                guard let base = ptr.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
                return String(cString: base)
            }
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
                    fileSize: entry.uncompressed_size,
                    entryParentDir: innerParent
                ))
            }
        }
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
