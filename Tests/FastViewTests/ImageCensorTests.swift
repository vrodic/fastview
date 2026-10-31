import XCTest
import AppKit
@testable import FastView

final class ImageCensorTests: XCTestCase {
    /// 200×100 image: left half a fine black/white checkerboard, right half plain grey.
    private func testImage() -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<100 {
            for x in 0..<200 {
                let v: CGFloat = x >= 100 ? 0.5 : ((x / 2 + y / 2) % 2 == 0 ? 1 : 0)
                rep.setColor(NSColor(deviceRed: v, green: v, blue: v, alpha: 1), atX: x, y: y)
            }
        }
        let image = NSImage(size: NSSize(width: 200, height: 100))
        // Tagged sRGB like the censor output, so untouched pixels compare equal.
        image.addRepresentation(rep.retagging(with: .sRGB)!)
        return image
    }

    private func pixels(_ image: NSImage) -> NSBitmapImageRep {
        NSBitmapImageRep(cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
    }

    /// The checkerboard's left half, as fractions.
    private let area = ImageCensor.rectangle(CGRect(x: 0.05, y: 0.1, width: 0.4, height: 0.8))

    func testEveryStyleHidesTheAreaAndLeavesTheRest() throws {
        let original = pixels(testImage())
        for style in CensorStyle.allCases {
            let out = pixels(try XCTUnwrap(ImageCensor.censor(testImage(), areas: [area], style: style, strength: 0.5), "\(style)"))
            XCTAssertEqual(out.pixelsWide, 200)
            // Outside the area: unchanged.
            XCTAssertEqual(out.colorAt(x: 150, y: 50)!.whiteComponentValue, original.colorAt(x: 150, y: 50)!.whiteComponentValue, accuracy: 0.02, "\(style)")
            // Inside: the checkerboard's alternation is gone (neighbouring pixels no longer differ fully).
            // The bar's white lettering is detail of its own, so it is checked for being mostly black instead.
            if style == .bar {
                let dark = (30..<70).filter { out.colorAt(x: $0, y: 20)!.whiteComponentValue < 0.1 }.count
                XCTAssertGreaterThan(dark, 35)
                continue
            }
            var strongEdges = 0
            for x in 30..<70 {
                let a = out.colorAt(x: x, y: 50)!.whiteComponentValue, b = out.colorAt(x: x + 2, y: 50)!.whiteComponentValue
                if abs(a - b) > 0.9 { strongEdges += 1 }
            }
            XCTAssertLessThan(strongEdges, 5, "\(style) left the detail visible")
        }
    }

    func testBlackBoxIsBlack() throws {
        let out = pixels(try XCTUnwrap(ImageCensor.censor(testImage(), areas: [area], style: .blackBox, strength: 0.5)))
        XCTAssertEqual(out.colorAt(x: 50, y: 50)!.whiteComponentValue, 0, accuracy: 0.01)
    }

    func testNoFacesInPattern() {
        XCTAssertTrue(ImageCensor.faceAreas(in: testImage()).isEmpty)
    }

    /// Writes every style over a region of FASTVIEW_INPAINT_IMAGE into FASTVIEW_INPAINT_OUT; skipped otherwise.
    func testWriteStyleSamples() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["FASTVIEW_INPAINT_IMAGE"], let outDir = env["FASTVIEW_INPAINT_OUT"],
              let image = NSImage(contentsOfFile: path) else { throw XCTSkip("FASTVIEW_INPAINT_IMAGE / FASTVIEW_INPAINT_OUT not set") }
        let areas = [ImageCensor.rectangle(CGRect(x: 0.62, y: 0.45, width: 0.2, height: 0.12)),
                     ImageCensor.ellipse(in: CGRect(x: 0.25, y: 0.1, width: 0.2, height: 0.25))]
        for style in CensorStyle.allCases {
            let out = try XCTUnwrap(ImageCensor.censor(image, areas: areas, style: style, strength: 0.5))
            let rep = NSBitmapImageRep(cgImage: out.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
            try rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])!
                .write(to: URL(fileURLWithPath: outDir).appendingPathComponent("censor_\(style.rawValue).jpg"))
        }
    }
}

private extension NSColor {
    var whiteComponentValue: CGFloat { usingColorSpace(.deviceGray)?.whiteComponent ?? 0 }
}
