import Foundation
import CoreGraphics
import CryptoKit
import ImageIO

/// On-disk cache of RAR archive thumbnails and image lists, in
/// `~/Library/Caches/FastView/ArchiveThumbs`.
///
/// Only RAR archives are cached (`isUsed(for:)`): listing one scans every
/// header (and, on a network volume, reads the whole file), while a ZIP
/// archive is listed from its central directory and its preview read by
/// range, which is about as quick as reading the cache.
///
/// For each archive it holds `<key>.jpg`, the sidebar thumbnail, and
/// `<key>.json`: the archive's path, size and modification date, the
/// thumbnail size, and the ids of the archive's images, which give its image
/// count and favourite/viewed statistics.  `<key>` is the SHA-256 of the
/// archive's path; files are spread over 256 subdirectories by its first byte.
/// An entry is used only while the archive's size and date still match, so a
/// changed archive is regenerated.
///
/// The cache lives on the local disk rather than next to the archives: on the
/// network share opening a file can stall for over half a second, and
/// revisiting a folder then costs one metadata lookup per archive instead.
///
/// Files are written atomically, the JSON last, so a reader never finds a
/// JSON without its thumbnail.
enum ArchiveThumbCache {
    private static let formatVersion = 2

    /// Tests point this at a temporary directory.
    static var rootDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("FastView", isDirectory: true)
            .appendingPathComponent("ArchiveThumbs", isDirectory: true)
    }()

    struct Entry {
        /// Nil when the archive has no images.
        let thumbnail: CGImage?
        let imageIDs: [String]
    }

    private struct Record: Codable {
        let version: Int
        let archivePath: String
        let archiveSize: UInt64
        let archiveModified: Double
        let thumbnailSize: Int
        let hasThumbnail: Bool
        let imageIDs: [String]
    }

    private static func files(for archivePath: String) -> (directory: URL, json: URL, thumbnail: URL) {
        let key = SHA256.hash(data: Data(archivePath.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = rootDirectory.appendingPathComponent(String(key.prefix(2)), isDirectory: true)
        return (directory, directory.appendingPathComponent(key + ".json"), directory.appendingPathComponent(key + ".jpg"))
    }

    private static func archiveStamp(_ archivePath: String) -> (size: UInt64, modified: Double)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: archivePath),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return (size, modified.timeIntervalSince1970)
    }

    /// The cached thumbnail and image ids of `archivePath`, if they are
    /// current and were made at `thumbnailSize`.  A miss is logged with its
    /// reason (THUMBS_CACHE_MISS).
    static func load(archivePath: String, thumbnailSize: Int) -> Entry? {
        let files = files(for: archivePath)
        func miss(_ reason: String) -> Entry? {
            FileLogger.shared.log("THUMBS_CACHE_MISS", path: "\(archivePath) | \(reason)")
            return nil
        }

        guard let json = try? Data(contentsOf: files.json) else { return miss("no entry") }
        guard let record = try? JSONDecoder().decode(Record.self, from: json),
              record.version == formatVersion, record.archivePath == archivePath else { return miss("unreadable or old entry") }
        guard record.thumbnailSize == thumbnailSize else { return miss("made at \(record.thumbnailSize) px") }
        guard let stamp = archiveStamp(archivePath) else { return miss("archive not found") }
        // Network file systems can report modification times at different
        // precision from one call to the next; a changed archive differs by
        // far more than a second (or in size).
        guard stamp.size == record.archiveSize, abs(stamp.modified - record.archiveModified) < 1 else {
            return miss("archive changed")
        }

        guard record.hasThumbnail else { return Entry(thumbnail: nil, imageIDs: record.imageIDs) }
        guard let jpeg = try? Data(contentsOf: files.thumbnail),
              let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let thumbnail = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return miss("thumbnail unreadable") }
        return Entry(thumbnail: thumbnail, imageIDs: record.imageIDs)
    }

    /// Whether thumbnails of archives of `type` are cached.
    static func isUsed(for type: FileType) -> Bool {
        type == .archiveRar
    }

    static func save(archivePath: String, thumbnailSize: Int, thumbnail: CGImage?, imageIDs: [String]) {
        let files = files(for: archivePath)
        guard let stamp = archiveStamp(archivePath) else { return }

        do {
            try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
            if let thumbnail = thumbnail {
                let jpeg = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil) else { return }
                CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { return }
                try (jpeg as Data).write(to: files.thumbnail, options: .atomic)
            }
            let record = Record(version: formatVersion, archivePath: archivePath,
                                archiveSize: stamp.size, archiveModified: stamp.modified,
                                thumbnailSize: thumbnailSize, hasThumbnail: thumbnail != nil, imageIDs: imageIDs)
            try JSONEncoder().encode(record).write(to: files.json, options: .atomic)
            FileLogger.shared.log("THUMBS_CACHE_SAVED", path: archivePath)
        } catch {
            FileLogger.shared.log("THUMBS_CACHE_WRITE_FAILED", path: "\(archivePath) | \(error.localizedDescription)")
        }
    }
}
