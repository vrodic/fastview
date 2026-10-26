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

    public func contents(isCancelled: (() -> Bool)? = nil) -> [FileItem] {
        if isCancelled?() == true { return [] }

        let key = currentLocation.cacheKey
        if let cached = SQLiteCache.shared.getDirectoryContents(key: key) {
            let hasContent = cached.contains { $0.type == .image || $0.type == .directory || $0.type == .archiveZip || $0.type == .archiveRar }
            if hasContent || !currentLocation.isArchive {
                return cached
            }
        }

        var results: [FileItem] = []
        let parentItem = FileItem.parentItem(for: currentLocation.physicalPath)
        results.append(parentItem)

        if currentLocation.isArchive {
            let subfolder = currentLocation.archiveSubfolder ?? ""
            let archiveItems: [FileItem]
            if currentLocation.archiveType == .archiveZip {
                archiveItems = ArchiveReader.listZipContents(archivePath: currentLocation.physicalPath, subfolder: subfolder, isCancelled: isCancelled)
            } else {
                archiveItems = ArchiveReader.listRarContents(archivePath: currentLocation.physicalPath, subfolder: subfolder, isCancelled: isCancelled)
            }
            results.append(contentsOf: archiveItems)
        } else {
            let fm = FileManager.default
            let dirURL = URL(fileURLWithPath: currentLocation.physicalPath)

            guard let fileURLs = try? fm.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                SQLiteCache.shared.saveDirectoryContents(key: key, items: results)
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

        let hasContent = results.contains { $0.type == .image || $0.type == .directory || $0.type == .archiveZip || $0.type == .archiveRar }
        if hasContent || !currentLocation.isArchive {
            SQLiteCache.shared.saveDirectoryContents(key: key, items: results)
        }
        return results
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
        } else {
            if item.isDirectory {
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
        let exitedPath: String
        if currentLocation.isArchive {
            exitedPath = currentLocation.physicalPath
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
                return (newLoc, subfolder)
            } else {
                let parentDir = (currentLocation.physicalPath as NSString).deletingLastPathComponent
                let newLoc = NavigationLocation(
                    physicalPath: parentDir,
                    archiveSubfolder: nil,
                    isArchive: false,
                    archiveType: nil
                )
                self.currentLocation = newLoc
                return (newLoc, exitedPath)
            }
        } else {
            exitedPath = currentLocation.physicalPath
            let parentDir = (currentLocation.physicalPath as NSString).deletingLastPathComponent
            let newLoc = NavigationLocation(
                physicalPath: parentDir,
                archiveSubfolder: nil,
                isArchive: false,
                archiveType: nil
            )
            self.currentLocation = newLoc
            return (newLoc, exitedPath)
        }
    }
}
