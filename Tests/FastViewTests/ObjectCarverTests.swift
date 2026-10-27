import XCTest
import AppKit
@testable import FastView

final class ObjectCarverTests: XCTestCase {
    /// 200×100 points at 2 pixels per point, fully opaque.
    private func makeImage() -> (CGImage, NSSize) {
        let ctx = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 1600,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        return (ctx.makeImage()!, NSSize(width: 200, height: 100))
    }

    private func alpha(of image: NSImage, xFraction: CGFloat, yFraction: CGFloat) -> UInt8 {
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let x = Int(xFraction * CGFloat(cg.width)), y = Int(yFraction * CGFloat(cg.height))
        ctx.draw(cg, in: CGRect(x: -x, y: -y, width: cg.width, height: cg.height))
        return pixel[3]
    }

    /// A triangle over the right half of the image.
    private let triangle = [CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1)]

    func testCarveOutKeepsInsideAndCropsToOutline() throws {
        let (cg, size) = makeImage()
        let (out, rect) = try XCTUnwrap(ObjectCarver.apply(ObjectCarve(points: triangle, keepsInside: true), to: cg, size: size))
        XCTAssertEqual(rect, CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(out.size, NSSize(width: 100, height: 100))
        XCTAssertEqual(alpha(of: out, xFraction: 0.9, yFraction: 0.2), 255)
        XCTAssertEqual(alpha(of: out, xFraction: 0.1, yFraction: 0.9), 0)
    }

    func testEraseRemovesInsideAndKeepsSize() throws {
        let (cg, size) = makeImage()
        let (out, rect) = try XCTUnwrap(ObjectCarver.apply(ObjectCarve(points: triangle, keepsInside: false), to: cg, size: size))
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(out.size, size)
        XCTAssertEqual(alpha(of: out, xFraction: 0.95, yFraction: 0.1), 0)
        XCTAssertEqual(alpha(of: out, xFraction: 0.25, yFraction: 0.5), 255)
    }

    func testCarvesComposeAndUndo() throws {
        let (cg, size) = makeImage()
        let fg = ForegroundObject(image: NSImage(cgImage: cg, size: size), normalizedBoundingBox: CGRect(x: 0, y: 0, width: 1, height: 1))
        let rightHalf = ObjectCarve(points: [CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0.5, y: 1)], keepsInside: true)
        let topHalf = ObjectCarve(points: [CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)], keepsInside: true)

        let carved = expectation(description: "carved")
        var result: ForegroundObject?
        ForegroundSource.applyCarves([rightHalf, topHalf], to: fg) { out, rect in
            XCTAssertEqual(rect, CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
            result = out
            carved.fulfill()
        }
        wait(for: [carved], timeout: 5)
        let out = try XCTUnwrap(result)
        XCTAssertEqual(out.carves.count, 2)
        XCTAssertEqual(out.image.size, NSSize(width: 100, height: 50))
        XCTAssertEqual(out.carvedRect, CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))

        let undone = expectation(description: "undone")
        ForegroundSource.undoCarves(of: out) { restored, rect in
            XCTAssertEqual(restored.image.size, size)
            XCTAssertTrue(restored.carves.isEmpty)
            XCTAssertNil(restored.imageBeforeCarving)
            // The original image relative to the carved one.
            XCTAssertEqual(rect, CGRect(x: -1, y: -1, width: 2, height: 2))
            undone.fulfill()
        }
        wait(for: [undone], timeout: 5)
    }

    func testCarveOutWithDetectionStillLeavesTheOutlinedPart() throws {
        let (cg, size) = makeImage()
        let fg = ForegroundObject(image: NSImage(cgImage: cg, size: size), normalizedBoundingBox: CGRect(x: 0, y: 0, width: 1, height: 1))
        let done = expectation(description: "carved")
        ForegroundSource.applyCarves([ObjectCarve(points: triangle, keepsInside: true, detectsForeground: true)], to: fg) { out, rect in
            // Vision may or may not find a subject in a flat colour; either way the crop is the outline's.
            XCTAssertEqual(rect, CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
            XCTAssertEqual(out.image.size, NSSize(width: 100, height: 100))
            XCTAssertEqual(out.carves.first?.detectsForeground, true)
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
    }

    /// 400×200 pixels: dark below y = 138 (from the bottom), light above.
    private func makeTwoToneImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 1600,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 138))
        ctx.setFillColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 138, width: 400, height: 62))
        return ctx.makeImage()!
    }

    func testSnapMovesOutlineOntoNearbyEdge() {
        // A rectangle whose top side is drawn 4 pixels below the edge.
        let drawn = [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.2), CGPoint(x: 0.8, y: 0.67), CGPoint(x: 0.2, y: 0.67)]
        let snapped = ObjectCarver.snapToEdges(drawn, in: makeTwoToneImage())
        let topSide = snapped.filter { $0.y > 0.6 && $0.x > 0.3 && $0.x < 0.7 }
        XCTAssertFalse(topSide.isEmpty)
        for p in topSide {
            XCTAssertEqual(p.y * 200, 138, accuracy: 2.5, "top side should sit on the edge")
        }
        // Away from any edge the outline stays where it was drawn.
        let bottomSide = snapped.filter { $0.y < 0.3 && $0.x > 0.3 && $0.x < 0.7 }
        XCTAssertFalse(bottomSide.isEmpty)
        for p in bottomSide {
            XCTAssertEqual(p.y, 0.2, accuracy: 0.01)
        }
    }

    func testCarvesWithoutDetectionFlagDecodeAsNoDetection() throws {
        let json = #"{"points":[[0,0],[1,0],[1,1]],"keepsInside":true}"#
        let carve = try JSONDecoder().decode(ObjectCarve.self, from: Data(json.utf8))
        XCTAssertFalse(carve.detectsForeground)
    }

    func testCarvesRoundTripInSavedState() throws {
        let carves = [ObjectCarve(points: triangle, keepsInside: true, detectsForeground: true), ObjectCarve(points: triangle, keepsInside: false)]
        let state = SavedForegroundObjectState(posX: 0, posY: 0, scale: 1, rot: 0, flipH: false, flipV: false, carves: carves)
        let decoded = try JSONDecoder().decode(SavedForegroundObjectState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.carves, carves)

        let none = SavedForegroundObjectState(posX: 0, posY: 0, scale: 1, rot: 0, flipH: false, flipV: false)
        XCTAssertNil(none.carves)
    }
}
