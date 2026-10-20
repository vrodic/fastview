import Foundation

public struct NavigationLocation: Equatable {
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
            // File: location is parent directory
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
            // Read disk directory
            let fm = FileManager.default
            guard let fileURLs = try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: currentLocation.physicalPath),
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else {
                return results
            }

            var dirItems: [FileItem] = []
            for fileURL in fileURLs {
                let type = ArchiveReader.fileType(for: fileURL)
                if type == .unsupported { continue }

                var isDir: ObjCBool = false
                fm.fileExists(atPath: fileURL.path, isDirectory: &isDir)

                let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
                let size = UInt64(values?.fileSize ?? 0)

                dirItems.append(FileItem(
                    id: fileURL.path,
                    name: fileURL.lastPathComponent,
                    path: fileURL.path,
                    type: type,
                    archivePath: nil,
                    isDirectory: isDir.boolValue,
                    fileSize: size
                ))
            }

            results.append(contentsOf: ArchiveReader.sortItems(dirItems))
        }

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
                // Exit archive back to parent directory containing the archive
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
