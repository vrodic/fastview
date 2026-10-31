import XCTest
import AppKit
@testable import FastView

final class ObjectRemoverTests: XCTestCase {
    /// A flat background with a square object: the fill should match the background.
    func testPatchFillReplacesObjectWithBackground() {
        let w = 200, h = 150
        var pixels = [Float](repeating: 0, count: w * h * 3)
        var hole = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 3
                // Vertical stripes, 10 px wide.
                let v: Float = (x / 10) % 2 == 0 ? 200 : 60
                pixels[i] = v; pixels[i + 1] = v; pixels[i + 2] = v
                if x >= 80 && x < 120 && y >= 50 && y < 100 {
                    pixels[i] = 255; pixels[i + 1] = 0; pixels[i + 2] = 0
                    hole[y * w + x] = 1
                }
            }
        }
        let start = CFAbsoluteTimeGetCurrent()
        let result = PatchMatchInpainter.inpaint(RGBImage(width: w, height: h, pixels: pixels), hole: hole)
        print("patch fill \(w)x\(h): \(CFAbsoluteTimeGetCurrent() - start) s")

        var redLeft = 0, stripeErrors = 0
        for y in 50..<100 {
            for x in 80..<120 {
                let i = (y * w + x) * 3
                if result.pixels[i] > result.pixels[i + 1] + 50 { redLeft += 1 }
                let expected: Float = (x / 10) % 2 == 0 ? 200 : 60
                if abs(result.pixels[i + 1] - expected) > 50 { stripeErrors += 1 }
            }
        }
        XCTAssertEqual(redLeft, 0, "object colour left in the hole")
        XCTAssertLessThan(stripeErrors, 2000 / 10, "stripes not continued through the hole")
    }

    func testDilateGrowsMask() {
        var mask = [UInt8](repeating: 0, count: 25)
        mask[12] = 1
        let grown = PatchMatchInpainter.dilate(mask, width: 5, height: 5, radius: 1)
        XCTAssertEqual(grown.filter { $0 != 0 }.count, 9)
    }
}

/// Installs and runs the LaMa model from a local copy of its zip (set FASTVIEW_LAMA_ZIP); skipped otherwise.
final class LamaInpainterTests: XCTestCase {
    func testInstallAndInpaint() throws {
        guard let zip = ProcessInfo.processInfo.environment["FASTVIEW_LAMA_ZIP"] else {
            throw XCTSkip("FASTVIEW_LAMA_ZIP not set")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FastViewLamaTest-\(UUID().uuidString)")
        LamaInpainter.modelsDirectory = dir
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(LamaInpainter.shared.install(zipAt: URL(fileURLWithPath: zip)))

        let w = 300, h = 200
        var pixels = [Float](repeating: 0, count: w * h * 3)
        var hole = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 3
                pixels[i] = 40; pixels[i + 1] = 120; pixels[i + 2] = 220   // blue
                if x >= 120 && x < 180 && y >= 70 && y < 130 {
                    pixels[i] = 255; pixels[i + 1] = 0; pixels[i + 2] = 0
                    hole[y * w + x] = 1
                }
            }
        }
        let out = try LamaInpainter.shared.inpaint(RGBImage(width: w, height: h, pixels: pixels), hole: hole)
        XCTAssertEqual(out.width, w)
        XCTAssertEqual(out.height, h)
        // Outside the hole the model returns the image (0...255).
        XCTAssertEqual(out.pixels[0], 40, accuracy: 3)
        XCTAssertEqual(out.pixels[1], 120, accuracy: 3)
        XCTAssertEqual(out.pixels[2], 220, accuracy: 3)
        // The object's red is gone from the hole.
        let i = (100 * w + 150) * 3
        XCTAssertLessThan(out.pixels[i] - out.pixels[i + 1], 100)
    }
}

/// Writes before/after PNGs of a rectangle removed from FASTVIEW_INPAINT_IMAGE into FASTVIEW_INPAINT_OUT,
/// with the patch fill and (when FASTVIEW_LAMA_ZIP is set) the AI model; skipped otherwise.
final class ObjectRemoverVisualTests: XCTestCase {
    func testWriteComparison() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["FASTVIEW_INPAINT_IMAGE"], let outDir = env["FASTVIEW_INPAINT_OUT"],
              let image = NSImage(contentsOfFile: path),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw XCTSkip("FASTVIEW_INPAINT_IMAGE / FASTVIEW_INPAINT_OUT not set")
        }
        var engines: [ObjectRemovalEngine] = [.patchFill]
        if let zip = env["FASTVIEW_LAMA_ZIP"] {
            LamaInpainter.modelsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("FastViewLamaVisual")
            XCTAssertNil(LamaInpainter.shared.install(zipAt: URL(fileURLWithPath: zip)))
            engines.append(.aiModel)
        }
        let w = cg.width, h = cg.height
        var mask = [UInt8](repeating: 0, count: w * h)
        for y in (h * 2 / 5)..<(h * 3 / 5) { for x in (w * 9 / 20)..<(w * 11 / 20) { mask[y * w + x] = 1 } }
        for engine in engines {
            var rgba = try XCTUnwrap(RGBABuffer(cg))
            let start = CFAbsoluteTimeGetCurrent()
            XCTAssertNotNil(ObjectRemover.fill(&rgba, hole: mask, engine: engine, isCancelled: { false }))
            print("\(engine) \(w)x\(h): \(CFAbsoluteTimeGetCurrent() - start) s")
            let out = try XCTUnwrap(rgba.makeCGImage())
            let rep = NSBitmapImageRep(cgImage: out)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("\(engine).png"))
        }
    }
}
