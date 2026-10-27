import Foundation

public enum ListSortKey: String, CaseIterable {
    case name
    case modified
    case favorites
    case viewed

    public var title: String {
        switch self {
        case .name: return "Name"
        case .modified: return "Modified"
        case .favorites: return "Favorites"
        case .viewed: return "Viewed"
        }
    }

    /// Labels for the two directions: (ascending, descending).
    public var directionTitles: (ascending: String, descending: String) {
        switch self {
        case .name: return ("A → Z", "Z → A")
        case .modified: return ("Oldest First", "Newest First")
        case .favorites: return ("Favorites Last", "Favorites First")
        case .viewed: return ("Viewed Last", "Viewed First")
        }
    }
}

public struct ListSortOptions: Equatable {
    public var key: ListSortKey
    /// Name: A→Z, Modified: oldest first, Favorites/Viewed: those last.
    public var ascending: Bool

    public static let `default` = ListSortOptions(key: .name, ascending: true)

    public var directionTitle: String {
        let titles = key.directionTitles
        return ascending ? titles.ascending : titles.descending
    }

    private static func keyName(pane: Int) -> String { "FastViewSortKeyPane\(pane)" }
    private static func ascendingName(pane: Int) -> String { "FastViewSortAscendingPane\(pane)" }

    public static func load(pane: Int) -> ListSortOptions {
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: keyName(pane: pane)),
              let key = ListSortKey(rawValue: raw) else { return .default }
        let ascending = defaults.object(forKey: ascendingName(pane: pane)) as? Bool ?? true
        return ListSortOptions(key: key, ascending: ascending)
    }

    public func save(pane: Int) {
        UserDefaults.standard.set(key.rawValue, forKey: ListSortOptions.keyName(pane: pane))
        UserDefaults.standard.set(ascending, forKey: ListSortOptions.ascendingName(pane: pane))
    }
}

/// Orders sidebar lists.  The parent entry stays on top and folders/archives
/// stay ahead of images; the sort key orders items within those groups, with
/// name order breaking ties.
///
/// Sorting by modification date may read file dates, so call `sort` off the
/// main thread.  Dates are cached for the session with the time they were read:
/// a fresh load passes `datesReadSince` (when it began), so dates read before
/// it are read again while those its listing just supplied are kept.
/// Re-sorting the same list reuses them.
public enum ListSorter {
    private struct CachedDate {
        var date: Double
        var readAt: CFAbsoluteTime
    }

    private static var modificationDates = [String: CachedDate]()
    private static let datesLock = NSLock()
    /// Above this many dates missing in one folder, the folder is listed once
    /// (its entries' dates arrive in bulk) instead of reading each file's date.
    private static let bulkReadThreshold = 8

    /// `refreshDates` is `datesReadSince` set to now.
    public static func sort(_ items: [FileItem], options: ListSortOptions, refreshDates: Bool = false) -> [FileItem] {
        return sort(items, options: options, datesReadSince: refreshDates ? CFAbsoluteTimeGetCurrent() : nil)
    }

    public static func sort(_ items: [FileItem], options: ListSortOptions, datesReadSince: CFAbsoluteTime?) -> [FileItem] {
        let parents = items.filter { $0.type == .parentDirectory }
        let rest = items.filter { $0.type != .parentDirectory }
        let containers = rest.filter { isContainer($0) }
        let images = rest.filter { !isContainer($0) }
        return parents + sortGroup(containers, options: options, datesReadSince: datesReadSince)
            + sortGroup(images, options: options, datesReadSince: datesReadSince)
    }

    /// Records dates a directory listing already fetched, so sorting needs no reads of its own.
    public static func recordModificationDates(_ dates: [String: Double]) {
        guard !dates.isEmpty else { return }
        let now = CFAbsoluteTimeGetCurrent()
        datesLock.lock()
        for (path, date) in dates {
            modificationDates[path] = CachedDate(date: date, readAt: now)
        }
        datesLock.unlock()
    }

    private static func isContainer(_ item: FileItem) -> Bool {
        return item.isDirectory || item.type == .archiveZip || item.type == .archiveRar
    }

    private static func sortGroup(_ items: [FileItem], options: ListSortOptions, datesReadSince: CFAbsoluteTime?) -> [FileItem] {
        guard items.count > 1 else { return items }

        let scores: [Double]
        switch options.key {
        case .name:
            let sorted = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return options.ascending ? sorted : sorted.reversed()
        case .modified:
            scores = modificationDates(for: items, readSince: datesReadSince)
        case .favorites:
            scores = items.map(favoriteScore)
        case .viewed:
            loadMissingArchiveStats(for: items)
            scores = items.map(viewedScore)
        }

        return zip(items, scores)
            .sorted { a, b in
                if a.1 != b.1 {
                    return options.ascending ? a.1 < b.1 : a.1 > b.1
                }
                return a.0.name.localizedStandardCompare(b.0.name) == .orderedAscending
            }
            .map { $0.0 }
    }

    /// 1 for a favorite image; for a folder or archive, the number of
    /// favorite images inside it (plus one if it is a favorite itself), so
    /// containers holding more favorites come first.
    private static func favoriteScore(_ item: FileItem) -> Double {
        let cache = SQLiteCache.shared
        let isFavorite = cache.isFavorite(path: item.id) || cache.isFavorite(path: item.path)
        guard isContainer(item) else { return isFavorite ? 1 : 0 }
        return Double(cache.favoriteCount(inContainer: item) + (isFavorite ? 1 : 0))
    }

    /// Archives whose thumbnails have not been shown this session have no
    /// statistics in memory yet.  An archive with viewed images was opened,
    /// so its image list is in the listing cache; recording it gives the
    /// archive its viewed share (and its badge) without reading it.
    private static func loadMissingArchiveStats(for items: [FileItem]) {
        for item in items where item.type == .archiveZip || item.type == .archiveRar {
            guard FolderStatsCalculator.cachedStats(for: item) == nil,
                  SQLiteCache.shared.viewedCount(withPrefix: FolderStatsCalculator.viewedKeyPrefix(for: item)) > 0,
                  let imageIDs = SQLiteCache.shared.cachedArchiveImageIDs(archivePath: item.path) else { continue }
            FolderStatsCalculator.store(imageIDs: imageIDs, for: item)
        }
    }

    /// 1 for a viewed image; for a folder or archive, the share of its images
    /// that were viewed.  A container with viewed images always ranks above
    /// unviewed ones, even when its share is unknown or rounds to 0%.
    private static func viewedScore(_ item: FileItem) -> Double {
        if isContainer(item) {
            let viewed = SQLiteCache.shared.viewedCount(withPrefix: FolderStatsCalculator.viewedKeyPrefix(for: item))
            guard viewed > 0 else { return 0 }
            let share = FolderStatsCalculator.cachedStats(for: item).map { Double($0.viewedPercentage) / 100.0 } ?? 0
            return max(share, 0.001)
        }
        let key = item.archivePath.map { "\($0)#\(item.id)" } ?? item.id
        return SQLiteCache.shared.isImageViewed(key: key) ? 1 : 0
    }

    /// Entries inside an archive have no date of their own and use the archive's.
    private static func modificationDates(for items: [FileItem], readSince: CFAbsoluteTime?) -> [Double] {
        let paths = items.map { $0.archivePath ?? $0.path }

        datesLock.lock()
        let missing = Set(paths.filter { path in
            guard let cached = modificationDates[path] else { return true }
            return readSince.map { cached.readAt < $0 } ?? false
        })
        datesLock.unlock()

        if !missing.isEmpty {
            let found = DiskIOGate.shared.perform(.interactive, label: "sort-by-date") {
                readModificationDates(missing)
            }
            recordModificationDates(found)
        }

        datesLock.lock()
        defer { datesLock.unlock() }
        return paths.map { modificationDates[$0]?.date ?? 0 }
    }

    /// On a network volume every file's date is a round trip; listing the folder
    /// returns all its entries' dates in a few. So folders with many dates
    /// missing are listed, and the rest read one by one.
    private static func readModificationDates(_ paths: Set<String>) -> [String: Double] {
        var result = [String: Double]()
        let byFolder = Dictionary(grouping: paths) { ($0 as NSString).deletingLastPathComponent }
        for (folder, folderPaths) in byFolder {
            if folderPaths.count > bulkReadThreshold {
                let wanted = Set(folderPaths)
                let urls = (try? FileManager.default.contentsOfDirectory(
                    at: URL(fileURLWithPath: folder),
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: []
                )) ?? []
                for url in urls where wanted.contains(url.path) {
                    let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    result[url.path] = date?.timeIntervalSince1970 ?? 0
                }
            }
            // One by one: small groups, and anything the listing did not return.
            for path in folderPaths where result[path] == nil {
                let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey])
                result[path] = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            }
        }
        return result
    }
}
