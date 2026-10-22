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

        let createViewNodesTable = """
        CREATE TABLE IF NOT EXISTS view_nodes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            parent_id INTEGER,
            name TEXT NOT NULL,
            path TEXT UNIQUE NOT NULL,
            is_directory INTEGER NOT NULL DEFAULT 0,
            last_viewed_at INTEGER NOT NULL DEFAULT 0,
            view_count INTEGER NOT NULL DEFAULT 0
        );
        """

        let createParentIndex = "CREATE INDEX IF NOT EXISTS idx_view_nodes_parent_id ON view_nodes(parent_id);"
        let createPathIndex = "CREATE UNIQUE INDEX IF NOT EXISTS idx_view_nodes_path ON view_nodes(path);"

        sqlite3_exec(db, createDirectoryTable, nil, nil, nil)
        sqlite3_exec(db, createFavoritesTable, nil, nil, nil)
        sqlite3_exec(db, createViewNodesTable, nil, nil, nil)
        sqlite3_exec(db, createParentIndex, nil, nil, nil)
        sqlite3_exec(db, createPathIndex, nil, nil, nil)

        // Ensure missing columns exist in case of legacy schema
        sqlite3_exec(db, "ALTER TABLE favorites ADD COLUMN item_json TEXT;", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE favorites ADD COLUMN timestamp REAL;", nil, nil, nil)

        print("[SQLiteCache] Database initialized at \(dbPath)")
    }

    private func getOrInsertNode(path: String, parentId: Int64?, name: String, isDirectory: Bool) -> Int64 {
        let selectQuery = "SELECT id FROM view_nodes WHERE path = ?;"
        var stmtSelect: OpaquePointer?
        if sqlite3_prepare_v2(db, selectQuery, -1, &stmtSelect, nil) == SQLITE_OK {
            sqlite3_bind_text(stmtSelect, 1, path, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmtSelect) == SQLITE_ROW {
                let existingId = sqlite3_column_int64(stmtSelect, 0)
                sqlite3_finalize(stmtSelect)
                return existingId
            }
        }
        sqlite3_finalize(stmtSelect)

        let insertQuery = "INSERT INTO view_nodes (parent_id, name, path, is_directory, last_viewed_at, view_count) VALUES (?, ?, ?, ?, 0, 0);"
        var stmtInsert: OpaquePointer?
        var insertedId: Int64 = -1
        if sqlite3_prepare_v2(db, insertQuery, -1, &stmtInsert, nil) == SQLITE_OK {
            if let pId = parentId {
                sqlite3_bind_int64(stmtInsert, 1, pId)
            } else {
                sqlite3_bind_null(stmtInsert, 1)
            }
            sqlite3_bind_text(stmtInsert, 2, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmtInsert, 3, path, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmtInsert, 4, isDirectory ? 1 : 0)
            if sqlite3_step(stmtInsert) == SQLITE_DONE {
                insertedId = sqlite3_last_insert_rowid(db)
            }
        }
        sqlite3_finalize(stmtInsert)

        return insertedId
    }

    public func ensureHierarchyForFileItem(item: FileItem) -> Int64 {
        if let archivePath = item.archivePath, !archivePath.isEmpty {
            let archiveId = ensureHierarchyForPathString(archivePath, isLeafDirectory: true)
            let entryClean = item.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let components = entryClean.components(separatedBy: "/").filter { !$0.isEmpty }

            var currentParentId = archiveId
            var currentPath = archivePath

            for (idx, comp) in components.enumerated() {
                let isLast = (idx == components.count - 1)
                let nodeIsDirectory = isLast ? item.isDirectory : true
                currentPath = "\(currentPath)#\(comp)"
                currentParentId = getOrInsertNode(path: currentPath, parentId: currentParentId, name: comp, isDirectory: nodeIsDirectory)
            }
            return currentParentId
        } else {
            return ensureHierarchyForPathString(item.path, isLeafDirectory: item.isDirectory)
        }
    }

    private func ensureHierarchyForPathString(_ fullPath: String, isLeafDirectory: Bool) -> Int64 {
        let normPath = URL(fileURLWithPath: fullPath).standardized.path
        let components = normPath.components(separatedBy: "/").filter { !$0.isEmpty }

        var currentParentId: Int64? = nil
        var currentPath = ""

        for (idx, comp) in components.enumerated() {
            currentPath = currentPath.isEmpty ? "/\(comp)" : "\(currentPath)/\(comp)"
            let isLast = (idx == components.count - 1)
            let nodeIsDirectory = isLast ? isLeafDirectory : true
            let nodeId = getOrInsertNode(path: currentPath, parentId: currentParentId, name: comp, isDirectory: nodeIsDirectory)
            currentParentId = nodeId
        }

        return currentParentId ?? -1
    }

    public func registerLocationItems(items: [FileItem]) {
        lock.lock()
        defer { lock.unlock() }

        guard db != nil else { return }

        for item in items {
            if item.type == .parentDirectory { continue }
            _ = ensureHierarchyForFileItem(item: item)
        }
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

    public struct ViewInfo {
        public let lastViewedAt: Date?
        public let viewCount: Int

        public init(lastViewedAt: Date?, viewCount: Int) {
            self.lastViewedAt = lastViewedAt
            self.viewCount = viewCount
        }
    }

    public func recordView(item: FileItem) {
        lock.lock()
        defer { lock.unlock() }

        guard db != nil else { return }

        let leafId = ensureHierarchyForFileItem(item: item)
        guard leafId > 0 else { return }

        let nowInt = Int64(Date().timeIntervalSince1970)

        var currentCount = 0
        let querySelect = "SELECT view_count FROM view_nodes WHERE id = ?;"
        var stmtSelect: OpaquePointer?
        if sqlite3_prepare_v2(db, querySelect, -1, &stmtSelect, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmtSelect, 1, leafId)
            if sqlite3_step(stmtSelect) == SQLITE_ROW {
                currentCount = Int(sqlite3_column_int64(stmtSelect, 0))
            }
        }
        sqlite3_finalize(stmtSelect)

        let newCount = currentCount + 1

        let updateLeaf = "UPDATE view_nodes SET last_viewed_at = ?, view_count = ? WHERE id = ?;"
        var stmtUpdate: OpaquePointer?
        if sqlite3_prepare_v2(db, updateLeaf, -1, &stmtUpdate, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmtUpdate, 1, nowInt)
            sqlite3_bind_int64(stmtUpdate, 2, Int64(newCount))
            sqlite3_bind_int64(stmtUpdate, 3, leafId)
            sqlite3_step(stmtUpdate)
        }
        sqlite3_finalize(stmtUpdate)

        let altKeys = [item.id, item.path, "\(item.archivePath ?? "") / \(item.path)"].filter { !$0.isEmpty && $0 != item.path }
        for altKey in altKeys {
            let altQuery = "UPDATE view_nodes SET last_viewed_at = ?, view_count = ? WHERE path = ?;"
            var stmtAlt: OpaquePointer?
            if sqlite3_prepare_v2(db, altQuery, -1, &stmtAlt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmtAlt, 1, nowInt)
                sqlite3_bind_int64(stmtAlt, 2, Int64(newCount))
                sqlite3_bind_text(stmtAlt, 3, altKey, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmtAlt)
            }
            sqlite3_finalize(stmtAlt)
        }

        var currentParentId: Int64? = nil
        let pQuery = "SELECT parent_id FROM view_nodes WHERE id = ?;"
        var stmtP: OpaquePointer?
        if sqlite3_prepare_v2(db, pQuery, -1, &stmtP, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmtP, 1, leafId)
            if sqlite3_step(stmtP) == SQLITE_ROW && sqlite3_column_type(stmtP, 0) != SQLITE_NULL {
                currentParentId = sqlite3_column_int64(stmtP, 0)
            }
        }
        sqlite3_finalize(stmtP)

        while let pId = currentParentId, pId > 0 {
            let childQuery = "SELECT view_count, last_viewed_at FROM view_nodes WHERE parent_id = ?;"
            var stmtChild: OpaquePointer?
            var allChildrenViewed = true
            var childCount = 0
            var maxChildLastViewed: Int64 = 0

            if sqlite3_prepare_v2(db, childQuery, -1, &stmtChild, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmtChild, 1, pId)
                while sqlite3_step(stmtChild) == SQLITE_ROW {
                    childCount += 1
                    let vCount = sqlite3_column_int64(stmtChild, 0)
                    let vDate = sqlite3_column_int64(stmtChild, 1)
                    if vCount == 0 {
                        allChildrenViewed = false
                    }
                    if vDate > maxChildLastViewed {
                        maxChildLastViewed = vDate
                    }
                }
            }
            sqlite3_finalize(stmtChild)

            if childCount > 0 && allChildrenViewed {
                let updateParent = "UPDATE view_nodes SET view_count = 1, last_viewed_at = ? WHERE id = ?;"
                var stmtParent: OpaquePointer?
                if sqlite3_prepare_v2(db, updateParent, -1, &stmtParent, nil) == SQLITE_OK {
                    sqlite3_bind_int64(stmtParent, 1, maxChildLastViewed)
                    sqlite3_bind_int64(stmtParent, 2, pId)
                    sqlite3_step(stmtParent)
                }
                sqlite3_finalize(stmtParent)
            } else {
                let resetParent = "UPDATE view_nodes SET view_count = 0 WHERE id = ?;"
                var stmtReset: OpaquePointer?
                if sqlite3_prepare_v2(db, resetParent, -1, &stmtReset, nil) == SQLITE_OK {
                    sqlite3_bind_int64(stmtReset, 1, pId)
                    sqlite3_step(stmtReset)
                }
                sqlite3_finalize(stmtReset)
            }

            var nextParentId: Int64? = nil
            let parentLookup = "SELECT parent_id FROM view_nodes WHERE id = ?;"
            var stmtPLookup: OpaquePointer?
            if sqlite3_prepare_v2(db, parentLookup, -1, &stmtPLookup, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmtPLookup, 1, pId)
                if sqlite3_step(stmtPLookup) == SQLITE_ROW && sqlite3_column_type(stmtPLookup, 0) != SQLITE_NULL {
                    nextParentId = sqlite3_column_int64(stmtPLookup, 0)
                }
            }
            sqlite3_finalize(stmtPLookup)

            if nextParentId == pId { break }
            currentParentId = nextParentId
        }
    }

    public func isViewed(path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let query = "SELECT view_count FROM view_nodes WHERE path = ? AND view_count > 0;"
        var statement: OpaquePointer?
        var result = false

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, path, -1, SQLITE_TRANSIENT)
            if sqlite3_step(statement) == SQLITE_ROW {
                result = true
            }
        }
        sqlite3_finalize(statement)

        if !result {
            let altKey: String
            if path.contains("#") {
                altKey = path.replacingOccurrences(of: "#", with: " / ")
            } else if path.contains(" / ") {
                altKey = path.replacingOccurrences(of: " / ", with: "#")
            } else {
                altKey = ""
            }

            if !altKey.isEmpty {
                var stmtAlt: OpaquePointer?
                if sqlite3_prepare_v2(db, query, -1, &stmtAlt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmtAlt, 1, altKey, -1, SQLITE_TRANSIENT)
                    if sqlite3_step(stmtAlt) == SQLITE_ROW {
                        result = true
                    }
                }
                sqlite3_finalize(stmtAlt)
            }
        }

        return result
    }

    public func getViewInfo(path: String) -> ViewInfo {
        lock.lock()
        defer { lock.unlock() }

        let query = "SELECT last_viewed_at, view_count FROM view_nodes WHERE path = ?;"
        var statement: OpaquePointer?
        var lastViewed: Date? = nil
        var viewCount = 0

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, path, -1, SQLITE_TRANSIENT)
            if sqlite3_step(statement) == SQLITE_ROW {
                let timestamp = sqlite3_column_int64(statement, 0)
                if timestamp > 0 {
                    lastViewed = Date(timeIntervalSince1970: TimeInterval(timestamp))
                }
                viewCount = Int(sqlite3_column_int64(statement, 1))
            }
        }
        sqlite3_finalize(statement)

        return ViewInfo(lastViewedAt: lastViewed, viewCount: viewCount)
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
