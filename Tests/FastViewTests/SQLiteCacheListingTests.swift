import XCTest
import SQLite3
@testable import FastView

final class SQLiteCacheListingTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("test.sqlite") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FastViewCacheTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func listing(_ count: Int) -> [FileItem] {
        (0..<count).map { FileItem(id: "/photos/image\($0).png", name: "image\($0).png", path: "/photos/image\($0).png", type: .image) }
    }

    func testListingRoundTrips() {
        let cache = SQLiteCache(databaseURL: url)
        cache.saveDirectoryContents(key: "k", items: listing(100))
        XCTAssertEqual(cache.getDirectoryContents(key: "k")?.map(\.id), listing(100).map(\.id))
        XCTAssertNil(cache.getDirectoryContents(key: "other"))
    }

    func testUnchangedListingIsNotWritten() {
        let cache = SQLiteCache(databaseURL: url)
        cache.saveDirectoryContents(key: "k", items: listing(100))
        let changes = cache.totalChanges
        cache.saveDirectoryContents(key: "k", items: listing(100))
        XCTAssertEqual(cache.totalChanges, changes)
        cache.saveDirectoryContents(key: "k", items: listing(101))
        XCTAssertGreaterThan(cache.totalChanges, changes)
        XCTAssertEqual(cache.getDirectoryContents(key: "k")?.count, 101)
    }

    /// Rows saved by earlier versions are plain JSON text.
    func testPlainTextRowsStillReadAndGetReplaced() throws {
        let setup = SQLiteCache(databaseURL: url)
        setup.shutdown()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let json = #"[{"id":"/a.png","name":"a.png","path":"/a.png","typeRaw":"image","isDirectory":false,"fileSize":0}]"#
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO directory_entries VALUES ('old', '\(json)', 0);", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let cache = SQLiteCache(databaseURL: url)
        XCTAssertEqual(cache.getDirectoryContents(key: "old")?.map(\.id), ["/a.png"])
        let item = try XCTUnwrap(cache.getDirectoryContents(key: "old"))
        let changes = cache.totalChanges
        cache.saveDirectoryContents(key: "old", items: item)
        XCTAssertGreaterThan(cache.totalChanges, changes)
        XCTAssertEqual(cache.getDirectoryContents(key: "old")?.map(\.id), ["/a.png"])
    }

    func testNothingIsWrittenAfterShutdown() {
        let cache = SQLiteCache(databaseURL: url)
        cache.saveDirectoryContents(key: "k", items: listing(1))
        cache.shutdown()
        cache.saveDirectoryContents(key: "k2", items: listing(1))
        cache.markImageAsViewed(key: "/photos/image0.png")
        XCTAssertNil(cache.getDirectoryContents(key: "k2"))
        let reopened = SQLiteCache(databaseURL: url)
        XCTAssertNil(reopened.getDirectoryContents(key: "k2"))
        XCTAssertEqual(reopened.getDirectoryContents(key: "k")?.count, 1)
    }
}
