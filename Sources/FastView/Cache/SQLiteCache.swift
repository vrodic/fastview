import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public class SQLiteCache {
    public static let shared = SQLiteCache()
    private var db: OpaquePointer?
    private let lock = NSLock()

    /// `databaseURL` is the default location unless a test gives its own.
    public init(databaseURL: URL? = nil) {
        setupDatabase(at: databaseURL ?? SQLiteCache.defaultDatabaseURL())
    }

    deinit {
        if db != nil {
            sqlite3_close(db)
        }
    }

    /// Closes the database for the app's exit. Waits for a write in progress, so the process does
    /// not die in the middle of one and leave a journal for the next launch to roll back; writes
    /// arriving after this are dropped.
    public func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        guard db != nil else { return }
        sqlite3_close(db)
        db = nil
    }

    /// Rows changed so far by this connection.
    var totalChanges: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return db == nil ? 0 : sqlite3_total_changes(db)
    }

    private static func defaultDatabaseURL() -> URL {
        let fm = FileManager.default
        let cacheDir: URL
        if let userCache = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            cacheDir = userCache.appendingPathComponent("FastView", isDirectory: true)
        } else {
            let execDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            cacheDir = execDir
        }

        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return cacheDir.appendingPathComponent("fastview_cache.sqlite")
    }

    private func setupDatabase(at dbURL: URL) {
        let dbPath = dbURL.path

        let res = sqlite3_open(dbPath, &db)
        if res != SQLITE_OK {
            return
        }

        // Disable explicit disk syncs to avoid NVMe wear and let OS handle flushing opportunistically
        sqlite3_exec(db, "PRAGMA synchronous = OFF;", nil, nil, nil)

        let createDirectoryTable = """
        CREATE TABLE IF NOT EXISTS directory_entries (
            cache_key TEXT PRIMARY KEY,
            json_data TEXT,
            timestamp REAL
        );
        """

        let createFavoritesTable = """
        CREATE TABLE IF NOT EXISTS favorites (
            path TEXT PRIMARY KEY,
            item_json TEXT,
            timestamp REAL
        );
        """

        let createViewedImagesTable = """
        CREATE TABLE IF NOT EXISTS viewed_images (
            path TEXT PRIMARY KEY,
            timestamp REAL
        );
        """

        sqlite3_exec(db, createDirectoryTable, nil, nil, nil)
        sqlite3_exec(db, createFavoritesTable, nil, nil, nil)
        sqlite3_exec(db, createViewedImagesTable, nil, nil, nil)

        // Ensure missing columns exist in case of legacy schema
        sqlite3_exec(db, "ALTER TABLE favorites ADD COLUMN item_json TEXT;", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE favorites ADD COLUMN timestamp REAL;", nil, nil, nil)

        loadFavoritePaths()
    }

    private var viewedCache = [String: Bool]()
    // Viewed-key prefixes (see `FolderStatsCalculator.viewedKeyPrefix`) found
    // to have viewed images under them, and found to have none; the latter
    // are forgotten whenever a new image is marked viewed.
    private var prefixesWithViewed = Set<String>()
    private var prefixesWithoutViewed = Set<String>()
    // Favorite images per containing location: every enclosing folder and
    // archive by path, and every folder inside an archive as
    // "<archive path>#<folder>".
    private var favoriteCountsByContainer = [String: Int]()

    private func loadFavoritePaths() {
        favoriteCountsByContainer.removeAll()
        guard db != nil else { return }
        let query = "SELECT item_json FROM favorites;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let cJson = sqlite3_column_text(statement, 0) {
                    let jsonStr = String(cString: cJson)
                    if let data = jsonStr.data(using: .utf8),
                       let decoded = try? JSONDecoder().decode(CodableFileItem.self, from: data) {
                        let item = decoded.toFileItem()
                        if item.type == .image {
                            countFavoriteInContainers(item)
                        }
                    }
                }
            }
        }
        sqlite3_finalize(statement)
    }

    private func countFavoriteInContainers(_ item: FileItem) {
        for key in SQLiteCache.containerKeys(enclosing: item) {
            favoriteCountsByContainer[key, default: 0] += 1
        }
    }

    /// Keys of every folder and archive enclosing `item`, in the form
    /// `favoriteCount(inContainer:)` looks up.
    static func containerKeys(enclosing item: FileItem) -> [String] {
        var keys: [String] = []
        var physical = item.path
        if let archivePath = item.archivePath {
            var entryDir = (item.path as NSString).deletingLastPathComponent
            while !entryDir.isEmpty && entryDir != "/" {
                keys.append("\(archivePath)#\(entryDir)")
                entryDir = (entryDir as NSString).deletingLastPathComponent
            }
            keys.append(archivePath)
            physical = archivePath
        }
        physical = (physical as NSString).deletingLastPathComponent
        while !physical.isEmpty && physical != "/" {
            keys.append(physical)
            physical = (physical as NSString).deletingLastPathComponent
        }
        return keys
    }

    /// Number of favorite images inside a folder or archive (including
    /// nested ones), known without listing it.
    public func favoriteCount(inContainer item: FileItem) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let archivePath = item.archivePath {
            return favoriteCountsByContainer["\(archivePath)#\(item.path)"] ?? 0
        }
        return favoriteCountsByContainer[item.path] ?? 0
    }

    public var isTrackingViewedImagesEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "FastViewTrackViewedImages") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "FastViewTrackViewedImages")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "FastViewTrackViewedImages")
        }
    }

    public func markImageAsViewed(key: String) {
        guard isTrackingViewedImagesEnabled else { return }
        lock.lock()
        defer { lock.unlock() }

        if viewedCache[key] == true { return }
        viewedCache[key] = true
        prefixesWithoutViewed.removeAll()

        guard db != nil else { return }
        let query = "INSERT OR REPLACE INTO viewed_images (path, timestamp) VALUES (?, ?);"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    public func isImageViewed(key: String) -> Bool {
        return getViewedCount(keys: [key]) > 0
    }

    public func getViewedCount(keys: [String]) -> Int {
        guard isTrackingViewedImagesEnabled, !keys.isEmpty else { return 0 }
        lock.lock()
        defer { lock.unlock() }

        let missingKeys = keys.filter { viewedCache[$0] == nil }

        if !missingKeys.isEmpty, db != nil {
            let chunkSize = 500
            for i in stride(from: 0, to: missingKeys.count, by: chunkSize) {
                let chunk = Array(missingKeys[i..<min(i + chunkSize, missingKeys.count)])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let query = "SELECT path FROM viewed_images WHERE path IN (\(placeholders));"

                var statement: OpaquePointer?
                if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                    for (index, pathKey) in chunk.enumerated() {
                        sqlite3_bind_text(statement, Int32(index + 1), pathKey, -1, SQLITE_TRANSIENT)
                    }
                    var foundPaths = Set<String>()
                    while sqlite3_step(statement) == SQLITE_ROW {
                        if let cString = sqlite3_column_text(statement, 0) {
                            foundPaths.insert(String(cString: cString))
                        }
                    }
                    sqlite3_finalize(statement)

                    for pathKey in chunk {
                        viewedCache[pathKey] = foundPaths.contains(pathKey)
                    }
                } else {
                    sqlite3_finalize(statement)
                    for pathKey in chunk {
                        viewedCache[pathKey] = false
                    }
                }
            }
        }

        return keys.filter { viewedCache[$0] == true }.count
    }

    /// Number of viewed images whose key starts with `prefix`: "<archive>#"
    /// for an archive, "<folder>/" for a folder (including archives in it).
    public func viewedCount(withPrefix prefix: String) -> Int {
        guard isTrackingViewedImagesEnabled else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        guard db != nil else { return 0 }

        // A key range rather than LIKE, so the primary key index is used.
        let query = "SELECT COUNT(*) FROM viewed_images WHERE path >= ? AND path < ?;"
        var statement: OpaquePointer?
        var count = 0
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, prefix, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, prefix + "\u{10FFFF}", -1, SQLITE_TRANSIENT)
            if sqlite3_step(statement) == SQLITE_ROW {
                count = Int(sqlite3_column_int64(statement, 0))
            }
        }
        sqlite3_finalize(statement)
        return count
    }

    /// How many of `prefixes` have at least one viewed image under them, if
    /// every one has been looked up before; nil otherwise.  Reads no database.
    public func cachedCountOfPrefixesWithViewed(_ prefixes: [String]) -> Int? {
        guard isTrackingViewedImagesEnabled else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        var count = 0
        for prefix in prefixes {
            if prefixesWithViewed.contains(prefix) {
                count += 1
            } else if !prefixesWithoutViewed.contains(prefix) {
                return nil
            }
        }
        return count
    }

    /// How many of `prefixes` have at least one viewed image under them: one
    /// indexed lookup for each prefix not looked up before.
    public func countPrefixesWithViewed(_ prefixes: [String]) -> Int {
        guard isTrackingViewedImagesEnabled else { return 0 }
        lock.lock()
        defer { lock.unlock() }

        let missing = prefixes.filter { !prefixesWithViewed.contains($0) && !prefixesWithoutViewed.contains($0) }
        if !missing.isEmpty, db != nil {
            let query = "SELECT 1 FROM viewed_images WHERE path >= ? AND path < ? LIMIT 1;"
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                for prefix in missing {
                    sqlite3_reset(statement)
                    sqlite3_bind_text(statement, 1, prefix, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(statement, 2, prefix + "\u{10FFFF}", -1, SQLITE_TRANSIENT)
                    if sqlite3_step(statement) == SQLITE_ROW {
                        prefixesWithViewed.insert(prefix)
                    } else {
                        prefixesWithoutViewed.insert(prefix)
                    }
                }
            }
            sqlite3_finalize(statement)
        }
        return prefixes.filter { prefixesWithViewed.contains($0) }.count
    }

    /// The ids of every image in an archive, from its listings cached here
    /// when it was opened (subfolder listings too, unless it was opened
    /// flattened).  Nil if any listing needed is not cached.
    public func cachedArchiveImageIDs(archivePath: String) -> [String]? {
        var imageIDs: [String] = []
        var pendingSubfolders = [""]
        while let subfolder = pendingSubfolders.popLast() {
            let key = NavigationLocation(physicalPath: archivePath, archiveSubfolder: subfolder, isArchive: true).cacheKey
            guard let listing = getDirectoryContents(key: key) else { return nil }
            for item in listing where item.archivePath == archivePath {
                if item.type == .image {
                    imageIDs.append(item.id)
                } else if item.isDirectory {
                    pendingSubfolders.append(item.path)
                }
            }
        }
        return imageIDs
    }

    public func isFavorite(path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return isFavoriteUnlocked(path: path)
    }

    public func toggleFavorite(item: FileItem) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard db != nil else {
            return false
        }

        let favKey = item.id
        let isFav = isFavoriteUnlocked(path: favKey) || isFavoriteUnlocked(path: item.path)

        if isFav {
            let deleteQuery = "DELETE FROM favorites WHERE path = ? OR path = ?;"
            var statement: OpaquePointer?
            let prepRes = sqlite3_prepare_v2(db, deleteQuery, -1, &statement, nil)
            if prepRes == SQLITE_OK {
                sqlite3_bind_text(statement, 1, favKey, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 2, item.path, -1, SQLITE_TRANSIENT)
                _ = sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
            loadFavoritePaths()
            return false
        } else {
            let codable = CodableFileItem(from: item)
            guard let jsonData = try? JSONEncoder().encode(codable),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                return false
            }

            let insertQuery = "INSERT OR REPLACE INTO favorites (path, item_json, timestamp) VALUES (?, ?, ?);"
            var statement: OpaquePointer?
            var prepRes = sqlite3_prepare_v2(db, insertQuery, -1, &statement, nil)

            if prepRes != SQLITE_OK {
                sqlite3_exec(db, "DROP TABLE IF EXISTS favorites;", nil, nil, nil)
                sqlite3_exec(db, "CREATE TABLE favorites (path TEXT PRIMARY KEY, item_json TEXT, timestamp REAL);", nil, nil, nil)
                prepRes = sqlite3_prepare_v2(db, insertQuery, -1, &statement, nil)
            }

            if prepRes == SQLITE_OK {
                sqlite3_bind_text(statement, 1, favKey, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 2, jsonString, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
                _ = sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
            loadFavoritePaths()
            return true
        }
    }

    /// When each favorite was added (seconds since 1970), by favorite key
    /// (the item's id).  Favorites saved before timestamps were recorded have 0.
    public func favoriteTimestamps() -> [String: Double] {
        lock.lock()
        defer { lock.unlock() }

        guard db != nil else { return [:] }

        var result = [String: Double]()
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT path, timestamp FROM favorites;", -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let cString = sqlite3_column_text(statement, 0) else { continue }
                result[String(cString: cString)] = sqlite3_column_double(statement, 1)
            }
        }
        sqlite3_finalize(statement)
        return result
    }

    public func getAllFavorites() -> [FileItem] {
        lock.lock()
        defer { lock.unlock() }

        guard db != nil else { return [] }

        let query = "SELECT item_json FROM favorites ORDER BY timestamp DESC;"
        var statement: OpaquePointer?
        var items: [FileItem] = []

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let cString = sqlite3_column_text(statement, 0) {
                    let jsonString = String(cString: cString)
                    if let data = jsonString.data(using: .utf8),
                       let decoded = try? JSONDecoder().decode(CodableFileItem.self, from: data) {
                        let fileItem = decoded.toFileItem()
                        if fileItem.type == .image {
                            items.append(fileItem)
                        }
                    }
                }
            }
        }
        sqlite3_finalize(statement)
        return items
    }

    private func isFavoriteUnlocked(path: String) -> Bool {
        let query = "SELECT path FROM favorites WHERE path = ?;"
        var statement: OpaquePointer?
        var result = false
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, path, -1, SQLITE_TRANSIENT)
            if sqlite3_step(statement) == SQLITE_ROW {
                result = true
            }
        }
        sqlite3_finalize(statement)
        return result
    }

    /// The stored listing as JSON, as written: compressed (BLOB), or plain text in rows
    /// saved before listings were compressed. Call with `lock` held.
    private func storedListingColumn(key: String) -> (bytes: Data, isCompressed: Bool)? {
        guard db != nil else { return nil }
        let query = "SELECT json_data FROM directory_entries WHERE cache_key = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let isCompressed = sqlite3_column_type(statement, 0) == SQLITE_BLOB
        // BLOB access first: it leaves the stored text as it is.
        guard let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        return (Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))), isCompressed)
    }

    public func getDirectoryContents(key: String) -> [FileItem]? {
        lock.lock()
        let stored = storedListingColumn(key: key)
        lock.unlock()

        guard let stored = stored else { return nil }
        var json = stored.bytes
        if stored.isCompressed {
            guard let decompressed = try? (stored.bytes as NSData).decompressed(using: .lzfse) as Data else { return nil }
            json = decompressed
        }
        return (try? JSONDecoder().decode([CodableFileItem].self, from: json))?.map { $0.toFileItem() }
    }

    /// Stores a listing, compressed (repeated paths make the JSON shrink about tenfold). Replacing
    /// a row journals all of its old pages and listings can run to megabytes, and folders are
    /// re-listed each time they open, so a listing that has not changed is not written at all.
    public func saveDirectoryContents(key: String, items: [FileItem]) {
        let encoder = JSONEncoder()
        // A stable key order: an unchanged listing must encode to the same bytes.
        encoder.outputFormatting = .sortedKeys
        guard let json = try? encoder.encode(items.map { CodableFileItem(from: $0) }),
              let compressed = try? (json as NSData).compressed(using: .lzfse) as Data else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        guard db != nil else { return }
        if let stored = storedListingColumn(key: key), stored.isCompressed, stored.bytes == compressed { return }

        let query = "INSERT OR REPLACE INTO directory_entries (cache_key, json_data, timestamp) VALUES (?, ?, ?);"
        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
            compressed.withUnsafeBytes { buffer in
                _ = sqlite3_bind_blob(statement, 2, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
            }
            sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)

            _ = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }

        guard db != nil else { return }
        sqlite3_exec(db, "DELETE FROM directory_entries;", nil, nil, nil)
    }
}

private struct CodableFileItem: Codable {
    let id: String
    let name: String
    let path: String
    let typeRaw: String
    let archivePath: String?
    let isDirectory: Bool
    let fileSize: UInt64
    let entryParentDir: String?

    init(from item: FileItem) {
        self.id = item.id
        self.name = item.name
        self.path = item.path
        self.archivePath = item.archivePath
        self.isDirectory = item.isDirectory
        self.fileSize = item.fileSize
        self.entryParentDir = item.entryParentDir

        switch item.type {
        case .image: self.typeRaw = "image"
        case .archiveZip: self.typeRaw = "archiveZip"
        case .archiveRar: self.typeRaw = "archiveRar"
        case .directory: self.typeRaw = "directory"
        case .parentDirectory: self.typeRaw = "parentDirectory"
        case .unsupported: self.typeRaw = "unsupported"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? container.decode(String.self, forKey: .id)) ?? ""
        self.name = (try? container.decode(String.self, forKey: .name)) ?? ""
        self.path = (try? container.decode(String.self, forKey: .path)) ?? ""
        self.typeRaw = (try? container.decode(String.self, forKey: .typeRaw)) ?? "image"
        self.archivePath = try? container.decodeIfPresent(String.self, forKey: .archivePath)
        self.isDirectory = (try? container.decode(Bool.self, forKey: .isDirectory)) ?? false
        self.fileSize = (try? container.decode(UInt64.self, forKey: .fileSize)) ?? 0
        self.entryParentDir = try? container.decodeIfPresent(String.self, forKey: .entryParentDir)
    }

    func toFileItem() -> FileItem {
        let type: FileType
        switch typeRaw {
        case "image": type = .image
        case "archiveZip": type = .archiveZip
        case "archiveRar": type = .archiveRar
        case "directory": type = .directory
        case "parentDirectory": type = .parentDirectory
        default: type = .unsupported
        }

        let effectiveId = id.isEmpty ? path : id

        return FileItem(
            id: effectiveId,
            name: name,
            path: path,
            type: type,
            archivePath: archivePath,
            isDirectory: isDirectory,
            fileSize: fileSize,
            entryParentDir: entryParentDir
        )
    }
}
