import AppKit

public struct SavedForegroundObjectState: Codable {
    public var itemPath: String?
    /// Archive `itemPath` is an entry of; nil for plain files.
    public var archivePath: String?
    /// Pane whose image the object was auto-detected from; nil for added objects.
    public var sourcePane: Int?
    /// Absolute canvas position; `normX`/`normY` (fractions of the canvas) win when present.
    public var posX: Double
    public var posY: Double
    public var normX: Double?
    public var normY: Double?
    public var scale: Double
    public var rot: Double
    public var flipH: Bool
    public var flipV: Bool
    public var detectionMode: String
    /// Region-selection crop as fractions of the oriented source image (top-left origin).
    public var cropX: Double?
    public var cropY: Double?
    public var cropW: Double?
    public var cropH: Double?
    /// Orientation of the source pane when the region was cropped.
    public var cropRot: Double?
    public var cropFlipH: Bool?
    public var cropFlipV: Bool?
    public var colorAdjustment: ColorAdjustment?

    public init(
        itemPath: String? = nil,
        archivePath: String? = nil,
        sourcePane: Int? = nil,
        posX: Double,
        posY: Double,
        normX: Double? = nil,
        normY: Double? = nil,
        scale: Double,
        rot: Double,
        flipH: Bool,
        flipV: Bool,
        detectionMode: String = "Instance Segmentation",
        crop: CGRect? = nil,
        cropOrientation: ImageOrientation? = nil,
        colorAdjustment: ColorAdjustment? = nil
    ) {
        self.itemPath = itemPath
        self.archivePath = archivePath
        self.sourcePane = sourcePane
        self.posX = posX
        self.posY = posY
        self.normX = normX
        self.normY = normY
        self.scale = scale
        self.rot = rot
        self.flipH = flipH
        self.flipV = flipV
        self.detectionMode = detectionMode
        self.cropX = crop.map { Double($0.origin.x) }
        self.cropY = crop.map { Double($0.origin.y) }
        self.cropW = crop.map { Double($0.width) }
        self.cropH = crop.map { Double($0.height) }
        self.cropRot = cropOrientation.map { Double($0.rotationDegrees) }
        self.cropFlipH = cropOrientation?.isFlippedHorizontal
        self.cropFlipV = cropOrientation?.isFlippedVertical
        self.colorAdjustment = colorAdjustment
    }

    public var crop: CGRect? {
        guard let x = cropX, let y = cropY, let w = cropW, let h = cropH else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    public var cropOrientation: ImageOrientation? {
        guard crop != nil else { return nil }
        return ImageOrientation(rotationDegrees: CGFloat(cropRot ?? 0), isFlippedHorizontal: cropFlipH ?? false, isFlippedVertical: cropFlipV ?? false)
    }
}

public struct SavedCombinationState: Codable {
    public var id: String
    public var name: String
    public var savedAt: Date
    public var path1: String
    public var itemPath1: String?
    public var path2: String
    public var itemPath2: String?
    public var rot1: Double
    public var flipH1: Bool
    public var flipV1: Bool
    public var rot2: Double
    public var flipH2: Bool
    public var flipV2: Bool
    public var combiningMode: String
    public var mergeLeftPercent: Double
    public var mergeRightPercent: Double
    public var alphaGradientPercent: Double
    public var fgOffset1Percent: Double
    public var fgOffset2Percent: Double
    public var showBackground1: Bool
    public var showBackground2: Bool
    public var fg1OnTop: Bool
    public var fgPos1X: Double?
    public var fgPos1Y: Double?
    public var fgScale1: Double?
    public var fgRot1: Double?
    public var fgFlipH1: Bool?
    public var fgFlipV1: Bool?
    public var fgPos2X: Double?
    public var fgPos2Y: Double?
    public var fgScale2: Double?
    public var fgRot2: Double?
    public var fgFlipH2: Bool?
    public var fgFlipV2: Bool?
    public var canvasRed: Double?
    public var canvasGreen: Double?
    public var canvasBlue: Double?
    public var canvasAlpha: Double?
    public var objects: [SavedForegroundObjectState]?

    public init(
        id: String = UUID().uuidString,
        name: String,
        savedAt: Date = Date(),
        path1: String,
        itemPath1: String? = nil,
        path2: String,
        itemPath2: String? = nil,
        rot1: Double = 0,
        flipH1: Bool = false,
        flipV1: Bool = false,
        rot2: Double = 0,
        flipH2: Bool = false,
        flipV2: Bool = false,
        combiningMode: String = "split",
        mergeLeftPercent: Double = 50,
        mergeRightPercent: Double = 50,
        alphaGradientPercent: Double = 20,
        fgOffset1Percent: Double = 50,
        fgOffset2Percent: Double = 50,
        showBackground1: Bool = true,
        showBackground2: Bool = true,
        fg1OnTop: Bool = true,
        fgPos1X: Double? = nil,
        fgPos1Y: Double? = nil,
        fgScale1: Double? = nil,
        fgRot1: Double? = nil,
        fgFlipH1: Bool? = nil,
        fgFlipV1: Bool? = nil,
        fgPos2X: Double? = nil,
        fgPos2Y: Double? = nil,
        fgScale2: Double? = nil,
        fgRot2: Double? = nil,
        fgFlipH2: Bool? = nil,
        fgFlipV2: Bool? = nil,
        canvasRed: Double? = nil,
        canvasGreen: Double? = nil,
        canvasBlue: Double? = nil,
        canvasAlpha: Double? = nil,
        objects: [SavedForegroundObjectState]? = nil
    ) {
        self.id = id
        self.name = name
        self.savedAt = savedAt
        self.path1 = path1
        self.itemPath1 = itemPath1
        self.path2 = path2
        self.itemPath2 = itemPath2
        self.rot1 = rot1
        self.flipH1 = flipH1
        self.flipV1 = flipV1
        self.rot2 = rot2
        self.flipH2 = flipH2
        self.flipV2 = flipV2
        self.combiningMode = combiningMode
        self.mergeLeftPercent = mergeLeftPercent
        self.mergeRightPercent = mergeRightPercent
        self.alphaGradientPercent = alphaGradientPercent
        self.fgOffset1Percent = fgOffset1Percent
        self.fgOffset2Percent = fgOffset2Percent
        self.showBackground1 = showBackground1
        self.showBackground2 = showBackground2
        self.fg1OnTop = fg1OnTop
        self.fgPos1X = fgPos1X
        self.fgPos1Y = fgPos1Y
        self.fgScale1 = fgScale1
        self.fgRot1 = fgRot1
        self.fgFlipH1 = fgFlipH1
        self.fgFlipV1 = fgFlipV1
        self.fgPos2X = fgPos2X
        self.fgPos2Y = fgPos2Y
        self.fgScale2 = fgScale2
        self.fgRot2 = fgRot2
        self.fgFlipH2 = fgFlipH2
        self.fgFlipV2 = fgFlipV2
        self.canvasRed = canvasRed
        self.canvasGreen = canvasGreen
        self.canvasBlue = canvasBlue
        self.canvasAlpha = canvasAlpha
        self.objects = objects
    }
}

/// The light part of a saved combination, read for menus and the manager window.
public struct SavedCombinationSummary {
    public var url: URL
    public var id: String
    public var name: String
    public var savedAt: Date
    public var combiningMode: String
    public var itemName1: String
    public var itemName2: String
    public var objectCount: Int
    /// Source folders or archives that no longer exist.
    public var missingSources: [String]

    public var itemNames: String { "\(itemName1) + \(itemName2)" }
}

public enum CombinationStateError: LocalizedError {
    case nameTaken(String)

    public var errorDescription: String? {
        switch self {
        case .nameTaken(let name): return "A combination named \"\(name)\" already exists."
        }
    }
}

/// Saved combinations, one `.fastview` JSON file each in ~/Documents/FastView.
/// Preview thumbnails are a cache in ~/Library/Caches/FastView/CombinationPreviews.
/// File I/O runs on a serial queue; `summaries` is read and updated on the main thread.
public enum CombinationStateManager {
    public static let fileExtension = "fastview"
    public static let didChangeNotification = Notification.Name("FastViewCombinationStatesDidChange")

    private static let legacyDefaultsKey = "FastViewSavedCombinationStates"
    private static let ioQueue = DispatchQueue(label: "FastView.CombinationStates", qos: .userInitiated)

    public private(set) static var summaries: [SavedCombinationSummary] = []

    public static var directory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return documents.appendingPathComponent("FastView", isDirectory: true)
    }

    private static var previewDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent("FastView/CombinationPreviews", isDirectory: true)
    }

    public static func previewURL(forId id: String) -> URL {
        previewDirectory.appendingPathComponent(id).appendingPathExtension("jpg")
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Re-reads the folder and posts `didChangeNotification` on the main thread.
    public static func reload() {
        ioQueue.async {
            migrateLegacyDefaults()
            publish(readSummaries())
        }
    }

    public static func save(_ state: SavedCombinationState, preview: NSImage? = nil, completion: ((Result<URL, Error>) -> Void)? = nil) {
        ioQueue.async {
            let result = Result { try write(state) }
            if case .success = result, let preview = preview {
                writePreview(preview, id: state.id)
            }
            publish(readSummaries()) { completion?(result) }
        }
    }

    /// The state, and its preview when one is cached.
    public static func load(_ url: URL, completion: @escaping (SavedCombinationState?, NSImage?) -> Void) {
        ioQueue.async {
            let state = readState(at: url)
            let preview = state.flatMap { decodedImage(at: previewURL(forId: $0.id), maxPixelSize: nil) }
            DispatchQueue.main.async { completion(state, preview) }
        }
    }

    /// The image at `url`, decoded now (not on first draw), optionally downscaled.
    public static func decodedImage(at url: URL, maxPixelSize: Int?) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        if let max = maxPixelSize {
            options[kCGImageSourceThumbnailMaxPixelSize] = max
        } else if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            options[kCGImageSourceThumbnailMaxPixelSize] = Swift.max(w, h)
        }
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Renames the combination and its file.
    public static func rename(_ url: URL, to newName: String, completion: ((Result<URL, Error>) -> Void)? = nil) {
        ioQueue.async {
            let result = Result<URL, Error> {
                guard var state = readState(at: url) else { throw CocoaError(.fileReadCorruptFile) }
                let newURL = fileURL(forName: newName)
                if newURL.standardizedFileURL != url.standardizedFileURL,
                   FileManager.default.fileExists(atPath: newURL.path) {
                    throw CombinationStateError.nameTaken(newName)
                }
                state.name = newName
                let written = try write(state)
                if written.standardizedFileURL != url.standardizedFileURL {
                    try? FileManager.default.removeItem(at: url)
                }
                return written
            }
            publish(readSummaries()) { completion?(result) }
        }
    }

    /// Moves the file to the Trash.
    public static func delete(_ url: URL) {
        ioQueue.async {
            if let id = readState(at: url)?.id {
                try? FileManager.default.removeItem(at: previewURL(forId: id))
            }
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            publish(readSummaries())
        }
    }

    /// Moves every saved combination to the Trash.
    public static func clearAll() {
        ioQueue.async {
            for summary in readSummaries() {
                try? FileManager.default.removeItem(at: previewURL(forId: summary.id))
                try? FileManager.default.trashItem(at: summary.url, resultingItemURL: nil)
            }
            publish([])
        }
    }

    public static func fileURL(forName name: String) -> URL {
        let illegal = CharacterSet(charactersIn: "/:\\\\").union(.newlines).union(.controlCharacters)
        var base = name.components(separatedBy: illegal).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        while base.hasPrefix(".") { base.removeFirst() }
        if base.isEmpty { base = "Combination" }
        return directory.appendingPathComponent(base).appendingPathExtension(fileExtension)
    }

    // MARK: - Runs on ioQueue

    private static func publish(_ list: [SavedCombinationSummary], then: (() -> Void)? = nil) {
        DispatchQueue.main.async {
            summaries = list
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
            then?()
        }
    }

    private static func readState(at url: URL) -> SavedCombinationState? {
        (try? Data(contentsOf: url)).flatMap { try? makeDecoder().decode(SavedCombinationState.self, from: $0) }
    }

    /// Writes `state` to the file named after it; a combination with the same name is replaced.
    private static func write(_ state: SavedCombinationState) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(forName: state.name)
        let data = try makeEncoder().encode(state)
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func writePreview(_ image: NSImage, id: String) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return }
        try? FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
        try? data.write(to: previewURL(forId: id), options: .atomic)
    }

    private struct SummaryFields: Decodable {
        struct Object: Decodable {}
        var id: String
        var name: String
        var savedAt: Date
        var combiningMode: String
        var path1: String
        var itemPath1: String?
        var path2: String
        var itemPath2: String?
        var objects: [Object]?
    }

    private static func readSummaries() -> [SavedCombinationSummary] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        let decoder = makeDecoder()
        return urls
            .filter { $0.pathExtension.lowercased() == fileExtension }
            .compactMap { url -> SavedCombinationSummary? in
                guard let data = try? Data(contentsOf: url),
                      let f = try? decoder.decode(SummaryFields.self, from: data) else { return nil }
                let missing = Set([f.path1, f.path2]).filter { !FileManager.default.fileExists(atPath: $0) }.sorted()
                return SavedCombinationSummary(
                    url: url, id: f.id, name: f.name, savedAt: f.savedAt, combiningMode: f.combiningMode,
                    itemName1: displayName(f.itemPath1 ?? f.path1),
                    itemName2: displayName(f.itemPath2 ?? f.path2),
                    objectCount: f.objects?.count ?? 0,
                    missingSources: missing
                )
            }
            .sorted { $0.savedAt > $1.savedAt }
    }

    /// Last path component; archive entries ("archive#entry") show the entry name.
    private static func displayName(_ path: String) -> String {
        let tail = path.components(separatedBy: "#").last ?? path
        return (tail as NSString).lastPathComponent
    }

    /// Moves combinations saved in UserDefaults by earlier versions into files.
    private static func migrateLegacyDefaults() {
        guard let data = UserDefaults.standard.data(forKey: legacyDefaultsKey) else { return }
        let states = (try? JSONDecoder().decode([SavedCombinationState].self, from: data)) ?? []
        var allWritten = true
        for state in states where !FileManager.default.fileExists(atPath: fileURL(forName: state.name).path) {
            if (try? write(state)) == nil { allWritten = false }
        }
        if allWritten {
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        }
    }
}
