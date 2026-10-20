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
    public let id: String // Unique identifier (path or entry path inside archive)
    public let name: String
    public let path: String // Full disk path or virtual archive path
    public let type: FileType
    public let archivePath: String? // Physical disk path if inside an archive
    public let isDirectory: Bool
    public let fileSize: UInt64

    public init(id: String, name: String, path: String, type: FileType, archivePath: String? = nil, isDirectory: Bool = false, fileSize: UInt64 = 0) {
        self.id = id
        self.name = name
        self.path = path
        self.type = type
        self.archivePath = archivePath
        self.isDirectory = isDirectory
        self.fileSize = fileSize
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

    // Load entry content completely in memory from ZIP archive
    public static func loadZipData(archivePath: String, entryPath: String) -> Data? {
        guard let archive = Archive(url: URL(fileURLWithPath: archivePath), accessMode: .read) else {
            return nil
        }
        guard let entry = archive[entryPath] else {
            return nil
        }

        var data = Data()
        _ = try? archive.extract(entry, consumer: { chunk in
            data.append(chunk)
        })
        return data
    }

    // Load entry content completely in memory from RAR archive
    public static func loadRarData(archivePath: String, entryPath: String) -> Data? {
        guard let archive = unrar_open(archivePath) else { return nil }
        defer { unrar_close(archive) }

        var size: Int = 0
        guard let buffer = unrar_extract_file_to_memory(archive, entryPath, &size), size > 0 else {
            return nil
        }
        let data = Data(bytes: buffer, count: size)
        free(buffer)
        return data
    }

    // List contents of ZIP archive at specific subfolder level (or all items if root)
    public static func listZipContents(archivePath: String, subfolder: String = "") -> [FileItem] {
        guard let archive = Archive(url: URL(fileURLWithPath: archivePath), accessMode: .read) else {
            return []
        }

        var items: [FileItem] = []
        let cleanSubfolder = subfolder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = cleanSubfolder.isEmpty ? "" : cleanSubfolder + "/"

        var seenFolders = Set<String>()

        for entry in archive {
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
                    items.append(FileItem(
                        id: path,
                        name: itemName,
                        path: path,
                        type: .image,
                        archivePath: archivePath,
                        isDirectory: false,
                        fileSize: UInt64(entry.uncompressedSize)
                    ))
                }
            }
        }

        // If listing at root yielded only 1 item and it's a directory wrapper, flatten or include all images
        if items.count == 1 && items[0].isDirectory {
            return listAllZipImages(archivePath: archivePath)
        }

        return sortItems(items)
    }

    // List ALL image entries recursively in ZIP archive
    public static func listAllZipImages(archivePath: String) -> [FileItem] {
        guard let archive = Archive(url: URL(fileURLWithPath: archivePath), accessMode: .read) else {
            return []
        }

        var items: [FileItem] = []
        for entry in archive {
            guard entry.type == .file else { continue }
            let path = entry.path
            let ext = (path as NSString).pathExtension.lowercased()
            if isImageExtension(ext) {
                let name = (path as NSString).lastPathComponent
                items.append(FileItem(
                    id: path,
                    name: name,
                    path: path,
                    type: .image,
                    archivePath: archivePath,
                    isDirectory: false,
                    fileSize: UInt64(entry.uncompressedSize)
                ))
            }
        }
        return sortItems(items)
    }

    // List contents of RAR archive at specific subfolder level
    public static func listRarContents(archivePath: String, subfolder: String = "") -> [FileItem] {
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
                    items.append(FileItem(
                        id: path,
                        name: itemName,
                        path: path,
                        type: .image,
                        archivePath: archivePath,
                        isDirectory: false,
                        fileSize: entry.uncompressed_size
                    ))
                }
            }
        }

        if items.count == 1 && items[0].isDirectory {
            return listAllRarImages(archivePath: archivePath)
        }

        return sortItems(items)
    }

    // List ALL image entries recursively in RAR archive
    public static func listAllRarImages(archivePath: String) -> [FileItem] {
        guard let archive = unrar_open(archivePath) else { return [] }
        defer { unrar_close(archive) }

        guard let listPtr = unrar_list_files(archive) else { return [] }
        defer { unrar_free_entry_list(listPtr) }

        var items: [FileItem] = []
        let count = listPtr.pointee.count
        guard count > 0, let rawEntries = listPtr.pointee.entries else { return [] }

        for i in 0..<count {
            var entry = rawEntries[i]
            if entry.is_directory { continue }
            let path = withUnsafeBytes(of: &entry.name) { ptr -> String in
                guard let base = ptr.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
                return String(cString: base)
            }
            let ext = (path as NSString).pathExtension.lowercased()
            if isImageExtension(ext) {
                let name = (path as NSString).lastPathComponent
                items.append(FileItem(
                    id: path,
                    name: name,
                    path: path,
                    type: .image,
                    archivePath: archivePath,
                    isDirectory: false,
                    fileSize: entry.uncompressed_size
                ))
            }
        }
        return sortItems(items)
    }

    // Fast natural sorting: Folders/Archives first, then alphanumeric images
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
