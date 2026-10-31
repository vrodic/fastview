import AppKit
import CoreML

/// The optional LaMa inpainting model: downloaded on request, compiled once and kept in
/// `~/Library/Application Support/FastView/Models`, deletable from the Options menu.
public final class LamaInpainter: NSObject, URLSessionDownloadDelegate, DownloadableModel {
    public static let shared = LamaInpainter()

    /// Apache 2.0 conversion of advimman/lama (big-lama) to Core ML, 800x800 image and mask in.
    public static let downloadURL = URL(string: "https://huggingface.co/Jia-Liu/big-lama-coreml/resolve/main/big-lama-coreml.zip")!
    public let displayName = "AI object removal model (LaMa)"
    public let sourceDescription = "Hugging Face (huggingface.co/Jia-Liu/big-lama-coreml, Apache 2.0 licence)"
    public let approximateDownloadSize = "95 MB"

    /// Where the compiled model lives; tests point it elsewhere.
    static var modelsDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FastView/Models", isDirectory: true)
    private static var compiledModelURL: URL { modelsDirectory.appendingPathComponent("LaMa.mlmodelc", isDirectory: true) }
    public var installLocation: URL { Self.compiledModelURL }

    /// Checked once at launch and updated on install and delete (read by menu validation on the main thread).
    public private(set) var isInstalled = false
    public private(set) var isDownloading = false
    /// Size of the installed model on disk, for the delete menu item.
    public private(set) var installedSize: String?

    private override init() {
        super.init()
        refreshInstallState()
    }

    /// Re-reads whether the model is installed and its size, off the main thread.
    func refreshInstallState(completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async {
            let url = Self.compiledModelURL
            let installed = FileManager.default.fileExists(atPath: url.path)
            var size: String?
            if installed, let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
                var total: Int64 = 0
                for case let file as URL in files {
                    total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
                size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            }
            DispatchQueue.main.async {
                self.isInstalled = installed
                self.installedSize = size
                completion?()
            }
        }
    }

    private let modelQueue = DispatchQueue(label: "FastView.LamaInpainter")
    private var model: MLModel?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var progressHandler: ((Double) -> Void)?
    private var completionHandler: ((Error?) -> Void)?

    // MARK: - Download / delete

    /// Downloads, unpacks and compiles the model. Handlers run on the main queue.
    public func download(progress: @escaping (Double) -> Void, completion: @escaping (Error?) -> Void) {
        guard !isDownloading else { return }
        isDownloading = true
        progressHandler = progress
        completionHandler = completion
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        task = session.downloadTask(with: Self.downloadURL)
        task?.resume()
    }

    public func cancelDownload() {
        task?.cancel()
    }

    public func deleteModel() {
        isInstalled = false
        installedSize = nil
        modelQueue.async {
            self.model = nil
            try? FileManager.default.removeItem(at: Self.compiledModelURL)
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.progressHandler?(fraction) }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is removed when this returns, so unpack it now.
        let error: Error?
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            error = Self.error("The download failed (HTTP \(http.statusCode)).")
        } else {
            error = install(zipAt: location)
        }
        finish(error)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error { finish(error) }
    }

    private func finish(_ error: Error?) {
        session?.finishTasksAndInvalidate()
        session = nil
        task = nil
        refreshInstallState {
            guard self.isDownloading else { return }
            self.isDownloading = false
            self.completionHandler?(error)
            self.completionHandler = nil
            self.progressHandler = nil
        }
    }

    func install(zipAt zipURL: URL) -> Error? {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("FastView-LaMa-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", zipURL.path, work.path]
            try unzip.run()
            unzip.waitUntilExit()
            guard unzip.terminationStatus == 0 else { return Self.error("The downloaded archive could not be unpacked.") }

            guard let files = fm.enumerator(at: work, includingPropertiesForKeys: nil),
                  let package = (files.allObjects as? [URL])?.first(where: { ["mlpackage", "mlmodel"].contains($0.pathExtension) && !$0.path.contains("__MACOSX") }) else {
                return Self.error("The download does not contain a Core ML model.")
            }
            let compiled = try MLModel.compileModel(at: package)
            try fm.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)
            modelQueue.sync { model = nil }
            try? fm.removeItem(at: Self.compiledModelURL)
            try fm.moveItem(at: compiled, to: Self.compiledModelURL)
            return nil
        } catch {
            return error
        }
    }

    private static func error(_ message: String) -> Error {
        NSError(domain: "FastView.LamaInpainter", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - Inference

    /// Inpaints `image` where `hole` is set, at the model's input size (the caller resizes).
    /// Runs synchronously; call off the main thread.
    public func inpaint(_ image: RGBImage, hole: [UInt8]) throws -> RGBImage {
        try modelQueue.sync {
            if model == nil {
                let config = MLModelConfiguration()
                config.computeUnits = .cpuAndGPU
                model = try MLModel(contentsOf: Self.compiledModelURL, configuration: config)
            }
            guard let model = model else { throw Self.error("The AI model could not be loaded.") }

            // Inputs: image [1, 3, H, W] in 0...1 and mask [1, 1, H, W], 1 where filled; output [1, 3, H, W] in 0...255.
            let inputs = model.modelDescription.inputDescriptionsByName.values
            guard let imageInput = inputs.first(where: { $0.multiArrayConstraint?.shape.count == 4 && $0.multiArrayConstraint?.shape[1] == 3 }),
                  let maskInput = inputs.first(where: { $0.multiArrayConstraint?.shape.count == 4 && $0.multiArrayConstraint?.shape[1] == 1 }),
                  let shape = imageInput.multiArrayConstraint?.shape, let maskShape = maskInput.multiArrayConstraint?.shape else {
                throw Self.error("The AI model has unexpected inputs.")
            }
            let mh = shape[2].intValue, mw = shape[3].intValue
            let scaled = PatchMatchInpainter.upsample(image, toWidth: mw, height: mh)
            let scaledHole = Self.resizeMask(hole, fromWidth: image.width, height: image.height, toWidth: mw, height: mh)

            let imageArray = try MLMultiArray(shape: shape, dataType: .float32)
            let maskArray = try MLMultiArray(shape: maskShape, dataType: .float32)
            let plane = mw * mh
            let imagePtr = imageArray.dataPointer.assumingMemoryBound(to: Float32.self)
            let maskPtr = maskArray.dataPointer.assumingMemoryBound(to: Float32.self)
            for i in 0..<plane {
                // The hole is blanked: LaMa must not see what it replaces.
                let keep: Float = scaledHole[i] != 0 ? 0 : 1
                imagePtr[i] = scaled.pixels[i * 3] / 255 * keep
                imagePtr[plane + i] = scaled.pixels[i * 3 + 1] / 255 * keep
                imagePtr[2 * plane + i] = scaled.pixels[i * 3 + 2] / 255 * keep
                maskPtr[i] = (1 - keep) * 255
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                imageInput.name: MLFeatureValue(multiArray: imageArray),
                maskInput.name: MLFeatureValue(multiArray: maskArray),
            ])
            let output = try model.prediction(from: provider)
            guard let name = model.modelDescription.outputDescriptionsByName.keys.first,
                  let array = output.featureValue(for: name)?.multiArrayValue else { throw Self.error("The AI model returned nothing.") }
            let result = try Self.rgbImage(from: array)
            return PatchMatchInpainter.upsample(result, toWidth: image.width, height: image.height)
        }
    }

    private static func resizeMask(_ mask: [UInt8], fromWidth w: Int, height h: Int, toWidth tw: Int, height th: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: tw * th)
        for y in 0..<h {
            for x in 0..<w where mask[y * w + x] != 0 {
                let x0 = x * tw / w, x1 = max(x0, ((x + 1) * tw - 1) / w)
                let y0 = y * th / h, y1 = max(y0, ((y + 1) * th - 1) / h)
                for ty in y0...min(th - 1, y1) {
                    for tx in x0...min(tw - 1, x1) { out[ty * tw + tx] = 1 }
                }
            }
        }
        return out
    }

    /// A (1,)3,H,W array, 0...255 or 0...1.
    private static func rgbImage(from array: MLMultiArray) throws -> RGBImage {
        let shape = array.shape.map { $0.intValue }
        guard shape.count >= 3 else { throw error("The AI model output could not be read.") }
        let h = shape[shape.count - 2], w = shape[shape.count - 1]
        let strides = array.strides.map { $0.intValue }
        let cs = strides[strides.count - 3], ys = strides[strides.count - 2], xs = strides[strides.count - 1]
        var maxValue: Float = 0
        var pixels = [Float](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<3 {
                    let v = array[c * cs + y * ys + x * xs].floatValue
                    pixels[(y * w + x) * 3 + c] = v
                    maxValue = max(maxValue, v)
                }
            }
        }
        if maxValue <= 1.5 { for i in pixels.indices { pixels[i] *= 255 } }
        return RGBImage(width: w, height: h, pixels: pixels)
    }
}
