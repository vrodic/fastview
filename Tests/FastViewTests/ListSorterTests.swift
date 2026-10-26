import XCTest
@testable import FastView

final class ListSorterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FastViewSortTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeFile(_ name: String, modified: TimeInterval, type: FileType = .image) throws -> FileItem {
        let url = directory.appendingPathComponent(name)
        try Data([0]).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: url.path)
        return FileItem(id: url.path, name: name, path: url.path, type: type)
    }

    func testNameSortKeepsParentFirstAndContainersBeforeImages() throws {
        let parent = FileItem.parentItem(for: directory.path)
        let items = [
            try makeFile("b10.jpg", modified: 1),
            try makeFile("b2.jpg", modified: 1),
            try makeFile("a.zip", modified: 1, type: .archiveZip),
            parent,
            try makeFile("c.zip", modified: 1, type: .archiveZip)
        ]

        let ascending = ListSorter.sort(items, options: ListSortOptions(key: .name, ascending: true))
        XCTAssertEqual(ascending.map { $0.name }, ["(..)", "a.zip", "c.zip", "b2.jpg", "b10.jpg"])

        let descending = ListSorter.sort(items, options: ListSortOptions(key: .name, ascending: false))
        XCTAssertEqual(descending.map { $0.name }, ["(..)", "c.zip", "a.zip", "b10.jpg", "b2.jpg"])
    }

    func testModifiedSortOrdersByDateAndRereadsDatesOnRefresh() throws {
        let old = try makeFile("old.jpg", modified: 1_000)
        let new = try makeFile("new.jpg", modified: 2_000)
        let tie = try makeFile("another.jpg", modified: 2_000)

        let newestFirst = ListSorter.sort([old, new, tie], options: ListSortOptions(key: .modified, ascending: false))
        XCTAssertEqual(newestFirst.map { $0.name }, ["another.jpg", "new.jpg", "old.jpg"])

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 3_000)], ofItemAtPath: old.path)
        let refreshed = ListSorter.sort([old, new, tie], options: ListSortOptions(key: .modified, ascending: false), refreshDates: true)
        XCTAssertEqual(refreshed.map { $0.name }, ["old.jpg", "another.jpg", "new.jpg"])
    }
}

final class FavoriteContainerKeysTests: XCTestCase {
    func testArchiveEntryCountsTowardsItsFoldersArchiveAndEnclosingFolders() {
        let entry = FileItem(id: "set/a/1.jpg", name: "1.jpg", path: "set/a/1.jpg", type: .image, archivePath: "/lib/comics/x.zip")
        XCTAssertEqual(SQLiteCache.containerKeys(enclosing: entry), [
            "/lib/comics/x.zip#set/a", "/lib/comics/x.zip#set",
            "/lib/comics/x.zip", "/lib/comics", "/lib"
        ])
    }

    func testLooseImageCountsTowardsEnclosingFolders() {
        let image = FileItem(id: "/lib/pics/1.jpg", name: "1.jpg", path: "/lib/pics/1.jpg", type: .image)
        XCTAssertEqual(SQLiteCache.containerKeys(enclosing: image), ["/lib/pics", "/lib"])
    }
}
