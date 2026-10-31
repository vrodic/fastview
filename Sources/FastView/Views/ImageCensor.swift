import AppKit
import CoreImage
import Vision

/// How a censored area is hidden.
public enum CensorStyle: String, CaseIterable {
    case pixelate
    case blur
    case blackBox
    case bar

    public var title: String {
        switch self {
        case .pixelate: return "Pixelate"
        case .blur: return "Blur"
        case .blackBox: return "Black Box"
        case .bar: return "Censored Bar"
        }
    }
}

/// The shape drawn to mark an area.
public enum CensorShape: String, CaseIterable {
    case rectangle
    case ellipse
    case freehand

    public var symbolName: String {
        switch self {
        case .rectangle: return "rectangle"
        case .ellipse: return "oval"
        case .freehand: return "scribble"
        }
    }
}

/// Censor settings, remembered between launches.
public struct CensorSettings {
    public var style: CensorStyle
    public var shape: CensorShape
    /// 0...1: block size for pixelate, radius for blur.
    public var strength: Double

    public static var saved: CensorSettings {
        get {
            let d = UserDefaults.standard
            return CensorSettings(
                style: CensorStyle(rawValue: d.string(forKey: "FastViewCensorStyle") ?? "") ?? .pixelate,
                shape: CensorShape(rawValue: d.string(forKey: "FastViewCensorShape") ?? "") ?? .rectangle,
                strength: d.object(forKey: "FastViewCensorStrength") as? Double ?? 0.5)
        }
        set {
            let d = UserDefaults.standard
            d.set(newValue.style.rawValue, forKey: "FastViewCensorStyle")
            d.set(newValue.shape.rawValue, forKey: "FastViewCensorShape")
            d.set(newValue.strength, forKey: "FastViewCensorStrength")
        }
    }
}

/// Hides areas of an image. Areas are polygons as fractions of the image (bottom-left origin).
/// Pure functions; call off the main thread.
public enum ImageCensor {
    private static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    /// The image with every area hidden in `style`. `textRotation` turns the bar's label so it reads
    /// upright on screen (the inverse of the display orientation), `textFlipped` mirrors it back.
    public static func censor(_ image: NSImage, areas: [[CGPoint]], style: CensorStyle, strength: Double,
                              textRotation: CGFloat = 0, textFlipped: (h: Bool, v: Bool) = (false, false)) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), !areas.isEmpty else { return nil }
        let w = cg.width, h = cg.height
        let paths = areas.filter { $0.count > 2 }.map { area -> CGPath in
            let path = CGMutablePath()
            path.addLines(between: area.map { CGPoint(x: $0.x * CGFloat(w), y: $0.y * CGFloat(h)) })
            path.closeSubpath()
            return path
        }
        guard !paths.isEmpty else { return nil }

        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.draw(cg, in: full)

        for path in paths {
            let box = path.boundingBoxOfPath.intersection(full)
            guard !box.isNull, box.width >= 1, box.height >= 1 else { continue }
            let side = Double(min(box.width, box.height))
            switch style {
            case .pixelate, .blur:
                guard let hidden = filtered(cg, style: style, side: side, strength: strength, around: box) else { continue }
                ctx.saveGState()
                ctx.addPath(path)
                ctx.clip()
                ctx.draw(hidden, in: full)
                ctx.restoreGState()
            case .blackBox:
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.addPath(path)
                ctx.fillPath()
            case .bar:
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.addPath(path)
                ctx.fillPath()
                drawLabel(in: ctx, box: box, rotation: textRotation, flipped: textFlipped)
            }
        }
        guard let out = ctx.makeImage() else { return nil }
        return NSImage(cgImage: out, size: image.size)
    }

    /// The whole image pixelated or blurred at a size suited to an area of `side` pixels.
    private static func filtered(_ cg: CGImage, style: CensorStyle, side: Double, strength: Double, around box: CGRect) -> CGImage? {
        let input = CIImage(cgImage: cg)
        let extent = input.extent
        let output: CIImage
        if style == .pixelate {
            // 6 to 20 blocks across the area's short side, never smaller than 6 px.
            let blocks = 20 - 14 * strength
            output = input.clampedToExtent()
                .applyingFilter("CIPixellate", parameters: [
                    kCIInputScaleKey: max(6, side / blocks),
                    kCIInputCenterKey: CIVector(x: box.minX, y: box.minY),
                ])
                .cropped(to: extent)
        } else {
            output = input.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(4, side * (0.04 + 0.16 * strength))])
                .cropped(to: extent)
        }
        return context.createCGImage(output, from: extent)
    }

    /// "CENSORED" in white, as large as fits the area, upright on screen.
    private static func drawLabel(in ctx: CGContext, box: CGRect, rotation: CGFloat, flipped: (h: Bool, v: Bool)) {
        let quarterTurn = Int((rotation / 90).rounded()) % 2 != 0
        let across = quarterTurn ? box.height : box.width
        let tall = quarterTurn ? box.width : box.height
        let text = "CENSORED" as NSString
        var fontSize = min(tall * 0.6, across / 6)
        guard fontSize >= 4 else { return }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .heavy),
            .foregroundColor: NSColor.white,
            .kern: fontSize * 0.12,
        ]
        var size = text.size(withAttributes: attributes)
        if size.width > across * 0.9 {
            fontSize *= across * 0.9 / size.width
            attributes[.font] = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
            attributes[.kern] = fontSize * 0.12
            size = text.size(withAttributes: attributes)
        }
        ctx.saveGState()
        ctx.translateBy(x: box.midX, y: box.midY)
        ctx.rotate(by: rotation * .pi / 180)
        ctx.scaleBy(x: flipped.h ? -1 : 1, y: flipped.v ? -1 : 1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        text.draw(at: NSPoint(x: -size.width / 2, y: -size.height / 2), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    /// Faces in the image, as ellipses a little larger than each face (fractions, bottom-left origin).
    public static func faceAreas(in image: NSImage) -> [[CGPoint]] {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let request = VNDetectFaceRectanglesRequest()
        guard (try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])) != nil else { return [] }
        return (request.results ?? []).map { face in
            let box = face.boundingBox
            // Faces are found from brows to chin; widen to cover hair and ears.
            let rect = CGRect(x: box.midX - box.width * 0.65, y: box.midY - box.height * 0.7,
                              width: box.width * 1.3, height: box.height * 1.5)
            return ellipse(in: rect)
        }
    }

    /// An ellipse as a polygon.
    public static func ellipse(in rect: CGRect, segments: Int = 64) -> [CGPoint] {
        (0..<segments).map { i in
            let a = Double(i) / Double(segments) * 2 * .pi
            return CGPoint(x: rect.midX + rect.width / 2 * cos(a), y: rect.midY + rect.height / 2 * sin(a))
        }
    }

    /// A rectangle as a polygon.
    public static func rectangle(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }
}
