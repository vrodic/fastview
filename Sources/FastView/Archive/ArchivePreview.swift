import Foundation
import CoreGraphics
import ImageIO

/// How FastView picks and renders the preview image of an archive, so the
/// archive service and the sidebar choose the same image.
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
}
