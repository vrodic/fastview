import AppKit
import Vision
import CoreImage

/// A freehand outline drawn over a foreground object: the object keeps only what is
/// inside it (carve out), or loses what is inside it (erase). A carve-out can also run
/// foreground detection on what it keeps, so only the subject inside the outline stays.
public struct ObjectCarve: Codable, Equatable {
    /// Outline as fractions of the object image at the time of carving (bottom-left origin).
    public var points: [CGPoint]
    public var keepsInside: Bool
    public var detectsForeground: Bool

    public init(points: [CGPoint], keepsInside: Bool, detectsForeground: Bool = false) {
        self.points = points
        self.keepsInside = keepsInside
        self.detectsForeground = detectsForeground
    }

    private enum CodingKeys: String, CodingKey { case points, keepsInside, detectsForeground }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        points = try c.decode([[Double]].self, forKey: .points).compactMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        keepsInside = try c.decode(Bool.self, forKey: .keepsInside)
        detectsForeground = try c.decodeIfPresent(Bool.self, forKey: .detectsForeground) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(points.map { [Double($0.x), Double($0.y)] }, forKey: .points)
        try c.encode(keepsInside, forKey: .keepsInside)
        try c.encode(detectsForeground, forKey: .detectsForeground)
    }
}

public enum ObjectCarver {
    private static let ciContext = CIContext()

    /// Vision's foreground mask of `image` (white where any instance is), or nil when it
    /// finds none. The image is put over mid grey first, so its transparent surround does
    /// not read as black. Slow: call off the main thread.
    public static func foregroundMask(of image: CGImage) -> CIImage? {
        guard #available(macOS 14.0, *) else { return nil }
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        guard let flattened = ctx.makeImage() else { return nil }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: flattened, options: [:])
        do {
            try handler.perform([request])
            guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
            let mask = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
            return CIImage(cvPixelBuffer: mask)
        } catch {
            print("[ObjectCarver] Foreground mask error: \(error)")
            return nil
        }
    }

    /// `image` keeping only where `mask` (red channel, same pixel size) is set.
    public static func applyMask(_ mask: CIImage, to image: CGImage, size: NSSize) -> NSImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIBlendWithRedMask") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(CIImage(color: .clear).cropped(to: input.extent), forKey: kCIInputBackgroundImageKey)
        filter.setValue(mask, forKey: kCIInputMaskImageKey)
        guard let output = filter.outputImage, let cg = ciContext.createCGImage(output, from: input.extent) else { return nil }
        return NSImage(cgImage: cg, size: size)
    }

    /// The part of the image a carve leaves, as fractions of the image (bottom-left origin):
    /// the outline's bounds for a carve-out, the whole image for an erase.
    public static func keptRect(of carve: ObjectCarve) -> CGRect {
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard carve.keepsInside, let first = carve.points.first else { return full }
        var box = CGRect(origin: first, size: .zero)
        for p in carve.points.dropFirst() { box = box.union(CGRect(origin: p, size: .zero)) }
        let kept = box.intersection(full)
        return kept.isNull ? full : kept
    }

    /// `image` carved by `carve` and, for a carve-out, cropped to `keptRect(of:)` on whole
    /// pixels, with the rect it was cropped to (fractions of `image`, bottom-left origin);
    /// nil when nothing would be left. `size` is the image's size in points; the result
    /// keeps the same points-per-pixel. Safe off the main thread.
    public static func apply(_ carve: ObjectCarve, to image: CGImage, size: NSSize) -> (image: NSImage, rect: CGRect)? {
        guard carve.points.count > 2 else { return nil }
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        let path = CGMutablePath()
        path.addLines(between: carve.points.map { CGPoint(x: $0.x * CGFloat(w), y: $0.y * CGFloat(h)) })
        path.closeSubpath()

        if carve.keepsInside {
            ctx.addPath(path)
            ctx.clip()
            ctx.draw(image, in: full)
        } else {
            ctx.draw(image, in: full)
            ctx.addPath(path)
            ctx.setBlendMode(.clear)
            ctx.fillPath()
        }
        guard let carved = ctx.makeImage() else { return nil }

        let kept = keptRect(of: carve)
        // CGImage cropping counts rows from the top.
        let pixelRect = CGRect(x: kept.minX * CGFloat(w), y: (1 - kept.maxY) * CGFloat(h),
                               width: kept.width * CGFloat(w), height: kept.height * CGFloat(h)).integral.intersection(full)
        guard pixelRect.width >= 2 && pixelRect.height >= 2, let cropped = carved.cropping(to: pixelRect) else { return nil }
        let rect = CGRect(x: pixelRect.minX / CGFloat(w), y: 1 - pixelRect.maxY / CGFloat(h),
                          width: pixelRect.width / CGFloat(w), height: pixelRect.height / CGFloat(h))
        let out = NSImage(cgImage: cropped, size: NSSize(width: size.width * rect.width, height: size.height * rect.height))
        return (out, rect)
    }
}

// MARK: - Edge snapping

extension ObjectCarver {
    /// Long side of the copy edges are found on.
    private static let edgeAnalysisDimension = 1024

    /// `points` (a closed outline, fractions of `image`, bottom-left origin) moved onto the
    /// strongest nearby edges of `image`, like a magnetic lasso. Each point may move along the
    /// outline's normal within a band; dynamic programming picks the moves that follow edges
    /// while keeping the outline smooth, so where there is no edge it stays as drawn.
    /// Slow: call off the main thread.
    public static func snapToEdges(_ points: [CGPoint], in image: CGImage) -> [CGPoint] {
        guard points.count > 2 else { return points }
        let scale = min(1, CGFloat(edgeAnalysisDimension) / CGFloat(max(image.width, image.height)))
        let w = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let h = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let edges = edgeStrength(of: image, width: w, height: h) else { return points }

        // Work in analysis pixels, y up like the outline.
        let outline = resampled(points.map { CGPoint(x: $0.x * CGFloat(w), y: $0.y * CGFloat(h)) }, spacing: 3, maxCount: 600)
        let n = outline.count
        guard n > 2 else { return points }
        let band = max(6, max(w, h) / 60)
        let k = 2 * band + 1
        let normals: [CGPoint] = (0..<n).map { i in
            let a = outline[(i + n - 1) % n], b = outline[(i + 1) % n]
            let dx = b.x - a.x, dy = b.y - a.y
            let len = max(0.0001, hypot(dx, dy))
            return CGPoint(x: -dy / len, y: dx / len)
        }
        let sample: (CGPoint) -> Float = { p in
            let x = Int(p.x.rounded()), y = h - 1 - Int(p.y.rounded())
            guard x >= 0, y >= 0, x < w, y < h else { return 0 }
            return edges[y * w + x]
        }

        // Cost of each candidate: weak edge, and a little for straying from the drawn line.
        let distancePrior: Float = 0.15
        let smoothness: Float = 0.06
        var unary = [Float](repeating: 0, count: n * k)
        for i in 0..<n {
            for j in 0..<k {
                let offset = CGFloat(j - band)
                let p = CGPoint(x: outline[i].x + normals[i].x * offset, y: outline[i].y + normals[i].y * offset)
                unary[i * k + j] = -sample(p) + distancePrior * Float(abs(j - band)) / Float(band)
            }
        }

        // Viterbi along the outline (the seam where it closes is left free).
        var total = Array(unary[0..<k])
        var back = [Int](repeating: 0, count: n * k)
        for i in 1..<n {
            var next = [Float](repeating: 0, count: k)
            for j in 0..<k {
                var best = Float.greatestFiniteMagnitude, bestFrom = j
                for from in max(0, j - band)...min(k - 1, j + band) {
                    let c = total[from] + smoothness * Float(abs(j - from))
                    if c < best { best = c; bestFrom = from }
                }
                next[j] = best + unary[i * k + j]
                back[i * k + j] = bestFrom
            }
            total = next
        }
        var j = total.indices.min { total[$0] < total[$1] } ?? band
        var chosen = [Int](repeating: band, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            chosen[i] = j
            j = back[i * k + j]
        }

        return (0..<n).map { i in
            let offset = CGFloat(chosen[i] - band)
            return CGPoint(x: (outline[i].x + normals[i].x * offset) / CGFloat(w),
                           y: (outline[i].y + normals[i].y * offset) / CGFloat(h))
        }
    }

    /// Edge strength (0...1) of `image` at `width`×`height`, top row first. The image is put
    /// over mid grey so the object's own outline counts as an edge, and blurred a little so
    /// texture does not.
    private static func edgeStrength(of image: CGImage, width w: Int, height h: Int) -> [Float]? {
        let input = CIImage(cgImage: image)
        let scaled = input.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / CGFloat(image.width), y: CGFloat(h) / CGFloat(image.height)))
        let extent = CGRect(x: 0, y: 0, width: w, height: h)
        let grey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
        let edgesImage = scaled.composited(over: grey)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 1.0)
            .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 4.0])
            .applyingFilter("CIMaximumComponent")
            .cropped(to: extent)

        var bytes = [UInt8](repeating: 0, count: w * h)
        bytes.withUnsafeMutableBytes { buffer in
            ciContext.render(edgesImage, toBitmap: buffer.baseAddress!, rowBytes: w, bounds: extent, format: .L8, colorSpace: nil)
        }
        // Scale so the strongest edges (98th percentile) are 1.
        var histogram = [Int](repeating: 0, count: 256)
        for b in bytes { histogram[Int(b)] += 1 }
        var seen = 0, top = 255
        for v in stride(from: 255, through: 1, by: -1) {
            seen += histogram[v]
            if seen >= (w * h) / 50 { top = v; break }
        }
        let norm = 1 / Float(max(1, top))
        return bytes.map { min(1, Float($0) * norm) }
    }

    /// The closed outline with points every `spacing` along it, at most `maxCount` of them.
    private static func resampled(_ points: [CGPoint], spacing: CGFloat, maxCount: Int) -> [CGPoint] {
        var lengths: [CGFloat] = []
        var perimeter: CGFloat = 0
        for i in 0..<points.count {
            let a = points[i], b = points[(i + 1) % points.count]
            let d = hypot(b.x - a.x, b.y - a.y)
            lengths.append(d)
            perimeter += d
        }
        guard perimeter > 0 else { return points }
        let count = min(maxCount, max(3, Int(perimeter / spacing)))
        let step = perimeter / CGFloat(count)
        var out: [CGPoint] = []
        var segment = 0, along: CGFloat = 0
        for s in 0..<count {
            let target = CGFloat(s) * step
            while segment < points.count - 1 && along + lengths[segment] < target {
                along += lengths[segment]
                segment += 1
            }
            let a = points[segment], b = points[(segment + 1) % points.count]
            let t = lengths[segment] > 0 ? (target - along) / lengths[segment] : 0
            out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        return out
    }
}
