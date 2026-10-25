import Foundation

public class DirectoryCache {
    public static let shared = DirectoryCache()
    private var cache = [String: [FileItem]]()
    private let lock = NSLock()

    public func get(key: String) -> [FileItem]? {
        lock.lock()
        defer { lock.unlock() }
        return cache[key]
    }

    public func set(key: String, items: [FileItem]) {
        lock.lock()
        defer { lock.unlock() }
        cache[key] = items
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
        FolderStatsCalculator.clearCache()
    }
}

public struct FolderStats {
    public let totalImages: Int
    public let isComplete: Bool
    public let viewedPercentage: Int

    public var badgeString: String {
        guard totalImages > 0 else { return "" }
        let countText = isComplete ? "\(totalImages) imgs" : "\(totalImages)* imgs"
        if SQLiteCache.shared.isTrackingViewedImagesEnabled {
            return "\(countText) | \(viewedPercentage)%"
        } else {
            return countText
        }
    }
}

public enum FolderStatsCalculator {
    private struct CachedFolderData {
        let imageKeys: [String]
        let isComplete: Bool
    }

    private static var folderStatsCache = [String: CachedFolderData]()
    private static let cacheLock = NSLock()

    public static func clearCache() {
        cacheLock.lock()
        folderStatsCache.removeAll()
        cacheLock.unlock()
    }

    public static func cachedStats(for item: FileItem) -> FolderStats? {
        guard item.isDirectory || item.type == .archiveZip || item.type == .archiveRar else {
            return nil
        }

        cacheLock.lock()
        let existing = folderStatsCache[item.path]
        cacheLock.unlock()

        guard let cached = existing else { return nil }

        let total = cached.imageKeys.count
        var percentage = 0
        if total > 0 && SQLiteCache.shared.isTrackingViewedImagesEnabled {
            let viewedCount = SQLiteCache.shared.getViewedCount(keys: cached.imageKeys)
            percentage = Int(round(Double(viewedCount) / Double(total) * 100.0))
        }

        return FolderStats(totalImages: total, isComplete: cached.isComplete, viewedPercentage: percentage)
    }

    public static func stats(for item: FileItem) -> FolderStats? {
        if let fast = cachedStats(for: item) {
            return fast
        }

        guard item.isDirectory || item.type == .archiveZip || item.type == .archiveRar else {
            return nil
        }

        var imageKeys: [String] = []
        var isComplete = true

        if item.type == .archiveZip {
            let entries = ArchiveReader.listAllZipImages(archivePath: item.path)
            imageKeys = entries.map { "\(item.path)#\($0.id)" }
            isComplete = true
        } else if item.type == .archiveRar {
            let entries = ArchiveReader.listAllRarImages(archivePath: item.path)
            imageKeys = entries.map { "\(item.path)#\($0.id)" }
            isComplete = true
        } else if item.isDirectory {
            if let archivePath = item.archivePath {
                let ext = (archivePath as NSString).pathExtension.lowercased()
                let cleanSub = item.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let prefix = cleanSub.isEmpty ? "" : cleanSub + "/"

                let all: [FileItem]
                if ext == "zip" {
                    all = ArchiveReader.listAllZipImages(archivePath: archivePath)
                } else {
                    all = ArchiveReader.listAllRarImages(archivePath: archivePath)
                }

                let filtered = prefix.isEmpty ? all : all.filter { $0.path.hasPrefix(prefix) || $0.id.hasPrefix(prefix) }
                imageKeys = filtered.map { "\(archivePath)#\($0.id)" }
                isComplete = true
            } else {
                let mgr = NavigationManager(initialLocation: NavigationLocation(physicalPath: item.path))
                let contents = mgr.contents().filter { $0.type != .parentDirectory }

                let directImages = contents.filter { $0.type == .image }
                imageKeys = directImages.map { $0.id }

                let subFolders = contents.filter { $0.isDirectory || $0.type == .archiveZip || $0.type == .archiveRar }
                if !subFolders.isEmpty {
                    for sub in subFolders {
                        if sub.type == .archiveZip {
                            let zipEntries = ArchiveReader.listAllZipImages(archivePath: sub.path)
                            imageKeys.append(contentsOf: zipEntries.map { "\(sub.path)#\($0.id)" })
                        } else if sub.type == .archiveRar {
                            let rarEntries = ArchiveReader.listAllRarImages(archivePath: sub.path)
                            imageKeys.append(contentsOf: rarEntries.map { "\(sub.path)#\($0.id)" })
                        } else if sub.isDirectory {
                            cacheLock.lock()
                            let cachedSubData = folderStatsCache[sub.path]
                            cacheLock.unlock()

                            if let cachedSub = cachedSubData {
                                imageKeys.append(contentsOf: cachedSub.imageKeys)
                                if !cachedSub.isComplete {
                                    isComplete = false
                                }
                            } else {
                                isComplete = false
                            }
                        }
                    }
                }
            }
        }

        cacheLock.lock()
        folderStatsCache[item.path] = CachedFolderData(imageKeys: imageKeys, isComplete: isComplete)
        let parentPath = (item.path as NSString).deletingLastPathComponent
        if !parentPath.isEmpty && parentPath != item.path && parentPath != "/" {
            folderStatsCache.removeValue(forKey: parentPath)
        }
        cacheLock.unlock()

        let total = imageKeys.count
        var percentage = 0
        if total > 0 && SQLiteCache.shared.isTrackingViewedImagesEnabled {
            let viewedCount = SQLiteCache.shared.getViewedCount(keys: imageKeys)
            percentage = Int(round(Double(viewedCount) / Double(total) * 100.0))
        }

        return FolderStats(totalImages: total, isComplete: isComplete, viewedPercentage: percentage)
    }
}
