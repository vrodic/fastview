import XCTest
@testable import FastView

final class DirectoryWatcherTests: XCTestCase {
    private var folder: URL!
    private var watcher: DirectoryWatcher!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("FastViewWatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        watcher = DirectoryWatcher(latency: 0.1)
    }

    override func tearDownWithError() throws {
        watcher = nil
        try? FileManager.default.removeItem(at: folder)
    }

    /// Collects changes reported for the test folder until `timeout`.
    private func changes(after action: () throws -> Void, timeout: TimeInterval = 2) rethrows -> [Set<String>] {
        var reported: [Set<String>] = []
        watcher.onChange = { changed, modified in
            if changed == self.folder.path { reported.append(modified) }
        }
        watcher.watch([folder.path])
        // Let the stream start before changing anything.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try action()
        RunLoop.main.run(until: Date().addingTimeInterval(timeout))
        return reported
    }

    func testReportsNewFile() throws {
        let reported = try changes {
            try Data([1]).write(to: folder.appendingPathComponent("new.jpg"))
        }
        XCTAssertFalse(reported.isEmpty)
    }

    func testReportsModifiedFile() throws {
        let file = folder.appendingPathComponent("photo.jpg")
        try Data([1]).write(to: file)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let reported = try changes {
            let handle = try FileHandle(forWritingTo: file)
            handle.seekToEndOfFile()
            handle.write(Data([2, 3]))
            handle.closeFile()
        }
        let resolvedFile = file.path
        XCTAssertTrue(reported.contains { $0.contains(resolvedFile) }, "\(reported)")
    }

    // Changes inside subfolders are filtered too, but FSEvents can carry a just-created
    // subfolder's "created" flag onto later events, so that is not tested here.
    func testIgnoresHiddenFiles() throws {
        let reported = try changes {
            try Data([1]).write(to: folder.appendingPathComponent(".DS_Store"))
        }
        XCTAssertTrue(reported.isEmpty, "\(reported)")
    }

    func testListingWithoutCacheSeesNewFiles() throws {
        let location = NavigationLocation(physicalPath: folder.path, archiveSubfolder: nil, isArchive: false, archiveType: nil)
        let nav = NavigationManager(initialLocation: location)
        _ = nav.contents()
        try Data([1]).write(to: folder.appendingPathComponent("later.jpg"))

        XCTAssertFalse(nav.contents().contains { $0.name == "later.jpg" }, "cached listing")
        XCTAssertTrue(nav.lastContentsWereCached)
        XCTAssertTrue(nav.contents(useCache: false).contains { $0.name == "later.jpg" })
        XCTAssertFalse(nav.lastContentsWereCached)
    }
}
