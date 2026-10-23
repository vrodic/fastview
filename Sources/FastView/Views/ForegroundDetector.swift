import AppKit
import Vision
import CoreImage

public enum VisionDetectionMode: String, CaseIterable {
    case instanceMask = "Instance Segmentation"
    case attentionSaliency = "Attention Saliency"
    case objectnessSaliency = "Objectness Saliency"
    case fullRegion = "Full Region"
}

public struct ForegroundObject {
    public var image: NSImage
    public var normalizedBoundingBox: CGRect
    public var position: CGPoint = .zero
    public var scale: CGFloat = 1.0
    public var rotationDegrees: CGFloat = 0.0
    public var isFlippedHorizontal: Bool = false
    public var isFlippedVertical: Bool = false
    public var detectionMode: VisionDetectionMode = .instanceMask

    public init(
        image: NSImage,
        normalizedBoundingBox: CGRect,
        position: CGPoint = .zero,
        scale: CGFloat = 1.0,
        rotationDegrees: CGFloat = 0.0,
        isFlippedHorizontal: Bool = false,
        isFlippedVertical: Bool = false,
        detectionMode: VisionDetectionMode = .instanceMask
    ) {
        self.image = image
        self.normalizedBoundingBox = normalizedBoundingBox
        self.position = position
        self.scale = scale
        self.rotationDegrees = rotationDegrees
        self.isFlippedHorizontal = isFlippedHorizontal
        self.isFlippedVertical = isFlippedVertical
        self.detectionMode = detectionMode
    }
}

public class ForegroundDetector {
    private static let ciContext = CIContext()

    public static func detectForegroundObject(
        in nsImage: NSImage,
        mode: VisionDetectionMode = .instanceMask,
        completion: @escaping (ForegroundObject?) -> Void
    ) {
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

                if mode == .fullRegion {
                    let fgObj = ForegroundObject(
                        image: nsImage,
                        normalizedBoundingBox: CGRect(x: 0, y: 0, width: 1, height: 1),
                        detectionMode: .fullRegion
                    )
                    DispatchQueue.main.async { completion(fgObj) }
                    return
                }

                // 1. Instance Mask Mode (macOS 14+)
                if mode == .instanceMask, #available(macOS 14.0, *) {
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
                                        normalizedBoundingBox: normBox,
                                        detectionMode: .instanceMask
                                    )
                                    DispatchQueue.main.async { completion(fgObj) }
                                    return
                                }
                            }
                        }
                    } catch {
                        print("[ForegroundDetector] Instance mask error: \(error)")
                    }
                }

                // 2. Objectness or Attention Saliency Mode
                let request: VNImageBasedRequest
                if mode == .objectnessSaliency {
                    request = VNGenerateObjectnessBasedSaliencyImageRequest()
                } else {
                    request = VNGenerateAttentionBasedSaliencyImageRequest()
                }

                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                    if let result = request.results?.first as? VNSaliencyImageObservation,
                       let salObjects = result.salientObjects, !salObjects.isEmpty {

                        var combinedBox = salObjects[0].boundingBox
                        for obj in salObjects.dropFirst() {
                            combinedBox = combinedBox.union(obj.boundingBox)
                        }

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
                                normalizedBoundingBox: combinedBox,
                                detectionMode: mode
                            )
                            DispatchQueue.main.async { completion(fgObj) }
                            return
                        }
                    }
                } catch {
                    print("[ForegroundDetector] Saliency error: \(error)")
                }

                // Fallback: Full Region
                let fallbackObj = ForegroundObject(
                    image: nsImage,
                    normalizedBoundingBox: CGRect(x: 0, y: 0, width: 1, height: 1),
                    detectionMode: .fullRegion
                )
                DispatchQueue.main.async { completion(fallbackObj) }
            }
        }
    }
}
