import Foundation
import AppKit
import ImageIO

public class ThumbnailGenerator {
    public static let shared = ThumbnailGenerator()

    private let ioQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.fastview.ioqueue"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()

    private var activeOperations = [String: Operation]()
    private let lock = NSLock()
    public private(set) var isLoadingMainImage: Bool = false

    public func cancelAllPendingTasks() {
        lock.lock()
        ioQueue.cancelAllOperations()
        activeOperations.removeAll()
        isLoadingMainImage = false
        lock.unlock()
    }

    public func setMainImageLoading(_ loading: Bool) {
        lock.lock()
        self.isLoadingMainImage = loading
        if loading {
            ioQueue.cancelAllOperations()
            activeOperations.removeAll()
        }
        lock.unlock()
    }

    public func generateThumbnail(for item: FileItem, targetSize: CGSize = CGSize(width: 256, height: 256), completion: @escaping (NSImage?) -> Void) {
        let cacheKey = "thumb_\(item.id)_\(targetSize.width)x\(targetSize.height)"

        if let cached = MemoryLRUCache.shared.object(forKey: cacheKey) {
            completion(cached)
            return
        }

        lock.lock()
        if let existing = activeOperations[item.id] {
            existing.cancel()
        }

        let op = BlockOperation()
        op.addExecutionBlock { [weak self, weak op] in
            guard let self = self, let currentOp = op, !currentOp.isCancelled else { return }

            guard let cgImage = self.loadAndScaleCGImage(for: item, targetSize: targetSize) else {
                DispatchQueue.main.async {
                    if !currentOp.isCancelled { completion(nil) }
                }
                return
            }

            if currentOp.isCancelled { return }

            DispatchQueue.main.async {
                if !currentOp.isCancelled {
                    let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    let cost = Int(cgImage.width * cgImage.height * 4)
                    MemoryLRUCache.shared.setObject(image, forKey: cacheKey, cost: cost)
                    completion(image)
                }
            }
        }

        activeOperations[item.id] = op
        lock.unlock()

        ioQueue.addOperation(op)
    }

    public func peekFirstImage(in item: FileItem) -> FileItem? {
        if item.type == .parentDirectory { return nil }

        var entries: [FileItem] = []
        if item.type == .archiveZip {
            entries = ArchiveReader.listZipContents(archivePath: item.path)
        } else if item.type == .archiveRar {
            entries = ArchiveReader.listRarContents(archivePath: item.path)
        } else if item.isDirectory {
            if let archivePath = item.archivePath {
                let ext = (archivePath as NSString).pathExtension.lowercased()
                if ext == "zip" {
                    entries = ArchiveReader.listZipContents(archivePath: archivePath, subfolder: item.path)
                } else if ext == "rar" {
                    entries = ArchiveReader.listRarContents(archivePath: archivePath, subfolder: item.path)
                }
            } else {
                let mgr = NavigationManager(initialLocation: NavigationLocation(physicalPath: item.path))
                entries = mgr.contents().filter { $0.type != .parentDirectory }
            }
        }

        return findSecondImage(in: entries)
    }

    private func findSecondImage(in items: [FileItem]) -> FileItem? {
        var imageItems: [FileItem] = []
        for item in items {
            if item.type == .parentDirectory { continue }
            if item.type == .image {
                imageItems.append(item)
            } else if item.type == .archiveZip || item.type == .archiveRar || item.isDirectory {
                if let nested = peekFirstImage(in: item) {
                    imageItems.append(nested)
                }
            }
        }

        if imageItems.count >= 2 {
            return imageItems[1]
        } else {
            return imageItems.first
        }
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

        setMainImageLoading(true)

        let op = BlockOperation()
        op.addExecutionBlock { [weak self, weak op] in
            guard let self = self, let currentOp = op, !currentOp.isCancelled else { return }

            var targetItem = item
            if item.type == .archiveZip || item.type == .archiveRar || item.isDirectory {
                if let peeked = self.peekFirstImage(in: item) {
                    targetItem = peeked
                } else {
                    DispatchQueue.main.async {
                        self.setMainImageLoading(false)
                        completion(nil)
                    }
                    return
                }
            }

            if currentOp.isCancelled {
                self.setMainImageLoading(false)
                return
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

            guard let data = imageData, !currentOp.isCancelled else {
                DispatchQueue.main.async {
                    self.setMainImageLoading(false)
                    completion(nil)
                }
                return
            }

            DispatchQueue.main.async {
                self.setMainImageLoading(false)
                if currentOp.isCancelled { return }
                guard let image = NSImage(data: data) else {
                    completion(nil)
                    return
                }
                let cost = Int(image.size.width * image.size.height * 4)
                MemoryLRUCache.shared.setObject(image, forKey: cacheKey, cost: cost)
                completion(image)
            }
        }

        lock.lock()
        activeOperations[item.id] = op
        lock.unlock()

        ioQueue.addOperation(op)
    }
}
