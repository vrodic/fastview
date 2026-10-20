import Foundation

public struct NavigationLocation: Equatable, Hashable {
    public let physicalPath: String       // Disk path to directory or archive
    public let archiveSubfolder: String? // If inside archive, virtual subfolder path
    public let isArchive: Bool
    public let archiveType: FileType?

    public init(physicalPath: String, archiveSubfolder: String? = nil, isArchive: Bool = false, archiveType: FileType? = nil) {
        self.physicalPath = physicalPath
        self.archiveSubfolder = archiveSubfolder
        self.isArchive = isArchive
        self.archiveType = archiveType
    }

    public var cacheKey: String {
        return "\(physicalPath)_\(archiveSubfolder ?? "")_\(isArchive)"
    }
}

public class NavigationManager {
    public private(set) var currentLocation: NavigationLocation

    public init(initialLocation: NavigationLocation) {
        self.currentLocation = initialLocation
    }

    public static func locationForPath(_ rawPath: String) -> NavigationLocation {
        let url = URL(fileURLWithPath: rawPath).standardized
        let path = url.path
        let type = ArchiveReader.fileType(for: url)

        if type == .archiveZip || type == .archiveRar {
            return NavigationLocation(
                physicalPath: path,
                archiveSubfolder: "",
                isArchive: true,
                archiveType: type
            )
        } else if type == .directory {
            return NavigationLocation(
                physicalPath: path,
                archiveSubfolder: nil,
                isArchive: false,
                archiveType: nil
            )
        } else {
            let parentDir = (path as NSString).deletingLastPathComponent
            return NavigationLocation(
                physicalPath: parentDir,
                archiveSubfolder: nil,
                isArchive: false,
                archiveType: nil
            )
        }
    }

    public func contents() -> [FileItem] {
        let key = currentLocation.cacheKey
        if let cached = DirectoryCache.shared.get(key: key) {
            return cached
        }

        var results: [FileItem] = []
        let parentItem = FileItem.parentItem(for: currentLocation.physicalPath)
        results.append(parentItem)

        if currentLocation.isArchive {
            let subfolder = currentLocation.archiveSubfolder ?? ""
            let archiveItems: [FileItem]
            if currentLocation.archiveType == .archiveZip {
                archiveItems = ArchiveReader.listZipContents(archivePath: currentLocation.physicalPath, subfolder: subfolder)
            } else {
                archiveItems = ArchiveReader.listRarContents(archivePath: currentLocation.physicalPath, subfolder: subfolder)
            }
            results.append(contentsOf: archiveItems)
        } else {
            // Ultra-fast network directory scan: batch resource keys without stat calls
            let fm = FileManager.default
            let dirURL = URL(fileURLWithPath: currentLocation.physicalPath)

            guard let fileURLs = try? fm.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                DirectoryCache.shared.set(key: key, items: results)
                return results
            }

            var dirItems: [FileItem] = []
            dirItems.reserveCapacity(fileURLs.count)

            for fileURL in fileURLs {
                let ext = fileURL.pathExtension.lowercased()
                let fullPath = fileURL.path
                let fileName = fileURL.lastPathComponent

                if ext == "zip" {
                    dirItems.append(FileItem(id: fullPath, name: fileName, path: fullPath, type: .archiveZip, isDirectory: false))
                } else if ext == "rar" {
                    dirItems.append(FileItem(id: fullPath, name: fileName, path: fullPath, type: .archiveRar, isDirectory: false))
                } else if ArchiveReader.isImageExtension(ext) {
                    dirItems.append(FileItem(id: fullPath, name: fileName, path: fullPath, type: .image, isDirectory: false))
                } else {
                    let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
                    let isDir = values?.isDirectory ?? false
                    if isDir {
                        dirItems.append(FileItem(id: fullPath, name: fileName, path: fullPath, type: .directory, isDirectory: true))
                    }
                }
            }

            results.append(contentsOf: ArchiveReader.sortItems(dirItems))
        }

        DirectoryCache.shared.set(key: key, items: results)
        return results
    }

    public func contentsProgressive(chunkSize: Int = 50, onChunk: @escaping ([FileItem]) -> Void) {
        let items = contents()
        onChunk(items)
    }

    public func navigateTo(_ item: FileItem) -> NavigationLocation? {
        if item.type == .parentDirectory {
            return navigateUp().location
        }

        if currentLocation.isArchive {
            if item.isDirectory {
                let sub = item.path
                let newLoc = NavigationLocation(
                    physicalPath: currentLocation.physicalPath,
                    archiveSubfolder: sub,
                    isArchive: true,
                    archiveType: currentLocation.archiveType
                )
                self.currentLocation = newLoc
                return newLoc
            }
        } else {
            if item.type == .directory {
                let newLoc = NavigationLocation(
                    physicalPath: item.path,
                    archiveSubfolder: nil,
                    isArchive: false,
                    archiveType: nil
                )
                self.currentLocation = newLoc
                return newLoc
            } else if item.type == .archiveZip || item.type == .archiveRar {
                let newLoc = NavigationLocation(
                    physicalPath: item.path,
                    archiveSubfolder: "",
                    isArchive: true,
                    archiveType: item.type
                )
                self.currentLocation = newLoc
                return newLoc
            }
        }
        return nil
    }

    public func navigateUp() -> (location: NavigationLocation, exitedItemPath: String) {
        let exitedPath = currentLocation.isArchive ? (currentLocation.archiveSubfolder ?? currentLocation.physicalPath) : currentLocation.physicalPath

        if currentLocation.isArchive {
            if let subfolder = currentLocation.archiveSubfolder, !subfolder.isEmpty {
                let parentSub = (subfolder as NSString).deletingLastPathComponent
                let cleanSub = parentSub == "." ? "" : parentSub
                let newLoc = NavigationLocation(
                    physicalPath: currentLocation.physicalPath,
                    archiveSubfolder: cleanSub,
                    isArchive: true,
                    archiveType: currentLocation.archiveType
                )
                self.currentLocation = newLoc
                return (newLoc, exitedPath)
            } else {
                let parentDir = (currentLocation.physicalPath as NSString).deletingLastPathComponent
                let newLoc = NavigationLocation(
                    physicalPath: parentDir,
                    archiveSubfolder: nil,
                    isArchive: false,
                    archiveType: nil
                )
                self.currentLocation = newLoc
                return (newLoc, currentLocation.physicalPath)
            }
        } else {
            let parentDir = (currentLocation.physicalPath as NSString).deletingLastPathComponent
            let newLoc = NavigationLocation(
                physicalPath: parentDir,
                archiveSubfolder: nil,
                isArchive: false,
                archiveType: nil
            )
            self.currentLocation = newLoc
            return (newLoc, currentLocation.physicalPath)
        }
    }
}
