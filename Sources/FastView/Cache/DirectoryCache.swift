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
    public let favoriteCount: Int

    public var badgeString: String {
        guard totalImages > 0 else { return "" }
        let countText = isComplete ? "\(totalImages) imgs" : "\(totalImages)* imgs"
        if SQLiteCache.shared.isTrackingViewedImagesEnabled {
            return "\(countText) | \(viewedPercentage)%"
        } else {
            return countText
        }
    }

    public var favoriteBadgeString: String {
        guard favoriteCount > 0 else { return "" }
        return "★ \(favoriteCount)"
    }
}

public enum FolderStatsCalculator {
    public static let statsQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.fastview.statsqueue"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .utility
        return q
    }()

    private struct CachedFolderData {
        let imageKeys: [String]
        let isComplete: Bool
    }

    private static var folderStatsCache = [String: CachedFolderData]()
    private static let cacheLock = NSLock()

    public static func cancelPendingCountCalculations() {
        statsQueue.cancelAllOperations()
    }

    public static func clearCache() {
        cancelPendingCountCalculations()
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
        return makeStats(for: item, totalImages: cached.imageKeys.count, isComplete: cached.isComplete)
    }

    /// Only the image total is cached; the favorite and viewed counts are
    /// read from SQLite on every call (an indexed lookup each), so they are
    /// always current without invalidating anything.
    private static func makeStats(for item: FileItem, totalImages total: Int, isComplete: Bool) -> FolderStats {
        var percentage = 0
        var favCount = 0
        if total > 0 {
            favCount = min(total, SQLiteCache.shared.favoriteCount(inContainer: item))
            let viewedCount = min(total, SQLiteCache.shared.viewedCount(withPrefix: viewedKeyPrefix(for: item)))
            percentage = Int(round(Double(viewedCount) / Double(total) * 100.0))
        }
        return FolderStats(totalImages: total, isComplete: isComplete, viewedPercentage: percentage, favoriteCount: favCount)
    }

    /// The prefix of the viewed-image keys of everything inside a folder or
    /// archive: "<archive>#" for an archive, "<archive>#<folder>/" for a
    /// folder inside one, "<folder>/" for a folder on disk.
    public static func viewedKeyPrefix(for item: FileItem) -> String {
        if let archivePath = item.archivePath {
            return "\(archivePath)#\(item.path)/"
        }
        if item.type == .archiveZip || item.type == .archiveRar {
            return "\(item.path)#"
        }
        return item.path.hasSuffix("/") ? item.path : item.path + "/"
    }

    /// `progress` reports the archive listing progress when `item` is an
    /// archive that has not been listed yet.
    /// Records the image ids of an archive known without listing it (from
    /// the thumbnail cache), so `cachedStats` can answer for it.
    public static func store(imageIDs: [String], for item: FileItem) {
        cacheLock.lock()
        folderStatsCache[item.path] = CachedFolderData(imageKeys: imageIDs.map { "\(item.path)#\($0)" }, isComplete: true)
        cacheLock.unlock()
    }

    public static func stats(for item: FileItem, progress: LoadProgressHandler? = nil, isCancelled: (() -> Bool)? = nil) -> FolderStats? {
        if let fast = cachedStats(for: item) {
            return fast
        }

        if isCancelled?() == true { return nil }

        guard item.isDirectory || item.type == .archiveZip || item.type == .archiveRar else {
            return nil
        }

        var imageKeys: [String] = []
        var isComplete = true

        if item.type == .archiveZip {
            let entries = ArchiveReader.listAllZipImages(archivePath: item.path, progress: progress, isCancelled: isCancelled)
            imageKeys = entries.map { "\(item.path)#\($0.id)" }
            isComplete = true
        } else if item.type == .archiveRar {
            let entries = ArchiveReader.listAllRarImages(archivePath: item.path, progress: progress, isCancelled: isCancelled)
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

        // A cancelled listing returns no entries; caching it would pin the
        // count at 0 until the cache is cleared.
        if isCancelled?() == true { return nil }

        cacheLock.lock()
        folderStatsCache[item.path] = CachedFolderData(imageKeys: imageKeys, isComplete: isComplete)
        let parentPath = (item.path as NSString).deletingLastPathComponent
        if !parentPath.isEmpty && parentPath != item.path && parentPath != "/" {
            folderStatsCache.removeValue(forKey: parentPath)
        }
        cacheLock.unlock()

        return makeStats(for: item, totalImages: imageKeys.count, isComplete: isComplete)
    }
}
