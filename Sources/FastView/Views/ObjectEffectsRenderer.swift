import AppKit
import CoreImage

/// Builds the images behind an object's effects (feathered edges, drop shadow) from its alpha.
/// Pure functions; call off the main thread.
public enum ObjectEffectsRenderer {
    /// How far the shadow drops, as a fraction of the object's longer side.
    public static let shadowDrop: CGFloat = 0.02
    /// Room around the shadow image for its blur, as a fraction of each side.
    public static let shadowPadding: CGFloat = 0.08

    private static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    /// The image with its alpha shrunk and softened over ~0.6% of its size, so edges fade instead of cutting.
    public static func feather(_ image: NSImage) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        let extent = input.extent
        let radius = max(1.5, Double(max(cg.width, cg.height)) * 0.006)

        let mask = alphaAsGray(input)
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: radius * 0.6])
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)
        let output = input.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty().cropped(to: extent),
            kCIInputMaskImageKey: mask,
        ])
        guard let out = context.createCGImage(output, from: extent) else { return nil }
        return NSImage(cgImage: out, size: image.size)
    }

    /// A soft black silhouette of the image, padded by `shadowPadding` on every side.
    public static func shadow(of image: NSImage) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        let padX = CGFloat(cg.width) * shadowPadding, padY = CGFloat(cg.height) * shadowPadding
        let outExtent = input.extent.insetBy(dx: -padX, dy: -padY)
        let radius = Double(max(cg.width, cg.height)) * 0.03

        let alpha = alphaAsGray(input)
            .composited(over: CIImage(color: .black).cropped(to: outExtent))
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: outExtent)
        // Black, with the blurred silhouette as alpha.
        let silhouette = CIImage(color: .black).cropped(to: outExtent)
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty().cropped(to: outExtent),
                kCIInputMaskImageKey: alpha,
            ])
        guard let out = context.createCGImage(silhouette, from: outExtent) else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: image.size.width * (1 + 2 * shadowPadding),
                                                  height: image.size.height * (1 + 2 * shadowPadding)))
    }

    /// Grey image whose brightness is the input's alpha (opaque).
    private static func alphaAsGray(_ image: CIImage) -> CIImage {
        let fromAlpha = CIVector(x: 0, y: 0, z: 0, w: 1)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": fromAlpha,
            "inputGVector": fromAlpha,
            "inputBVector": fromAlpha,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }
}
