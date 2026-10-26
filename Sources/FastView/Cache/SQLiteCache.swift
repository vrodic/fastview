import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public class SQLiteCache {
    public static let shared = SQLiteCache()
    private var db: OpaquePointer?
    private let lock = NSLock()

    public init() {
        setupDatabase()
    }

    deinit {
        if db != nil {
            sqlite3_close(db)
        }
    }

    private func setupDatabase() {
        let fm = FileManager.default
        let cacheDir: URL
        if let userCache = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            cacheDir = userCache.appendingPathComponent("FastView", isDirectory: true)
        } else {
            let execDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            cacheDir = execDir
        }

        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let dbURL = cacheDir.appendingPathComponent("fastview_cache.sqlite")
        let dbPath = dbURL.path

        let res = sqlite3_open(dbPath, &db)
        if res != SQLITE_OK {
            let errmsg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"
            print("[SQLiteCache] Failed to open database at \(dbPath), code: \(res), msg: \(errmsg)")
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

        print("[SQLiteCache] Database initialized at \(dbPath)")
    }

    private var viewedCache = [String: Bool]()
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
            print("[SQLiteCache] toggleFavorite failed: database handle is nil")
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
                let stepRes = sqlite3_step(statement)
                print("[SQLiteCache] Removed favorite for \(item.name) (id: \(favKey), path: \(item.path)), step result: \(stepRes)")
            } else {
                let errmsg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"
                print("[SQLiteCache] Failed to prepare delete query, error code: \(prepRes), msg: \(errmsg)")
            }
            sqlite3_finalize(statement)
            loadFavoritePaths()
            return false
        } else {
            let codable = CodableFileItem(from: item)
            guard let jsonData = try? JSONEncoder().encode(codable),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                print("[SQLiteCache] Failed to encode FileItem to JSON for favorite")
                return false
            }

            let insertQuery = "INSERT OR REPLACE INTO favorites (path, item_json, timestamp) VALUES (?, ?, ?);"
            var statement: OpaquePointer?
            var prepRes = sqlite3_prepare_v2(db, insertQuery, -1, &statement, nil)

            if prepRes != SQLITE_OK {
                let errmsg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"
                print("[SQLiteCache] Failed to prepare insert query, error code: \(prepRes), msg: \(errmsg). Attempting schema fix...")
                sqlite3_exec(db, "DROP TABLE IF EXISTS favorites;", nil, nil, nil)
                sqlite3_exec(db, "CREATE TABLE favorites (path TEXT PRIMARY KEY, item_json TEXT, timestamp REAL);", nil, nil, nil)
                prepRes = sqlite3_prepare_v2(db, insertQuery, -1, &statement, nil)
            }

            if prepRes == SQLITE_OK {
                sqlite3_bind_text(statement, 1, favKey, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 2, jsonString, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
                let stepRes = sqlite3_step(statement)
                print("[SQLiteCache] Added favorite for \(item.name) (id: \(favKey), path: \(item.path)), step result: \(stepRes)")
            } else {
                let errmsg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"
                print("[SQLiteCache] Still failed to prepare insert query after schema fix, error code: \(prepRes), msg: \(errmsg)")
            }
            sqlite3_finalize(statement)
            loadFavoritePaths()
            return true
        }
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

    public func getDirectoryContents(key: String) -> [FileItem]? {
        lock.lock()
        defer { lock.unlock() }

        guard db != nil else { return nil }

        let query = "SELECT json_data FROM directory_entries WHERE cache_key = ?;"
        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)

            if sqlite3_step(statement) == SQLITE_ROW {
                if let cString = sqlite3_column_text(statement, 0) {
                    let jsonString = String(cString: cString)
                    sqlite3_finalize(statement)

                    if let data = jsonString.data(using: .utf8),
                       let decoded = try? JSONDecoder().decode([CodableFileItem].self, from: data) {
                        return decoded.map { $0.toFileItem() }
                    }
                }
            }
        }
        sqlite3_finalize(statement)
        return nil
    }

    public func saveDirectoryContents(key: String, items: [FileItem]) {
        lock.lock()
        defer { lock.unlock() }

        guard db != nil else { return }

        let codables = items.map { CodableFileItem(from: $0) }
        guard let jsonData = try? JSONEncoder().encode(codables),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        let query = "INSERT OR REPLACE INTO directory_entries (cache_key, json_data, timestamp) VALUES (?, ?, ?);"
        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, jsonString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)

            if sqlite3_step(statement) != SQLITE_DONE {
                print("[SQLiteCache] Failed to insert cache entry for \(key)")
            }
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
