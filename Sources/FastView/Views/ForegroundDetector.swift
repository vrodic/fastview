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
    public var id: UUID = UUID()
    public var itemPath: String? = nil
    /// The archive `itemPath` is an entry of; nil for plain files.
    public var archivePath: String? = nil
    /// The pane whose displayed image this object was auto-detected from; nil for objects the user added.
    public var sourcePane: Int? = nil
    public var image: NSImage
    public var normalizedBoundingBox: CGRect
    public var position: CGPoint = .zero
    public var scale: CGFloat = 1.0
    public var rotationDegrees: CGFloat = 0.0
    public var isFlippedHorizontal: Bool = false
    public var isFlippedVertical: Bool = false
    public var detectionMode: VisionDetectionMode = .instanceMask
    /// For objects cut from a region selection: the region as a fraction of the
    /// oriented source image (top-left origin), and the orientation it was taken in.
    public var sourceCrop: CGRect? = nil
    public var sourceOrientation: ImageOrientation? = nil
    /// Colour change applied to `image`; `unadjustedImage` is the image before it.
    public var colorAdjustment: ColorAdjustment? = nil
    public var unadjustedImage: NSImage? = nil

    public init(
        id: UUID = UUID(),
        itemPath: String? = nil,
        sourcePane: Int? = nil,
        image: NSImage,
        normalizedBoundingBox: CGRect,
        position: CGPoint = .zero,
        scale: CGFloat = 1.0,
        rotationDegrees: CGFloat = 0.0,
        isFlippedHorizontal: Bool = false,
        isFlippedVertical: Bool = false,
        detectionMode: VisionDetectionMode = .instanceMask
    ) {
        self.id = id
        self.itemPath = itemPath
        self.sourcePane = sourcePane
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

public extension NSImage {
    /// The part of the image inside `rect`, given as fractions of its size with a top-left origin.
    func cropped(toNormalized rect: CGRect) -> NSImage? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let pixelW = CGFloat(cg.width)
        let pixelH = CGFloat(cg.height)
        let cropRect = CGRect(
            x: max(0, rect.origin.x * pixelW),
            y: max(0, rect.origin.y * pixelH),
            width: min(pixelW, rect.width * pixelW),
            height: min(pixelH, rect.height * pixelH)
        )
        guard cropRect.width > 2 && cropRect.height > 2, let croppedCG = cg.cropping(to: cropRect) else { return nil }
        return NSImage(cgImage: croppedCG, size: NSSize(width: cropRect.width, height: cropRect.height))
    }
}

/// Re-creates foreground objects from the items they were cut from.
public enum ForegroundSource {
    /// Object loads run one at a time here, apart from the panes' full-image
    /// loads, so neither can cancel the other.
    private static let loadQueue = DispatchQueue(label: "FastView.ForegroundSource", qos: .userInitiated)

    /// Reads the item: an entry of the first archive in `archiveCandidates` that has it,
    /// else the file at `itemPath`. Returns the archive used. Runs on `loadQueue`.
    private static func readImage(itemPath: String, archiveCandidates: [String]) -> (NSImage, String?)? {
        return DiskIOGate.shared.perform(.interactive, label: itemPath) { () -> (NSImage, String?)? in
            if archiveCandidates.isEmpty || FileManager.default.fileExists(atPath: itemPath) {
                if let cached = MemoryLRUCache.shared.object(forKey: "full_\(itemPath)") { return (cached, nil) }
                if let data = try? Data(contentsOf: URL(fileURLWithPath: itemPath)), let image = NSImage(data: data) {
                    return (image, nil)
                }
            }
            for archivePath in archiveCandidates {
                let ext = (archivePath as NSString).pathExtension.lowercased()
                let data: Data?
                if ext == "zip" {
                    data = ArchiveReader.loadZipData(archivePath: archivePath, entryPath: itemPath)
                } else if ext == "rar" {
                    data = ArchiveReader.loadRarData(archivePath: archivePath, entryPath: itemPath)
                } else {
                    data = nil
                }
                if let data = data, let image = NSImage(data: data) {
                    return (image, archivePath)
                }
            }
            return nil
        }
    }

    /// Loads `itemPath`, re-applies the region crop if there was one, and runs detection.
    /// When detection finds nothing, the whole source is used so the object is not lost.
    /// Completes on the main thread.
    public static func detect(
        itemPath: String,
        archiveCandidates: [String],
        crop: CGRect?,
        orientation: ImageOrientation?,
        mode: VisionDetectionMode,
        completion: @escaping (ForegroundObject?) -> Void
    ) {
        loadQueue.async {
            guard let (image, archivePath) = readImage(itemPath: itemPath, archiveCandidates: archiveCandidates) else {
                FileLogger.shared.log("FG_SOURCE_LOAD_FAILED", path: itemPath)
                DispatchQueue.main.async { completion(nil) }
                return
            }
            var source: NSImage? = image
            if let crop = crop {
                source = image.transformed(with: orientation ?? ImageOrientation()).cropped(toNormalized: crop)
            }
            guard let src = source else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let finish: (ForegroundObject?) -> Void = { fgObj in
                guard var fg = fgObj else { return completion(nil) }
                fg.itemPath = itemPath
                fg.archivePath = archivePath
                fg.sourceCrop = crop
                fg.sourceOrientation = crop == nil ? nil : orientation
                fg.detectionMode = mode
                completion(fg)
            }
            ForegroundDetector.detectForegroundObject(in: src, mode: mode) { fgObj in
                if fgObj != nil || mode == .fullRegion {
                    finish(fgObj)
                } else {
                    FileLogger.shared.log("FG_SOURCE_DETECT_EMPTY", path: itemPath)
                    ForegroundDetector.detectForegroundObject(in: src, mode: .fullRegion, completion: finish)
                }
            }
        }
    }

    /// Applies `adjustment` off the main thread. Completes on the main thread.
    public static func applyColorAdjustment(_ adjustment: ColorAdjustment?, to fg: ForegroundObject, completion: @escaping (ForegroundObject) -> Void) {
        guard let adjustment = adjustment else { return completion(fg) }
        let base = fg.unadjustedImage ?? fg.image
        DispatchQueue.global(qos: .userInitiated).async {
            let adjusted = ColorMatcher.apply(adjustment, to: base)
            DispatchQueue.main.async {
                var out = fg
                if let adjusted = adjusted {
                    out.unadjustedImage = base
                    out.image = adjusted
                    out.colorAdjustment = adjustment
                }
                completion(out)
            }
        }
    }
}
