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

    /// Older versions kept the database in Caches; favorites must come along to Application Support.
    func testLegacyDatabaseMovesWithItsFavorites() throws {
        let oldDir = directory.appendingPathComponent("Caches", isDirectory: true)
        let newDir = directory.appendingPathComponent("Support", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        let oldURL = oldDir.appendingPathComponent(SQLiteCache.databaseFileName)
        let newURL = newDir.appendingPathComponent(SQLiteCache.databaseFileName)
        let favorite = listing(1)[0]

        let old = SQLiteCache(databaseURL: oldURL)
        XCTAssertTrue(old.toggleFavorite(item: favorite))
        old.shutdown()

        SQLiteCache.moveLegacyDatabase(from: oldDir, to: newURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        let moved = SQLiteCache(databaseURL: newURL)
        XCTAssertTrue(moved.isFavorite(path: favorite.id))
        moved.shutdown()
    }

    /// A database already in the new place is never replaced by an old one.
    func testLegacyDatabaseDoesNotReplaceTheCurrentOne() throws {
        let oldDir = directory.appendingPathComponent("Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        let oldURL = oldDir.appendingPathComponent(SQLiteCache.databaseFileName)
        let old = SQLiteCache(databaseURL: oldURL)
        old.shutdown()
        let current = SQLiteCache(databaseURL: url)
        XCTAssertTrue(current.toggleFavorite(item: listing(1)[0]))
        current.shutdown()

        SQLiteCache.moveLegacyDatabase(from: oldDir, to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertTrue(SQLiteCache(databaseURL: url).isFavorite(path: listing(1)[0].id))
    }

    /// Viewing images writes nothing until the batch is flushed, and then one transaction.
    func testViewedImagesAreWrittenInOneBatch() {
        let cache = SQLiteCache(databaseURL: url, viewedFlushInterval: 3600)
        let changes = cache.totalChanges
        let keys = (0..<200).map { "/photos/image\($0).png" }
        keys.forEach { cache.markImageAsViewed(key: $0) }
        XCTAssertEqual(cache.totalChanges, changes, "no row is written per view")
        XCTAssertEqual(cache.pendingViewedCount, 200)
        // Pending views count as viewed everywhere.
        XCTAssertTrue(cache.isImageViewed(key: keys[0]))
        XCTAssertEqual(cache.viewedCount(withPrefix: "/photos/"), 200)
        XCTAssertEqual(cache.viewedCount(withPrefix: "/other/"), 0)
        XCTAssertEqual(cache.countPrefixesWithViewed(["/photos/", "/other/"]), 1)

        cache.flushViewedImages()
        XCTAssertEqual(cache.pendingViewedCount, 0)
        XCTAssertEqual(cache.totalChanges, changes + 200)
        XCTAssertEqual(cache.viewedCount(withPrefix: "/photos/"), 200, "flushed views are not counted twice")
    }

    func testPendingViewsAreWrittenAtShutdown() {
        let cache = SQLiteCache(databaseURL: url, viewedFlushInterval: 3600)
        cache.markImageAsViewed(key: "/photos/a.png")
        cache.shutdown()
        let reopened = SQLiteCache(databaseURL: url)
        XCTAssertTrue(reopened.isImageViewed(key: "/photos/a.png"))
        XCTAssertEqual(reopened.viewedCount(withPrefix: "/photos/"), 1)
    }

    func testPendingViewsAreFlushedOnSchedule() {
        let cache = SQLiteCache(databaseURL: url, viewedFlushInterval: 0.05)
        cache.markImageAsViewed(key: "/photos/a.png")
        let flushed = expectation(description: "flushed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            if cache.pendingViewedCount == 0 { flushed.fulfill() }
        }
        wait(for: [flushed], timeout: 2)
        XCTAssertEqual(SQLiteCache(databaseURL: url).viewedCount(withPrefix: "/photos/"), 1)
    }

    /// An image viewed in an earlier session is not queued or written again.
    func testViewingAStoredImageAgainWritesNothing() {
        let first = SQLiteCache(databaseURL: url, viewedFlushInterval: 3600)
        first.markImageAsViewed(key: "/photos/a.png")
        first.shutdown()

        let second = SQLiteCache(databaseURL: url, viewedFlushInterval: 3600)
        second.markImageAsViewed(key: "/photos/a.png")
        XCTAssertEqual(second.pendingViewedCount, 0)
        XCTAssertEqual(second.viewedCount(withPrefix: "/photos/"), 1)
    }

    func testDatabaseUsesWriteAheadLog() {
        let cache = SQLiteCache(databaseURL: url)
        cache.saveDirectoryContents(key: "k", items: listing(1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + "-wal"))
        cache.shutdown()
    }
}
