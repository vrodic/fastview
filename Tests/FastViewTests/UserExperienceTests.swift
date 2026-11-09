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

    // MARK: - Thumbnail size

    func testThumbnailSizeCoversTheRowsPixels() {
        XCTAssertEqual(ThumbnailSize.pixels(forDisplayed: 100, scale: 2), 256)
        XCTAssertEqual(ThumbnailSize.pixels(forDisplayed: 360, scale: 2), 768)
        XCTAssertEqual(ThumbnailSize.pixels(forDisplayed: 746, scale: 2), 1536)
        XCTAssertEqual(ThumbnailSize.pixels(forDisplayed: 746, scale: 1), 768)
        XCTAssertEqual(ThumbnailSize.pixels(forDisplayed: 5000, scale: 2), 3072)
    }

    func testCachedThumbnailPrefersTheClosestSizeNotSmaller() {
        let id = "thumb-test-\(UUID().uuidString)"
        let small = NSImage(size: NSSize(width: 1, height: 1)), large = NSImage(size: NSSize(width: 2, height: 2))
        XCTAssertNil(ThumbnailSize.cachedThumbnail(itemID: id, pixels: 512))
        MemoryLRUCache.shared.setObject(small, forKey: ThumbnailSize.cacheKey(itemID: id, pixels: 256), cost: 1)
        XCTAssertTrue(ThumbnailSize.cachedThumbnail(itemID: id, pixels: 512) === small)
        MemoryLRUCache.shared.setObject(large, forKey: ThumbnailSize.cacheKey(itemID: id, pixels: 1024), cost: 1)
        XCTAssertTrue(ThumbnailSize.cachedThumbnail(itemID: id, pixels: 512) === large)
        ThumbnailSize.removeCachedThumbnails(itemID: id)
        XCTAssertNil(ThumbnailSize.cachedThumbnail(itemID: id, pixels: 512))
    }

    // MARK: - File actions

    func testOnlyRealFilesCountAsOnDisk() {
        XCTAssertTrue(FileActions.isOnDisk(FileItem(id: "/a/b.png", name: "b.png", path: "/a/b.png", type: .image)))
        XCTAssertFalse(FileActions.isOnDisk(FileItem(id: "e.png", name: "e.png", path: "e.png", type: .image, archivePath: "/a.zip")))
        XCTAssertFalse(FileActions.isOnDisk(FileItem.parentItem(for: "/a/b")))
    }

    // MARK: - Sidebar Selection & Relative Scroll Position Preservation

    func testPreservedScrollRelativeOffsetCalculations() {
        let sidebar = SidebarViewController()
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 200, height: 400)
        let sampleItems = (0..<50).map {
            FileItem(id: "item\($0)", name: "item\($0).png", path: "/path/item\($0).png", type: .image)
        }
        sidebar.setItems(sampleItems, selectFirst: false)

        // Select row 20
        sidebar.selectRow(20)
        XCTAssertEqual(sidebar.selectedItem?.id, "item20")

        // Capture preserved scroll & selection
        sidebar.preserveScrollAndSelection()

        // Simulate layout change with expanded width and height (like closing Pane 2)
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 400, height: 800)
        sidebar.viewDidLayout()

        // Selection should remain item 20
        XCTAssertEqual(sidebar.selectedItem?.id, "item20")

        // Now test contracting width and height (like opening Pane 2)
        sidebar.preserveScrollAndSelection()
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 200, height: 400)
        sidebar.viewDidLayout()

        XCTAssertEqual(sidebar.selectedItem?.id, "item20")
    }
}
