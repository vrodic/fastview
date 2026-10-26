import Foundation
import CoreGraphics
import ImageIO

/// How FastView picks and renders the preview image of an archive, shared by
/// the app and the helper so both choose the same image.
public enum ArchivePreview {
    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp", "ico"
    ]

    public static func isImagePath(_ path: String) -> Bool {
        imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Index of the preview image among image `names` in display order: the
    /// second image not named `*_cs` (the first is often a cover), else the
    /// first such image, else the second or first image of any kind.
    public static func preferredIndex(names: [String]) -> Int? {
        let nonCS = names.indices.filter { index in
            let name = names[index]
            let stem = (name as NSString).pathExtension == "" ? name : (name as NSString).deletingPathExtension
            return !stem.lowercased().hasSuffix("_cs")
        }
        if nonCS.count >= 2 { return nonCS[1] }
        if let first = nonCS.first { return first }
        if names.count >= 2 { return 1 }
        return names.isEmpty ? nil : 0
    }

    /// The archive's image entries in the order the sidebar lists them
    /// (flattened, by file name).
    public static func imagesInDisplayOrder(_ records: [ArchiveEntryRecord]) -> [ArchiveEntryRecord] {
        let images = records.filter { $0.kind == .file && isImagePath($0.path.replacingOccurrences(of: "\\", with: "/")) }
        func name(_ record: ArchiveEntryRecord) -> String {
            (record.path.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        }
        return images.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }

    /// A downscaled image no larger than `maxPixelSize`, oriented upright.
    public static func thumbnail(from data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldAllowFloat: false,
            kCGImageSourceShouldCache: false
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Pixel layout of a thumbnail sent as raw bytes (8-bit sRGB RGBA,
    /// premultiplied alpha), so neither side has to encode or decode it.
    public struct PixelFormat: Codable {
        public let width: Int
        public let height: Int
        public let bytesPerRow: Int

        public static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        public static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    }

    public static func pixels(of image: CGImage) -> (format: PixelFormat, data: Data)? {
        let format = PixelFormat(width: image.width, height: image.height, bytesPerRow: image.width * 4)
        var data = Data(count: format.bytesPerRow * format.height)
        let drawn = data.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: format.width, height: format.height,
                                          bitsPerComponent: 8, bytesPerRow: format.bytesPerRow,
                                          space: PixelFormat.colorSpace, bitmapInfo: PixelFormat.bitmapInfo) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: format.width, height: format.height))
            return true
        }
        return drawn ? (format, data) : nil
    }

    public static func image(fromPixels data: Data, format: PixelFormat) -> CGImage? {
        guard data.count >= format.bytesPerRow * format.height,
              let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: format.width, height: format.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: format.bytesPerRow, space: PixelFormat.colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: PixelFormat.bitmapInfo), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Header of a `preview` result, followed by the preview's bytes: raw
/// thumbnail pixels when `pixelFormat` is set, the image file otherwise.
/// On the wire: an 8-byte little-endian header length, the JSON header, the
/// bytes.
public struct ArchivePreviewHeader: Codable {
    /// The archive's entries, when the request asked for them.
    public let entries: [ArchiveEntryRecord]?
    /// Path of the chosen image entry, nil if the archive has no images.
    public let imagePath: String?
    public let pixelFormat: ArchivePreview.PixelFormat?

    public init(entries: [ArchiveEntryRecord]?, imagePath: String?, pixelFormat: ArchivePreview.PixelFormat?) {
        self.entries = entries
        self.imagePath = imagePath
        self.pixelFormat = pixelFormat
    }

    public func encode(with payload: Data) -> Data? {
        guard let json = try? JSONEncoder().encode(self) else { return nil }
        var length = UInt64(json.count).littleEndian
        var result = Data(bytes: &length, count: 8)
        result.append(json)
        result.append(payload)
        return result
    }

    public static func decode(_ data: Data) -> (header: ArchivePreviewHeader, payload: Data)? {
        guard data.count >= 8 else { return nil }
        let length = data.prefix(8).withUnsafeBytes { Int(UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))) }
        guard data.count >= 8 + length,
              let header = try? JSONDecoder().decode(ArchivePreviewHeader.self, from: data.subdata(in: 8..<(8 + length))) else { return nil }
        return (header, data.subdata(in: (8 + length)..<data.count))
    }
}
