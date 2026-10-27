import AppKit

/// Per-channel affine color change in sRGB (0...1, unpremultiplied): out = in * gain + bias.
public struct ColorAdjustment: Codable, Equatable {
    public var gain: [Double]
    public var bias: [Double]

    public init(gain: [Double], bias: [Double]) {
        self.gain = gain
        self.bias = bias
    }
}

/// Matches objects' colours to a reference object, led by skin tones: when both
/// show enough skin, each RGB channel is scaled so the object's average skin
/// colour becomes the reference's (white balance and exposure of the skin).
/// Otherwise each channel's mean and spread over all opaque pixels are matched.
public enum ColorMatcher {
    public struct Stats: Equatable {
        public var mean: [Double]
        public var std: [Double]
        /// Alpha-weighted pixel count the stats cover.
        public var weight: Double
    }

    /// What an image is matched by: its skin, if it shows enough, and all of it.
    public struct Profile {
        public var skin: Stats?
        public var all: Stats
    }

    private static let statsMaxDimension = 256
    private static let gainRange: ClosedRange<Double> = 0.4...2.5
    private static let skinGainRange: ClosedRange<Double> = 0.5...2.0
    /// Skin must cover this much of the opaque area, and this many pixels, to lead the match.
    private static let minSkinFraction = 0.02
    private static let minSkinWeight = 40.0

    /// Pixel colours (unpremultiplied, 0...1) with their alpha, from a downscaled copy.
    private struct Samples {
        var rgb: [(Double, Double, Double)] = []
        var alpha: [Double] = []
    }

    private static func samples(of image: NSImage) -> Samples? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.width > 0, cg.height > 0 else { return nil }
        let scale = min(1.0, Double(statsMaxDimension) / Double(max(cg.width, cg.height)))
        let w = max(1, Int(Double(cg.width) * scale))
        let h = max(1, Int(Double(cg.height) * scale))
        guard let pixels = rgbaPixels(of: cg, width: w, height: h) else { return nil }

        var out = Samples()
        out.rgb.reserveCapacity(w * h)
        out.alpha.reserveCapacity(w * h)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255.0
            guard a > 0.05 else { continue }
            // Premultiplied in the bitmap: dividing by alpha gives the colour itself.
            out.rgb.append((min(1, Double(pixels[i]) / 255.0 / a),
                            min(1, Double(pixels[i + 1]) / 255.0 / a),
                            min(1, Double(pixels[i + 2]) / 255.0 / a)))
            out.alpha.append(a)
        }
        return out.alpha.isEmpty ? nil : out
    }

    private static func stats(_ samples: Samples, where include: ((Double, Double, Double)) -> Bool = { _ in true }) -> Stats? {
        var sum = [0.0, 0.0, 0.0]
        var sumSq = [0.0, 0.0, 0.0]
        var weight = 0.0
        for (px, a) in zip(samples.rgb, samples.alpha) where include(px) {
            let v = [px.0, px.1, px.2]
            for c in 0..<3 {
                sum[c] += v[c] * a
                sumSq[c] += v[c] * v[c] * a
            }
            weight += a
        }
        guard weight > 0 else { return nil }
        let mean = sum.map { $0 / weight }
        let std = (0..<3).map { c in max(0, sumSq[c] / weight - mean[c] * mean[c]).squareRoot() }
        return Stats(mean: mean, std: std, weight: weight)
    }

    /// Skin test in YCbCr (BT.601), on 0...1 RGB. Clipped highlights and deep shadows are left out.
    static func isSkin(_ r: Double, _ g: Double, _ b: Double) -> Bool {
        guard max(r, g, b) < 0.97 else { return false }
        let y = 255 * (0.299 * r + 0.587 * g + 0.114 * b)
        let cb = 128 + 255 * (-0.168736 * r - 0.331264 * g + 0.5 * b)
        let cr = 128 + 255 * (0.5 * r - 0.418688 * g - 0.081312 * b)
        return y > 45 && (77...127).contains(cb) && (133...173).contains(cr) && r > b
    }

    /// Stats of the image's skin, or nil when it shows too little. A colour cast can hide
    /// skin from the test, so a grey-world balanced copy is tried when the image itself finds too little.
    private static func skinStats(_ samples: Samples, all: Stats) -> Stats? {
        let enough: (Stats?) -> Bool = { s in
            guard let s = s else { return false }
            return s.weight >= minSkinWeight && s.weight / all.weight >= minSkinFraction
        }
        let direct = stats(samples) { isSkin($0.0, $0.1, $0.2) }
        if enough(direct) { return direct }

        let grey = all.mean.reduce(0, +) / 3
        let balance = all.mean.map { $0 > 0.01 ? grey / $0 : 1 }
        let balanced = stats(samples) {
            isSkin(min(1, $0.0 * balance[0]), min(1, $0.1 * balance[1]), min(1, $0.2 * balance[2]))
        }
        return enough(balanced) ? balanced : nil
    }

    public static func profile(of image: NSImage) -> Profile? {
        guard let samples = samples(of: image), let all = stats(samples) else { return nil }
        return Profile(skin: skinStats(samples, all: all), all: all)
    }

    /// Mean and standard deviation of each channel over all opaque pixels, weighted by alpha.
    public static func stats(of image: NSImage) -> Stats? {
        samples(of: image).flatMap { stats($0) }
    }

    /// The change that makes `source` match `reference`, and whether skin led it.
    public static func adjustment(matching source: Profile, to reference: Profile) -> (adjustment: ColorAdjustment, bySkin: Bool) {
        if let srcSkin = source.skin, let refSkin = reference.skin {
            let gain = (0..<3).map { c -> Double in
                let g = srcSkin.mean[c] > 0.01 ? refSkin.mean[c] / srcSkin.mean[c] : 1
                return min(max(g, skinGainRange.lowerBound), skinGainRange.upperBound)
            }
            return (ColorAdjustment(gain: gain, bias: [0, 0, 0]), true)
        }
        return (adjustment(matching: source.all, to: reference.all), false)
    }

    /// Matches each channel's mean and spread.
    public static func adjustment(matching source: Stats, to reference: Stats) -> ColorAdjustment {
        var gain = [1.0, 1.0, 1.0]
        var bias = [0.0, 0.0, 0.0]
        for c in 0..<3 {
            let g = source.std[c] > 0.001 ? reference.std[c] / source.std[c] : 1.0
            gain[c] = min(max(g, gainRange.lowerBound), gainRange.upperBound)
            bias[c] = reference.mean[c] - gain[c] * source.mean[c]
        }
        return ColorAdjustment(gain: gain, bias: bias)
    }

    /// The image with `adjustment` applied; transparency is unchanged.
    public static func apply(_ adjustment: ColorAdjustment, to image: NSImage) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              var pixels = rgbaPixels(of: cg, width: cg.width, height: cg.height) else { return nil }

        // Opaque pixels, which are most of an object, go through a table.
        var lut = [[UInt8]](repeating: [UInt8](repeating: 0, count: 256), count: 3)
        for c in 0..<3 {
            for v in 0..<256 {
                lut[c][v] = clampByte((Double(v) / 255.0 * adjustment.gain[c] + adjustment.bias[c]) * 255.0)
            }
        }

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = pixels[i + 3]
            if a == 255 {
                pixels[i] = lut[0][Int(pixels[i])]
                pixels[i + 1] = lut[1][Int(pixels[i + 1])]
                pixels[i + 2] = lut[2][Int(pixels[i + 2])]
            } else if a > 0 {
                let af = Double(a) / 255.0
                for c in 0..<3 {
                    let v = min(1.0, Double(pixels[i + c]) / 255.0 / af)
                    let out = min(max(v * adjustment.gain[c] + adjustment.bias[c], 0), 1)
                    pixels[i + c] = clampByte(out * af * 255.0)
                }
            }
        }

        let width = cg.width
        let height = cg.height
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let out = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else { return nil }
        return NSImage(cgImage: out, size: image.size)
    }

    private static func clampByte(_ v: Double) -> UInt8 {
        UInt8(min(max(v.rounded(), 0), 255))
    }

    /// Premultiplied sRGB RGBA bytes of `image` drawn at the given size.
    private static func rgbaPixels(of image: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }
}
