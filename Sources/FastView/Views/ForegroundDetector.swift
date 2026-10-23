import AppKit
import Vision
import CoreImage

public struct ForegroundObject {
    public var image: NSImage
    public var normalizedBoundingBox: CGRect // In (0..1, 0..1) normalized coordinates
    public var position: CGPoint = .zero     // Center coordinate on canvas
    public var scale: CGFloat = 1.0
    public var rotationDegrees: CGFloat = 0.0
    public var isFlippedHorizontal: Bool = false
    public var isFlippedVertical: Bool = false

    public init(
        image: NSImage,
        normalizedBoundingBox: CGRect,
        position: CGPoint = .zero,
        scale: CGFloat = 1.0,
        rotationDegrees: CGFloat = 0.0,
        isFlippedHorizontal: Bool = false,
        isFlippedVertical: Bool = false
    ) {
        self.image = image
        self.normalizedBoundingBox = normalizedBoundingBox
        self.position = position
        self.scale = scale
        self.rotationDegrees = rotationDegrees
        self.isFlippedHorizontal = isFlippedHorizontal
        self.isFlippedVertical = isFlippedVertical
    }
}

public class ForegroundDetector {
    private static let ciContext = CIContext()

    public static func detectForegroundObject(in nsImage: NSImage, completion: @escaping (ForegroundObject?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            autoreleasepool {
                guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }

                let width = CGFloat(cgImage.width)
                let height = CGFloat(cgImage.height)
                guard width > 0 && height > 0 else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }

                // 1. Check macOS 14 Vision foreground instance mask
                if #available(macOS 14.0, *) {
                    let request = VNGenerateForegroundInstanceMaskRequest()
                    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                    do {
                        try handler.perform([request])
                        if let result = request.results?.first {
                            let instances = result.allInstances
                            if !instances.isEmpty {
                                let maskedBuffer = try result.generateMaskedImage(
                                    ofInstances: instances,
                                    from: handler,
                                    croppedToInstancesExtent: true
                                )

                                CVPixelBufferLockBaseAddress(maskedBuffer, .readOnly)
                                let ciImage = CIImage(cvPixelBuffer: maskedBuffer)
                                let cgMasked = ciContext.createCGImage(ciImage, from: ciImage.extent)
                                CVPixelBufferUnlockBaseAddress(maskedBuffer, .readOnly)

                                if let cgMasked = cgMasked {
                                    let isolatedImage = NSImage(cgImage: cgMasked, size: NSSize(width: ciImage.extent.width, height: ciImage.extent.height))
                                    let normBox = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
                                    let fgObj = ForegroundObject(
                                        image: isolatedImage,
                                        normalizedBoundingBox: normBox
                                    )
                                    DispatchQueue.main.async { completion(fgObj) }
                                    return
                                }
                            }
                        }
                    } catch {
                        print("[ForegroundDetector] VNGenerateForegroundInstanceMaskRequest error: \(error)")
                    }
                }

                // 2. Fallback to Saliency detection (macOS 10.15+)
                let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([saliencyRequest])
                    if let result = saliencyRequest.results?.first as? VNSaliencyImageObservation,
                       let salObjects = result.salientObjects, !salObjects.isEmpty {

                        var combinedBox = salObjects[0].boundingBox
                        for obj in salObjects.dropFirst() {
                            combinedBox = combinedBox.union(obj.boundingBox)
                        }

                        if combinedBox.width * combinedBox.height > 0.05 {
                            let cropY = (1.0 - combinedBox.origin.y - combinedBox.height) * height
                            let cropRect = CGRect(
                                x: combinedBox.origin.x * width,
                                y: max(0, cropY),
                                width: combinedBox.width * width,
                                height: combinedBox.height * height
                            )

                            if let croppedCG = cgImage.cropping(to: cropRect) {
                                let croppedNS = NSImage(cgImage: croppedCG, size: NSSize(width: cropRect.width, height: cropRect.height))
                                let fgObj = ForegroundObject(
                                    image: croppedNS,
                                    normalizedBoundingBox: combinedBox
                                )
                                DispatchQueue.main.async { completion(fgObj) }
                                return
                            }
                        }
                    }
                } catch {
                    print("[ForegroundDetector] Saliency request error: \(error)")
                }

                DispatchQueue.main.async { completion(nil) }
            }
        }
    }
}
