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

        // First item is always parent navigation `(..)`
        let parentItem = FileItem.parentItem(for: currentLocation.physicalPath)
        results.append(parentItem)

        if currentLocation.isArchive {
            let subfolder = currentLocation.archiveSubfolder ?? ""
            if currentLocation.archiveType == .archiveZip {
                let items = ArchiveReader.listZipContents(archivePath: currentLocation.physicalPath, subfolder: subfolder)
                results.append(contentsOf: items)
            } else if currentLocation.archiveType == .archiveRar {
                let items = ArchiveReader.listRarContents(archivePath: currentLocation.physicalPath, subfolder: subfolder)
                results.append(contentsOf: items)
            }
        } else {
            // Fast dirent directory scanning for network shares & large folders
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: currentLocation.physicalPath),
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
            ) else {
                DirectoryCache.shared.set(key: key, items: results)
                return results
            }

            var dirItems: [FileItem] = []
            while let fileURL = enumerator.nextObject() as? URL {
                let ext = fileURL.pathExtension.lowercased()
                let isImg = ArchiveReader.isImageExtension(ext)
                let isArc = ArchiveReader.isArchiveExtension(ext)

                var isDir: ObjCBool = false
                fm.fileExists(atPath: fileURL.path, isDirectory: &isDir)

                let type: FileType
                if isDir.boolValue {
                    type = .directory
                } else if ext == "zip" {
                    type = .archiveZip
                } else if ext == "rar" {
                    type = .archiveRar
                } else if isImg {
                    type = .image
                } else {
                    continue
                }

                dirItems.append(FileItem(
                    id: fileURL.path,
                    name: fileURL.lastPathComponent,
                    path: fileURL.path,
                    type: type,
                    archivePath: nil,
                    isDirectory: isDir.boolValue,
                    fileSize: 0
                ))
            }

            results.append(contentsOf: ArchiveReader.sortItems(dirItems))
        }

        DirectoryCache.shared.set(key: key, items: results)
        return results
    }

    public func navigateTo(_ item: FileItem) -> NavigationLocation? {
        if item.type == .parentDirectory {
            return navigateUp()
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

    public func navigateUp() -> NavigationLocation {
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
                return newLoc
            } else {
                let parentDir = (currentLocation.physicalPath as NSString).deletingLastPathComponent
                let newLoc = NavigationLocation(
                    physicalPath: parentDir,
                    archiveSubfolder: nil,
                    isArchive: false,
                    archiveType: nil
                )
                self.currentLocation = newLoc
                return newLoc
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
            return newLoc
        }
    }
}
