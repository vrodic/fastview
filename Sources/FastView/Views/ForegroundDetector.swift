import AppKit
import Vision
import CoreImage

public enum VisionDetectionMode: String, CaseIterable {
    case instanceMask = "Instance Segmentation"
    case attentionSaliency = "Attention Saliency"
    case objectnessSaliency = "Objectness Saliency"
    case fullRegion = "Full Region"
}

/// How an object is drawn into the combination, beyond its pixels.
public struct ObjectEffects: Codable, Equatable {
    /// A soft shadow under the object, falling straight down onto whatever is below.
    public var shadow = false
    /// Edges faded over a few pixels instead of the mask's hard cut.
    public var featherEdges = false

    public init(shadow: Bool = false, featherEdges: Bool = false) {
        self.shadow = shadow
        self.featherEdges = featherEdges
    }
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
    /// Carves applied to the detected image, in order.
    public var carves: [ObjectCarve] = []
    /// The uncoloured image before any carve, and where `image` lies in it
    /// (fractions, bottom-left origin).
    public var imageBeforeCarving: NSImage? = nil
    public var carvedRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    public var effects = ObjectEffects()

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

    /// Applies `carves` in turn to the uncoloured image (and the coloured one, if any) off the
    /// main thread. Completes on the main thread with the object and where its new image lies
    /// in its old one (fractions, bottom-left origin); nil when no carve left anything.
    public static func applyCarves(_ carves: [ObjectCarve], to fg: ForegroundObject, completion: @escaping (ForegroundObject, CGRect?) -> Void) {
        guard !carves.isEmpty else { return completion(fg, nil) }
        let isAdjusted = fg.unadjustedImage != nil
        // CGImages are taken here, so the work below does not share the NSImages the canvas draws.
        guard let baseCG = (fg.unadjustedImage ?? fg.image).cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return completion(fg, nil)
        }
        let adjustedCG = isAdjusted ? fg.image.cgImage(forProposedRect: nil, context: nil, hints: nil) : nil
        let startSize = fg.image.size
        DispatchQueue.global(qos: .userInitiated).async {
            var base: (cg: CGImage, image: NSImage)? = nil
            var adjusted: NSImage? = nil
            var size = startSize
            var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
            var applied: [ObjectCarve] = []
            for carve in carves {
                guard let current = base?.cg ?? Optional(baseCG),
                      let carved = ObjectCarver.apply(carve, to: current, size: size),
                      var newCG = carved.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                var newBase = carved.image
                let r = carved.rect
                var newAdjusted: NSImage?
                if isAdjusted, let currentAdjusted = adjusted?.cgImage(forProposedRect: nil, context: nil, hints: nil) ?? adjustedCG {
                    newAdjusted = ObjectCarver.apply(carve, to: currentAdjusted, size: size)?.image
                }
                // The mask comes from the uncoloured image and goes on both.
                if carve.detectsForeground, let mask = ObjectCarver.foregroundMask(of: newCG),
                   let masked = ObjectCarver.applyMask(mask, to: newCG, size: newBase.size),
                   let maskedCG = masked.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    newBase = masked
                    newCG = maskedCG
                    newAdjusted = newAdjusted.flatMap { a in
                        a.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap { ObjectCarver.applyMask(mask, to: $0, size: a.size) }
                    }
                }
                adjusted = newAdjusted
                base = (newCG, newBase)
                size = newBase.size
                rect = CGRect(x: rect.minX + r.minX * rect.width, y: rect.minY + r.minY * rect.height,
                              width: r.width * rect.width, height: r.height * rect.height)
                applied.append(carve)
            }
            DispatchQueue.main.async {
                guard let base = base else { return completion(fg, nil) }
                var out = fg
                out.imageBeforeCarving = fg.imageBeforeCarving ?? fg.unadjustedImage ?? fg.image
                out.carves += applied
                out.carvedRect = CGRect(x: fg.carvedRect.minX + rect.minX * fg.carvedRect.width,
                                        y: fg.carvedRect.minY + rect.minY * fg.carvedRect.height,
                                        width: rect.width * fg.carvedRect.width, height: rect.height * fg.carvedRect.height)
                out.image = isAdjusted ? (adjusted ?? base.image) : base.image
                out.unadjustedImage = isAdjusted ? base.image : nil
                completion(out, rect)
            }
        }
    }

    /// Undoes every carve, keeping the object's colour adjustment. Completes on the main thread
    /// with the object and where its new image lies relative to its carved one.
    public static func undoCarves(of fg: ForegroundObject, completion: @escaping (ForegroundObject, CGRect) -> Void) {
        guard let original = fg.imageBeforeCarving else { return completion(fg, CGRect(x: 0, y: 0, width: 1, height: 1)) }
        let c = fg.carvedRect
        let rect = CGRect(x: -c.minX / c.width, y: -c.minY / c.height, width: 1 / c.width, height: 1 / c.height)
        var out = fg
        out.image = original
        out.unadjustedImage = nil
        out.colorAdjustment = nil
        out.carves = []
        out.imageBeforeCarving = nil
        out.carvedRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        applyColorAdjustment(fg.colorAdjustment, to: out) { completion($0, rect) }
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
