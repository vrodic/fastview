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

    func testModifiedSortOfLargeFolderReadsDatesByListingIt() throws {
        // More files than the one-by-one threshold, in reverse date order to their names.
        var items: [FileItem] = []
        for i in 0..<30 {
            items.append(try makeFile(String(format: "img%02d.jpg", i), modified: TimeInterval(10_000 - i * 10)))
        }
        let oldestFirst = ListSorter.sort(items.shuffled(), options: ListSortOptions(key: .modified, ascending: true), refreshDates: true)
        XCTAssertEqual(oldestFirst.map { $0.name }, items.reversed().map { $0.name })
    }

    func testDatesFromTheListingAreNotReadAgain() throws {
        let a = try makeFile("a.jpg", modified: 1_000)
        let b = try makeFile("b.jpg", modified: 2_000)
        let loadStart = CFAbsoluteTimeGetCurrent()

        // The listing supplied these (deliberately unlike the files' real dates).
        ListSorter.recordModificationDates([a.path: 5_000, b.path: 4_000])
        let sorted = ListSorter.sort([a, b], options: ListSortOptions(key: .modified, ascending: true), datesReadSince: loadStart)
        XCTAssertEqual(sorted.map { $0.name }, ["b.jpg", "a.jpg"], "recorded dates were used, not re-read")

        // A later load re-reads them from disk.
        let resorted = ListSorter.sort([a, b], options: ListSortOptions(key: .modified, ascending: true), datesReadSince: CFAbsoluteTimeGetCurrent())
        XCTAssertEqual(resorted.map { $0.name }, ["a.jpg", "b.jpg"])
    }

    func testListingRecordsModificationDates() throws {
        _ = try makeFile("listed.jpg", modified: 7_000)
        let nav = NavigationManager(initialLocation: NavigationManager.locationForPath(directory.path))
        let listed = try XCTUnwrap(nav.contents().first { $0.name == "listed.jpg" })
        // Change the file's real date: the sort must use what the listing recorded.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: listed.path)
        let other = FileItem(id: "/elsewhere/other.jpg", name: "other.jpg", path: "/elsewhere/other.jpg", type: .image)
        ListSorter.recordModificationDates([other.path: 5_000])
        let sorted = ListSorter.sort([listed, other], options: ListSortOptions(key: .modified, ascending: true), datesReadSince: nil)
        XCTAssertEqual(sorted.map { $0.name }, ["other.jpg", "listed.jpg"])
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
