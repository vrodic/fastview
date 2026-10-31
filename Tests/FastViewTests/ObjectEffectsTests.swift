import XCTest
import AppKit
@testable import FastView

final class ObjectEffectsTests: XCTestCase {
    /// An opaque red square in the middle of a transparent 100×100 image.
    private func squareImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 100, height: 100))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 25, y: 25, width: 50, height: 50).fill()
        image.unlockFocus()
        return image
    }

    private func alpha(_ image: NSImage, x: Int, y: Int) -> CGFloat {
        let rep = NSBitmapImageRep(cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        let sx = x * rep.pixelsWide / 100, sy = y * rep.pixelsHigh / 100
        return rep.colorAt(x: sx, y: sy)?.alphaComponent ?? -1
    }

    func testFeatherSoftensEdgeButKeepsCentre() throws {
        let feathered = try XCTUnwrap(ObjectEffectsRenderer.feather(squareImage()))
        XCTAssertEqual(alpha(feathered, x: 50, y: 50), 1, accuracy: 0.02)
        XCTAssertEqual(alpha(feathered, x: 10, y: 10), 0, accuracy: 0.02)
        let edge = alpha(feathered, x: 25, y: 50)
        XCTAssertGreaterThan(edge, 0.02)
        XCTAssertLessThan(edge, 0.98)
    }

    func testShadowIsPaddedSoftSilhouette() throws {
        let shadow = try XCTUnwrap(ObjectEffectsRenderer.shadow(of: squareImage()))
        let pad = ObjectEffectsRenderer.shadowPadding
        XCTAssertEqual(shadow.size.width, 100 * (1 + 2 * pad), accuracy: 0.5)
        let rep = NSBitmapImageRep(cgImage: shadow.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        let centre = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)!
        XCTAssertGreaterThan(centre.alphaComponent, 0.8)
        XCTAssertLessThan(centre.usingColorSpace(.sRGB)!.redComponent, 0.05)
        XCTAssertLessThan(rep.colorAt(x: 1, y: 1)!.alphaComponent, 0.05)
    }
}
