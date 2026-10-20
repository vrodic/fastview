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
        let execPath = CommandLine.arguments[0]
        let execDir = (execPath as NSString).deletingLastPathComponent
        let dbPath = (execDir as NSString).appendingPathComponent("fastview_cache.sqlite")

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("[SQLiteCache] Failed to open database at \(dbPath)")
            return
        }

        let createTableQuery = """
        CREATE TABLE IF NOT EXISTS directory_entries (
            cache_key TEXT PRIMARY KEY,
            json_data TEXT,
            timestamp REAL
        );
        """

        if sqlite3_exec(db, createTableQuery, nil, nil, nil) != SQLITE_OK {
            print("[SQLiteCache] Failed to create directory_entries table")
        } else {
            print("[SQLiteCache] Database initialized at \(dbPath)")
        }
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
        print("[SQLiteCache] Cleared directory cache")
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
