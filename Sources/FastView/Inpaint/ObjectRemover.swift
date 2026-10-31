import AppKit
import Vision

/// Which inpainter fills the hole an object leaves (Options → Object Removal).
public enum ObjectRemovalEngine: String {
    case patchFill
    case aiModel

    private static let defaultsKey = "FastViewObjectRemovalEngine"

    public static var current: ObjectRemovalEngine {
        get { ObjectRemovalEngine(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .patchFill }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// The engine actually used: the AI model only once it is downloaded.
    static var effective: ObjectRemovalEngine {
        current == .aiModel && LamaInpainter.shared.isInstalled ? .aiModel : .patchFill
    }
}

/// Removes an object from an image: builds its mask (Vision foreground mask, or a drawn outline),
/// fills a crop around it with the chosen inpainter and blends the fill back in.
public enum ObjectRemover {
    /// Longest side the patch fill works at; larger crops are filled scaled down.
    private static let patchFillMaxSide = 1024

    /// `outline`: the area to remove as fractions of `image` (bottom-left origin); nil removes
    /// Vision's detected foreground. Completion runs on the main queue with the new image or an error message.
    public static func remove(from image: NSImage, outline: [CGPoint]?, isCancelled: @escaping () -> Bool, completion: @escaping (NSImage?, String?) -> Void) {
        let engine = ObjectRemovalEngine.effective
        DispatchQueue.global(qos: .userInitiated).async {
            let result: (NSImage?, String?) = autoreleasepool {
                guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      var rgba = RGBABuffer(cg) else { return (nil, "The image could not be read.") }
                let mask: [UInt8]
                if let outline = outline {
                    mask = rasterize(outline, width: rgba.width, height: rgba.height)
                } else {
                    guard let detected = foregroundMask(cg) else { return (nil, "No foreground object was found.") }
                    mask = detected
                }
                guard fill(&rgba, hole: mask, engine: engine, isCancelled: isCancelled) != nil else {
                    return (nil, isCancelled() ? nil : "There is nothing to remove.")
                }
                guard let out = rgba.makeCGImage() else { return (nil, "The result could not be created.") }
                return (NSImage(cgImage: out, size: image.size), nil)
            }
            DispatchQueue.main.async {
                if isCancelled() { return }
                completion(result.0, result.1)
            }
        }
    }

    // MARK: - Masks

    private static func foregroundMask(_ cg: CGImage) -> [UInt8]? {
        guard #available(macOS 14.0, *) else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first, !observation.allInstances.isEmpty,
              let buffer = try? observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler) else { return nil }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard w == cg.width, h == cg.height else { return nil }
        var mask = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = (base + y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<w where row[x] > 0.3 { mask[y * w + x] = 1 }
        }
        return mask
    }

    /// Fills the polygon into a top-left-origin byte mask.
    private static func rasterize(_ outline: [CGPoint], width: Int, height: Int) -> [UInt8] {
        var mask = [UInt8](repeating: 0, count: width * height)
        guard outline.count > 2 else { return mask }
        mask.withUnsafeMutableBytes { bytes in
            guard let ctx = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.move(to: CGPoint(x: outline[0].x * CGFloat(width), y: outline[0].y * CGFloat(height)))
            for p in outline.dropFirst() { ctx.addLine(to: CGPoint(x: p.x * CGFloat(width), y: p.y * CGFloat(height))) }
            ctx.closePath()
            ctx.fillPath()
        }
        // The context drew 255 (white); any non-zero byte is hole.
        return mask
    }

    // MARK: - Filling

    /// Fills the hole in place; returns nil when the mask is empty or the work was cancelled.
    @discardableResult
    static func fill(_ rgba: inout RGBABuffer, hole fullMask: [UInt8], engine: ObjectRemovalEngine, isCancelled: () -> Bool) -> Bool? {
        let W = rgba.width, H = rgba.height
        var minX = W, minY = H, maxX = -1, maxY = -1
        for y in 0..<H {
            for x in 0..<W where fullMask[y * W + x] != 0 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        // Grow the hole so the object's edge and shadow fringe go too; take context around it to copy from.
        let grow = max(4, max(W, H) / 250)
        let holeW = maxX - minX + 1, holeH = maxY - minY + 1
        let margin = max(32, max(holeW, holeH))
        let cx0 = max(0, minX - margin), cy0 = max(0, minY - margin)
        let cx1 = min(W - 1, maxX + margin), cy1 = min(H - 1, maxY + margin)
        let cw = cx1 - cx0 + 1, ch = cy1 - cy0 + 1

        var cropHole = [UInt8](repeating: 0, count: cw * ch)
        var crop = RGBImage(width: cw, height: ch, pixels: [Float](repeating: 0, count: cw * ch * 3))
        for y in 0..<ch {
            for x in 0..<cw {
                let s = (cy0 + y) * W + (cx0 + x)
                cropHole[y * cw + x] = fullMask[s]
                crop.pixels[(y * cw + x) * 3] = Float(rgba.pixels[s * 4])
                crop.pixels[(y * cw + x) * 3 + 1] = Float(rgba.pixels[s * 4 + 1])
                crop.pixels[(y * cw + x) * 3 + 2] = Float(rgba.pixels[s * 4 + 2])
            }
        }
        cropHole = PatchMatchInpainter.dilate(cropHole, width: cw, height: ch, radius: grow)

        let filled: RGBImage
        switch engine {
        case .aiModel:
            if let result = try? LamaInpainter.shared.inpaint(crop, hole: cropHole) {
                filled = result
            } else {
                filled = patchFill(crop, hole: cropHole, isCancelled: isCancelled)
            }
        case .patchFill:
            filled = patchFill(crop, hole: cropHole, isCancelled: isCancelled)
        }
        if isCancelled() { return nil }

        // Blend: the hole takes the fill, with a short ramp just outside it.
        let feather = 2
        let outer = PatchMatchInpainter.dilate(cropHole, width: cw, height: ch, radius: feather)
        for y in 0..<ch {
            for x in 0..<cw where outer[y * cw + x] != 0 {
                var alpha: Float = 1
                if cropHole[y * cw + x] == 0 {
                    var near = 0
                    for dy in -feather...feather {
                        for dx in -feather...feather {
                            let nx = x + dx, ny = y + dy
                            if nx >= 0, nx < cw, ny >= 0, ny < ch, cropHole[ny * cw + nx] != 0 { near += 1 }
                        }
                    }
                    alpha = Float(near) / Float((2 * feather + 1) * (2 * feather + 1))
                }
                let s = ((cy0 + y) * W + (cx0 + x)) * 4
                let f = (y * cw + x) * 3
                for c in 0..<3 {
                    let v = Float(rgba.pixels[s + c]) * (1 - alpha) + filled.pixels[f + c] * alpha
                    rgba.pixels[s + c] = UInt8(max(0, min(255, v.rounded())))
                }
                rgba.pixels[s + 3] = 255
            }
        }
        return true
    }

    private static func patchFill(_ crop: RGBImage, hole: [UInt8], isCancelled: () -> Bool) -> RGBImage {
        let scale = min(1.0, Double(patchFillMaxSide) / Double(max(crop.width, crop.height)))
        guard scale < 1 else { return PatchMatchInpainter.inpaint(crop, hole: hole, isCancelled: isCancelled) }
        let sw = max(8, Int(Double(crop.width) * scale)), sh = max(8, Int(Double(crop.height) * scale))
        let small = PatchMatchInpainter.upsample(crop, toWidth: sw, height: sh)
        var smallHole = [UInt8](repeating: 0, count: sw * sh)
        for y in 0..<crop.height {
            for x in 0..<crop.width where hole[y * crop.width + x] != 0 {
                smallHole[min(sh - 1, y * sh / crop.height) * sw + min(sw - 1, x * sw / crop.width)] = 1
            }
        }
        let result = PatchMatchInpainter.inpaint(small, hole: smallHole, isCancelled: isCancelled)
        return PatchMatchInpainter.upsample(result, toWidth: crop.width, height: crop.height)
    }
}

/// 8-bit RGBA pixels (sRGB, top-left origin, alpha premultiplied).
struct RGBABuffer {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    init?(_ cg: CGImage) {
        width = cg.width
        height = cg.height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ok: Bool = pixels.withUnsafeMutableBytes { bytes in
            guard let ctx = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
    }

    func makeCGImage() -> CGImage? {
        var copy = pixels
        return copy.withUnsafeMutableBytes { bytes in
            CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }
}
