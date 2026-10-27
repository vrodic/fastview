import XCTest
import AppKit
@testable import FastView
import ZIPFoundation

final class CombinationStateTests: XCTestCase {
    private func makeImage(width: Int = 8, height: Int = 4, color: NSColor = .red) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        return image
    }

    private func makeObject(_ tag: String, x: CGFloat, y: CGFloat) -> ForegroundObject {
        ForegroundObject(itemPath: tag, image: makeImage(), normalizedBoundingBox: CGRect(x: 0, y: 0, width: 1, height: 1),
                         position: CGPoint(x: x, y: y))
    }

    func testStateRoundTripsThroughFileFormat() throws {
        let adjustment = ColorAdjustment(gain: [1.1, 0.9, 1.0], bias: [0.02, -0.01, 0])
        let crop = CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25)
        let objects = [
            SavedForegroundObjectState(itemPath: "/a.jpg", sourcePane: 1, posX: 10, posY: 20, normX: 0.1, normY: 0.2,
                                       scale: 1.5, rot: 33, flipH: true, flipV: false, detectionMode: "Full Region",
                                       crop: crop, cropOrientation: ImageOrientation(rotationDegrees: 90, isFlippedHorizontal: true),
                                       colorAdjustment: adjustment),
            SavedForegroundObjectState(itemPath: "/b.jpg", posX: 30, posY: 40, scale: 0.5, rot: -90, flipH: false, flipV: true)
        ]
        let state = SavedCombinationState(name: "Test", path1: "/p1", path2: "/p2", rot1: 90, flipH2: true,
                                          combiningMode: "Foreground Combine", objects: objects)

        let data = try CombinationStateManager.makeEncoder().encode(state)
        let decoded = try CombinationStateManager.makeDecoder().decode(SavedCombinationState.self, from: data)

        XCTAssertEqual(decoded.rot1, 90)
        XCTAssertTrue(decoded.flipH2)
        let decodedObjects = try XCTUnwrap(decoded.objects)
        XCTAssertEqual(decodedObjects.map { $0.itemPath }, ["/a.jpg", "/b.jpg"], "z order is kept")
        XCTAssertEqual(decodedObjects[0].sourcePane, 1)
        XCTAssertEqual(decodedObjects[0].normX, 0.1)
        XCTAssertEqual(decodedObjects[0].scale, 1.5)
        XCTAssertEqual(decodedObjects[0].rot, 33)
        XCTAssertTrue(decodedObjects[0].flipH)
        XCTAssertEqual(decodedObjects[0].crop, crop)
        XCTAssertEqual(decodedObjects[0].cropOrientation?.rotationDegrees, 90)
        XCTAssertEqual(decodedObjects[0].cropOrientation?.isFlippedHorizontal, true)
        XCTAssertEqual(decodedObjects[0].colorAdjustment, adjustment)
        XCTAssertNil(decodedObjects[1].crop)
        XCTAssertNil(decodedObjects[1].cropOrientation)
        XCTAssertNil(decodedObjects[1].colorAdjustment)
        XCTAssertEqual(decodedObjects[1].rot, -90)
        XCTAssertTrue(decodedObjects[1].flipV)
        XCTAssertNil(decodedObjects[1].sourcePane)
    }

    func testLegacyObjectWithoutNewFieldsDecodes() throws {
        let json = #"{"posX":1,"posY":2,"scale":1,"rot":0,"flipH":false,"flipV":false,"detectionMode":"Full Region"}"#
        let obj = try JSONDecoder().decode(SavedForegroundObjectState.self, from: Data(json.utf8))
        XCTAssertNil(obj.normX)
        XCTAssertNil(obj.crop)
        XCTAssertNil(obj.colorAdjustment)
        XCTAssertNil(obj.sourcePane)
    }

    func testFileNameIsSanitised() {
        let url = CombinationStateManager.fileURL(forName: "../a/b:c")
        XCTAssertEqual(url.pathExtension, "fastview")
        XCTAssertEqual(url.deletingLastPathComponent(), CombinationStateManager.directory)
        XCTAssertFalse(url.lastPathComponent.hasPrefix("."))
    }

    func testRestoredObjectsKeepOrderAndUseNormalizedPositions() {
        let canvas = CombiningCanvasView(frame: NSRect(x: 0, y: 0, width: 1000, height: 500))
        canvas.setRestoredObjects([
            (makeObject("bottom", x: 1, y: 1), CGPoint(x: 0.5, y: 0.5)),
            (makeObject("top", x: 70, y: 80), nil)
        ])
        XCTAssertEqual(canvas.objects.map { $0.itemPath }, ["bottom", "top"])
        XCTAssertEqual(canvas.objects[0].position, CGPoint(x: 500, y: 250))
        XCTAssertEqual(canvas.objects[1].position, CGPoint(x: 70, y: 80))
    }

    func testRestoreBeforeLayoutAppliesOnFirstLayout() {
        let canvas = CombiningCanvasView(frame: .zero)
        canvas.setRestoredObjects([(makeObject("a", x: 0, y: 0), CGPoint(x: 0.25, y: 0.75))])
        canvas.setFrameSize(NSSize(width: 400, height: 200))
        XCTAssertEqual(canvas.objects[0].position, CGPoint(x: 100, y: 150))
    }

    func testResizeKeepsRelativePositions() {
        let canvas = CombiningCanvasView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        canvas.setRestoredObjects([(makeObject("a", x: 0, y: 0), CGPoint(x: 0.25, y: 0.5))])
        canvas.setFrameSize(NSSize(width: 800, height: 300))
        XCTAssertEqual(canvas.objects[0].position, CGPoint(x: 200, y: 150))
        let norm = try? XCTUnwrap(canvas.normalizedPosition(of: canvas.objects[0]))
        XCTAssertEqual(norm, CGPoint(x: 0.25, y: 0.5))
    }

    func testPaneObjectIsReplacedInPlace() {
        let canvas = CombiningCanvasView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        canvas.setForegroundObject(makeObject("pane1-old", x: 10, y: 10), forPane: 1)
        canvas.addObject(makeObject("added", x: 20, y: 20))
        canvas.setForegroundObject(makeObject("pane1-new", x: 10, y: 10), forPane: 1)
        XCTAssertEqual(canvas.objects.map { $0.itemPath }, ["pane1-new", "added"])

        // Moving the fg 2 slider must not touch other objects.
        canvas.fgOffset2Percent = 0
        XCTAssertEqual(canvas.objects[1].position, CGPoint(x: 20, y: 20))
    }

    func testColorMatchingMovesMeanOntoReference() throws {
        // Two-tone images so each channel has spread.
        func twoTone(_ a: NSColor, _ b: NSColor) -> NSImage {
            let image = NSImage(size: NSSize(width: 16, height: 16))
            image.lockFocus()
            a.setFill(); NSRect(x: 0, y: 0, width: 8, height: 16).fill()
            b.setFill(); NSRect(x: 8, y: 0, width: 8, height: 16).fill()
            image.unlockFocus()
            return image
        }
        let warm = twoTone(NSColor(srgbRed: 0.8, green: 0.5, blue: 0.3, alpha: 1), NSColor(srgbRed: 0.6, green: 0.4, blue: 0.2, alpha: 1))
        let cool = twoTone(NSColor(srgbRed: 0.3, green: 0.4, blue: 0.7, alpha: 1), NSColor(srgbRed: 0.2, green: 0.3, blue: 0.6, alpha: 1))

        let refStats = try XCTUnwrap(ColorMatcher.stats(of: warm))
        let srcStats = try XCTUnwrap(ColorMatcher.stats(of: cool))
        let adjustment = ColorMatcher.adjustment(matching: srcStats, to: refStats)
        let matched = try XCTUnwrap(ColorMatcher.apply(adjustment, to: cool))
        let matchedStats = try XCTUnwrap(ColorMatcher.stats(of: matched))

        for c in 0..<3 {
            XCTAssertEqual(matchedStats.mean[c], refStats.mean[c], accuracy: 0.02)
            XCTAssertEqual(matchedStats.std[c], refStats.std[c], accuracy: 0.02)
        }
        XCTAssertEqual(matched.size, cool.size)
    }

    func testColorMatchingIgnoresTransparentPixels() throws {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 8, height: 16).fill()
        image.unlockFocus()
        let stats = try XCTUnwrap(ColorMatcher.stats(of: image))
        XCTAssertEqual(stats.mean[0], 0.2, accuracy: 0.02)
        XCTAssertEqual(stats.mean[2], 0.6, accuracy: 0.02)

        // Transparent pixels stay transparent after a bias is applied.
        let adjusted = try XCTUnwrap(ColorMatcher.apply(ColorAdjustment(gain: [1, 1, 1], bias: [0.3, 0.3, 0.3]), to: image))
        let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(adjusted.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        let midY = rep.pixelsHigh / 2
        XCTAssertEqual(rep.colorAt(x: rep.pixelsWide * 3 / 4, y: midY)?.alphaComponent ?? 1, 0, accuracy: 0.01)
        XCTAssertEqual(rep.colorAt(x: rep.pixelsWide / 4, y: midY)?.alphaComponent ?? 0, 1, accuracy: 0.01)
    }

    func testCropUsesTopLeftOrigin() throws {
        let image = NSImage(size: NSSize(width: 20, height: 10))
        image.lockFocus()
        NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 20, height: 10).fill()
        NSColor.red.setFill(); NSRect(x: 0, y: 5, width: 20, height: 5).fill()   // top half in AppKit coordinates
        image.unlockFocus()
        let top = try XCTUnwrap(image.cropped(toNormalized: CGRect(x: 0, y: 0, width: 1, height: 0.5)))
        let stats = try XCTUnwrap(ColorMatcher.stats(of: top))
        XCTAssertGreaterThan(stats.mean[0], 0.9)
        XCTAssertLessThan(stats.mean[2], 0.1)
    }

    private func patches(_ colors: [NSColor]) -> NSImage {
        let image = NSImage(size: NSSize(width: 16 * colors.count, height: 16))
        image.lockFocus()
        for (i, color) in colors.enumerated() {
            color.setFill()
            NSRect(x: 16 * i, y: 0, width: 16, height: 16).fill()
        }
        image.unlockFocus()
        return image
    }

    func testSkinDetection() {
        XCTAssertTrue(ColorMatcher.isSkin(0.85, 0.65, 0.55))    // light skin
        XCTAssertTrue(ColorMatcher.isSkin(0.55, 0.38, 0.28))    // darker skin
        XCTAssertFalse(ColorMatcher.isSkin(0.2, 0.4, 0.8))      // blue
        XCTAssertFalse(ColorMatcher.isSkin(0.3, 0.7, 0.3))      // green
        XCTAssertFalse(ColorMatcher.isSkin(1, 1, 1))            // clipped
    }

    func testSkinTonesLeadTheMatch() throws {
        let refSkin = NSColor(srgbRed: 0.85, green: 0.65, blue: 0.55, alpha: 1)
        let srcSkin = NSColor(srgbRed: 0.70, green: 0.50, blue: 0.45, alpha: 1)
        // Very different clothing colours: whole-object matching would be pulled by them.
        let reference = patches([refSkin, refSkin, NSColor(srgbRed: 0.1, green: 0.6, blue: 0.2, alpha: 1)])
        let source = patches([srcSkin, NSColor(srgbRed: 0.2, green: 0.2, blue: 0.8, alpha: 1)])

        let refProfile = try XCTUnwrap(ColorMatcher.profile(of: reference))
        let srcProfile = try XCTUnwrap(ColorMatcher.profile(of: source))
        XCTAssertNotNil(refProfile.skin)
        XCTAssertNotNil(srcProfile.skin)

        let match = ColorMatcher.adjustment(matching: srcProfile, to: refProfile)
        XCTAssertTrue(match.bySkin)
        let matched = try XCTUnwrap(ColorMatcher.apply(match.adjustment, to: source))
        let matchedSkin = try XCTUnwrap(ColorMatcher.profile(of: matched)?.skin)
        let refSkinStats = try XCTUnwrap(refProfile.skin)
        for c in 0..<3 {
            XCTAssertEqual(matchedSkin.mean[c], refSkinStats.mean[c], accuracy: 0.02)
        }
    }

    func testTintedSkinIsFoundThroughGreyWorldBalance() throws {
        // Skin and a neutral grey under a strong blue cast.
        let tinted = patches([NSColor(srgbRed: 0.55, green: 0.55, blue: 0.75, alpha: 1),
                              NSColor(srgbRed: 0.35, green: 0.40, blue: 0.70, alpha: 1)])
        XCTAssertFalse(ColorMatcher.isSkin(0.55, 0.55, 0.75))
        let profile = try XCTUnwrap(ColorMatcher.profile(of: tinted))
        XCTAssertNotNil(profile.skin)
    }

    func testNoSkinFallsBackToOverallColours() throws {
        let a = try XCTUnwrap(ColorMatcher.profile(of: patches([.blue, .green])))
        let b = try XCTUnwrap(ColorMatcher.profile(of: patches([.cyan, .purple])))
        XCTAssertNil(a.skin)
        XCTAssertFalse(ColorMatcher.adjustment(matching: a, to: b).bySkin)
    }

    func testConcurrentObjectLoadsAllCompleteIncludingArchiveEntries() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FastViewObjTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func png(_ color: NSColor) throws -> Data {
            let cg = try XCTUnwrap(patches([color]).cgImage(forProposedRect: nil, context: nil, hints: nil))
            return try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
        }
        var paths: [(item: String, archives: [String])] = []
        for i in 0..<3 {
            let url = dir.appendingPathComponent("img\(i).png")
            try png(.red).write(to: url)
            paths.append((url.path, []))
        }
        let zipURL = dir.appendingPathComponent("set.zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        let entryData = try png(.green)
        try archive.addEntry(with: "inner/face.png", type: .file, uncompressedSize: Int64(entryData.count)) { pos, size in
            entryData.subdata(in: Int(pos)..<Int(pos) + size)
        }
        // An entry saved before objects recorded their archive: found through the pane's archive.
        paths.append(("inner/face.png", [zipURL.path]))

        let done = expectation(description: "every load completes")
        done.expectedFulfillmentCount = paths.count
        var loaded = 0
        for p in paths {
            ForegroundSource.detect(itemPath: p.item, archiveCandidates: p.archives, crop: nil, orientation: nil, mode: .fullRegion) { fg in
                if let fg = fg {
                    loaded += 1
                    XCTAssertEqual(fg.archivePath, p.archives.first)
                }
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 20)
        XCTAssertEqual(loaded, paths.count)
    }

    func testPreviewDecodesAtFullSizeOrDownscaled() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 900, bitsPerSample: 8,
                                                 samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(rep.representation(using: .jpeg, properties: [:])).write(to: url)

        let full = try XCTUnwrap(CombinationStateManager.decodedImage(at: url, maxPixelSize: nil))
        XCTAssertEqual(full.size, NSSize(width: 1600, height: 900))
        let small = try XCTUnwrap(CombinationStateManager.decodedImage(at: url, maxPixelSize: 240))
        XCTAssertEqual(small.size.width, 240)
        XCTAssertEqual(small.size.height, 135)
        XCTAssertNil(CombinationStateManager.decodedImage(at: url.appendingPathExtension("missing"), maxPixelSize: nil))
    }
}
