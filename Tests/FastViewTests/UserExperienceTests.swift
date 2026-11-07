import XCTest
@testable import FastView

final class UserExperienceTests: XCTestCase {
    // MARK: - What gets selected when opening a path

    func testOpeningAnImageSelectsIt() {
        XCTAssertEqual(MainSplitViewController.selectionTarget(openingPath: "/a/b.png", type: .image, lastOpenedPath: "/a", savedItem: "/a/c.png"), "/a/b.png")
    }

    func testOpeningAnotherFolderSelectsTheFirstItem() {
        // The item saved for /a would not be found in /z, leaving nothing selected.
        XCTAssertNil(MainSplitViewController.selectionTarget(openingPath: "/z", type: .directory, lastOpenedPath: "/a", savedItem: "/a/c.png"))
        XCTAssertNil(MainSplitViewController.selectionTarget(openingPath: "/z", type: .directory, lastOpenedPath: nil, savedItem: nil))
    }

    func testReopeningALocationKeepsItsSelection() {
        XCTAssertEqual(MainSplitViewController.selectionTarget(openingPath: "/a/", type: .directory, lastOpenedPath: "/a", savedItem: "/a/c.png"), "/a/c.png")
        XCTAssertEqual(MainSplitViewController.selectionTarget(openingPath: "/a.zip", type: .archiveZip, lastOpenedPath: "/a.zip", savedItem: "dir/entry.png"), "dir/entry.png")
    }

    // MARK: - Recent menu

    func testRecentTitlesTellSameNamedFoldersApart() {
        XCTAssertEqual(AppDelegate.recentMenuTitles(for: ["/x/photos", "/y/photos", "/y/cats"]),
                       ["photos — x", "photos — y", "cats"])
    }

    // MARK: - Zoom level

    func testZoomPercentIsRelativeToTheImagesOwnSize() {
        let image = NSSize(width: 2000, height: 1000)
        let view = NSSize(width: 1000, height: 1000)
        XCTAssertEqual(MainImageView.zoomPercent(imageSize: image, viewSize: view, magnification: 1), 50)
        XCTAssertEqual(MainImageView.zoomPercent(imageSize: image, viewSize: view, magnification: 2), 100)
        XCTAssertNil(MainImageView.zoomPercent(imageSize: .zero, viewSize: view, magnification: 1))
    }

    // MARK: - Save name

    func testSavingOffersTheFilesName() {
        XCTAssertEqual(MainImageView.suggestedSaveName(sourceName: "cat.jpeg", isEdited: false), "cat.png")
        XCTAssertEqual(MainImageView.suggestedSaveName(sourceName: "cat.jpeg", isEdited: true), "cat edited.png")
        XCTAssertEqual(MainImageView.suggestedSaveName(sourceName: nil, isEdited: false), "Image.png")
    }

    // MARK: - File actions

    func testOnlyRealFilesCountAsOnDisk() {
        XCTAssertTrue(FileActions.isOnDisk(FileItem(id: "/a/b.png", name: "b.png", path: "/a/b.png", type: .image)))
        XCTAssertFalse(FileActions.isOnDisk(FileItem(id: "e.png", name: "e.png", path: "e.png", type: .image, archivePath: "/a.zip")))
        XCTAssertFalse(FileActions.isOnDisk(FileItem.parentItem(for: "/a/b")))
    }
}
