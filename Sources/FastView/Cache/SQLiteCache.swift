import Foundation
import SQLite3

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

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("[SQLiteCache] Failed to open database at \(dbPath)")
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

        sqlite3_exec(db, createDirectoryTable, nil, nil, nil)
        sqlite3_exec(db, createFavoritesTable, nil, nil, nil)
        print("[SQLiteCache] Database initialized at \(dbPath)")
    }

    public func isFavorite(path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard db != nil else { return false }

        let query = "SELECT path FROM favorites WHERE path = ?;"
        var statement: OpaquePointer?

        var result = false
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (path as NSString).utf8String, -1, nil)
            if sqlite3_step(statement) == SQLITE_ROW {
                result = true
            }
        }
        sqlite3_finalize(statement)
        return result
    }

    public func toggleFavorite(item: FileItem) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard db != nil else { return false }

        let path = item.path
        if isFavoriteUnlocked(path: path) {
            let deleteQuery = "DELETE FROM favorites WHERE path = ?;"
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, deleteQuery, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (path as NSString).utf8String, -1, nil)
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
            return false
        } else {
            let codable = CodableFileItem(from: item)
            guard let jsonData = try? JSONEncoder().encode(codable),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                return false
            }

            let insertQuery = "INSERT OR REPLACE INTO favorites (path, item_json, timestamp) VALUES (?, ?, ?);"
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, insertQuery, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (path as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 2, (jsonString as NSString).utf8String, -1, nil)
                sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
                sqlite3_step(statement)
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
                        items.append(decoded.toFileItem())
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
            sqlite3_bind_text(statement, 1, (path as NSString).utf8String, -1, nil)
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
            sqlite3_bind_text(statement, 1, (key as NSString).utf8String, -1, nil)

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
            sqlite3_bind_text(statement, 1, (key as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (jsonString as NSString).utf8String, -1, nil)
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

    init(from item: FileItem) {
        self.id = item.id
        self.name = item.name
        self.path = item.path
        self.archivePath = item.archivePath
        self.isDirectory = item.isDirectory
        self.fileSize = item.fileSize

        switch item.type {
        case .image: self.typeRaw = "image"
        case .archiveZip: self.typeRaw = "archiveZip"
        case .archiveRar: self.typeRaw = "archiveRar"
        case .directory: self.typeRaw = "directory"
        case .parentDirectory: self.typeRaw = "parentDirectory"
        case .unsupported: self.typeRaw = "unsupported"
        }
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

        return FileItem(
            id: id,
            name: name,
            path: path,
            type: type,
            archivePath: archivePath,
            isDirectory: isDirectory,
            fileSize: fileSize
        )
    }
}
