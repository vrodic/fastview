import Foundation
import AppKit
import ImageIO

public class ThumbnailGenerator {
    public static let shared = ThumbnailGenerator()
    private let queue = DispatchQueue(label: "com.fastview.thumbnailgenerator", qos: .userInitiated, attributes: .concurrent)

    public func generateThumbnail(for item: FileItem, targetSize: CGSize = CGSize(width: 160, height: 160), completion: @escaping (NSImage?) -> Void) {
        let cacheKey = "thumb_\(item.id)_\(targetSize.width)x\(targetSize.height)"

        if let cached = MemoryLRUCache.shared.object(forKey: cacheKey) {
            completion(cached)
            return
        }

        queue.async {
            guard let cgImage = self.loadAndScaleCGImage(for: item, targetSize: targetSize) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            DispatchQueue.main.async {
                let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                let cost = Int(cgImage.width * cgImage.height * 4)
                MemoryLRUCache.shared.setObject(image, forKey: cacheKey, cost: cost)
                completion(image)
            }
        }
    }

    public func peekFirstImage(in item: FileItem) -> FileItem? {
        if item.type == .parentDirectory { return nil }

        if item.type == .archiveZip {
            let entries = ArchiveReader.listZipContents(archivePath: item.path)
            return findFirstImage(in: entries)
        } else if item.type == .archiveRar {
            let entries = ArchiveReader.listRarContents(archivePath: item.path)
            return findFirstImage(in: entries)
        } else if item.isDirectory {
            if let archivePath = item.archivePath {
                let ext = (archivePath as NSString).pathExtension.lowercased()
                if ext == "zip" {
                    let entries = ArchiveReader.listZipContents(archivePath: archivePath, subfolder: item.path)
                    return findFirstImage(in: entries)
                } else if ext == "rar" {
                    let entries = ArchiveReader.listRarContents(archivePath: archivePath, subfolder: item.path)
                    return findFirstImage(in: entries)
                }
            } else {
                let mgr = NavigationManager(initialLocation: NavigationLocation(physicalPath: item.path))
                let entries = mgr.contents().filter { $0.type != .parentDirectory }
                return findFirstImage(in: entries)
            }
        }
        return nil
    }

    private func findFirstImage(in items: [FileItem]) -> FileItem? {
        for item in items {
            if item.type == .parentDirectory { continue }
            if item.type == .image { return item }
            if item.type == .archiveZip || item.type == .archiveRar || item.isDirectory {
                if let nested = peekFirstImage(in: item) {
                    return nested
                }
            }
        }
        return nil
    }

    public func loadAndScaleCGImage(for item: FileItem, targetSize: CGSize) -> CGImage? {
        if item.type == .archiveZip || item.type == .archiveRar || item.isDirectory {
            if let peeked = peekFirstImage(in: item) {
                return loadAndScaleCGImage(for: peeked, targetSize: targetSize)
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

        guard let data = imageData else { return nil }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let maxDimension = max(targetSize.width, targetSize.height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]

        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    public func loadFullImage(for item: FileItem, completion: @escaping (NSImage?) -> Void) {
        let cacheKey = "full_\(item.id)"

        if let cached = MemoryLRUCache.shared.object(forKey: cacheKey) {
            completion(cached)
            return
        }

        queue.async {
            var targetItem = item
            if item.type == .archiveZip || item.type == .archiveRar || item.isDirectory {
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

            guard let data = imageData else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            DispatchQueue.main.async {
                guard let image = NSImage(data: data) else {
                    completion(nil)
                    return
                }
                let cost = Int(image.size.width * image.size.height * 4)
                MemoryLRUCache.shared.setObject(image, forKey: cacheKey, cost: cost)
                completion(image)
            }
        }
    }
}
