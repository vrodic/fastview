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

        loadViewedPaths()
        loadFavoritePaths()

        print("[SQLiteCache] Database initialized at \(dbPath)")
    }

    private var viewedPathsSet = Set<String>()
    private var favoritePathsSet = Set<String>()

    private func loadViewedPaths() {
        guard db != nil else { return }
        let query = "SELECT path FROM viewed_images;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let cString = sqlite3_column_text(statement, 0) {
                    let path = String(cString: cString)
                    viewedPathsSet.insert(path)
                }
            }
        }
        sqlite3_finalize(statement)
    }

    private func loadFavoritePaths() {
        guard db != nil else { return }
        let query = "SELECT path FROM favorites;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let cString = sqlite3_column_text(statement, 0) {
                    let path = String(cString: cString)
                    favoritePathsSet.insert(path)
                }
            }
        }
        sqlite3_finalize(statement)
    }

    public func getFavoriteCount(keys: [String]) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return keys.filter { favoritePathsSet.contains($0) || favoritePathsSet.contains(($0 as NSString).lastPathComponent) }.count
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

        if viewedPathsSet.contains(key) { return }
        viewedPathsSet.insert(key)

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
        guard isTrackingViewedImagesEnabled else { return false }
        lock.lock()
        defer { lock.unlock() }
        return viewedPathsSet.contains(key)
    }

    public func getViewedCount(keys: [String]) -> Int {
        guard isTrackingViewedImagesEnabled else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        return keys.filter { viewedPathsSet.contains($0) }.count
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
            favoritePathsSet.remove(favKey)
            favoritePathsSet.remove(item.path)
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
            FolderStatsCalculator.clearCache()
            return false
        } else {
            favoritePathsSet.insert(favKey)
            favoritePathsSet.insert(item.path)
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
            FolderStatsCalculator.clearCache()
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
