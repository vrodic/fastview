import Foundation
import AppKit
import ImageIO

public class ThumbnailGenerator {
    public static let shared = ThumbnailGenerator()
    private let queue = DispatchQueue(label: "com.fastview.thumbnailgenerator", qos: .userInitiated, attributes: .concurrent)

    // Generates a thumbnail image asynchronously for a given FileItem
    public func generateThumbnail(for item: FileItem, targetSize: CGSize = CGSize(width: 160, height: 160), completion: @escaping (NSImage?) -> Void) {
        let cacheKey = "thumb_\(item.id)_\(targetSize.width)x\(targetSize.height)"

        if let cached = MemoryLRUCache.shared.object(forKey: cacheKey) {
            completion(cached)
            return
        }

        queue.async {
            guard let image = self.loadAndScaleImage(for: item, targetSize: targetSize) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // Estimate cost in bytes: width * height * 4
            let cost = Int(image.size.width * image.size.height * 4)
            MemoryLRUCache.shared.setObject(image, forKey: cacheKey, cost: cost)

            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    // Peeks inside an archive (or folder) to find the first image for rendering preview/thumbnail
    public func peekFirstImage(in item: FileItem) -> FileItem? {
        if item.type == .archiveZip {
            let entries = ArchiveReader.listZipContents(archivePath: item.path)
            return findFirstImage(in: entries)
        } else if item.type == .archiveRar {
            let entries = ArchiveReader.listRarContents(archivePath: item.path)
            return findFirstImage(in: entries)
        } else if item.type == .directory {
            let mgr = NavigationManager(initialLocation: NavigationLocation(physicalPath: item.path))
            let entries = mgr.contents()
            return findFirstImage(in: entries)
        }
        return nil
    }

    private func findFirstImage(in items: [FileItem]) -> FileItem? {
        for item in items {
            if item.type == .image { return item }
            if item.type == .archiveZip || item.type == .archiveRar || item.isDirectory {
                if let nested = peekFirstImage(in: item) {
                    return nested
                }
            }
        }
        return nil
    }

    // Helper: Loads image data and uses ImageIO fast thumbnailing
    public func loadAndScaleImage(for item: FileItem, targetSize: CGSize) -> NSImage? {
        if item.type == .archiveZip || item.type == .archiveRar || item.type == .directory {
            if let peeked = peekFirstImage(in: item) {
                return loadAndScaleImage(for: peeked, targetSize: targetSize)
            }
            return nil
        }

        var imageData: Data?
        if let archivePath = item.archivePath {
            let ext = (archivePath as NSString).pathExtension.lowercased()
            if ext == "zip" {
                imageData = ArchiveReader.loadZipData(archivePath: archivePath, entryPath: item.path)
            } else if ext == "rar" {
                imageData = ArchiveReader.loadRarData(archivePath: archivePath, entryPath: item.path)
            }
        } else if item.type == .image {
            imageData = try? Data(contentsOf: URL(fileURLWithPath: item.path))
        }

        guard let data = imageData as CFData? else { return nil }
        guard let source = CGImageSourceCreateWithData(data, nil) else { return nil }

        let maxDimension = max(targetSize.width, targetSize.height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    // Fast loading of full resolution image
    public func loadFullImage(for item: FileItem, completion: @escaping (NSImage?) -> Void) {
        let cacheKey = "full_\(item.id)"

        if let cached = MemoryLRUCache.shared.object(forKey: cacheKey) {
            completion(cached)
            return
        }

        queue.async {
            var targetItem = item
            if item.type == .archiveZip || item.type == .archiveRar || item.type == .directory {
                if let peeked = self.peekFirstImage(in: item) {
                    targetItem = peeked
                } else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
            }

            var imageData: Data?
            if let archivePath = targetItem.archivePath {
                let ext = (archivePath as NSString).pathExtension.lowercased()
                if ext == "zip" {
                    imageData = ArchiveReader.loadZipData(archivePath: archivePath, entryPath: targetItem.path)
                } else if ext == "rar" {
                    imageData = ArchiveReader.loadRarData(archivePath: archivePath, entryPath: targetItem.path)
                }
            } else {
                imageData = try? Data(contentsOf: URL(fileURLWithPath: targetItem.path))
            }

            guard let data = imageData, let image = NSImage(data: data) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let cost = Int(image.size.width * image.size.height * 4)
            MemoryLRUCache.shared.setObject(image, forKey: cacheKey, cost: cost)

            DispatchQueue.main.async {
                completion(image)
            }
        }
    }
}
