import Foundation
import AppKit
import ImageIO

public class ThumbnailGenerator {
    public static let shared = ThumbnailGenerator()

    // High-priority queue for the currently-selected image and archive opens.
    // Serial so that only one priority IO runs at a time and is never starved
    // by background thumbnail work.
    private let priorityQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.fastview.priorityqueue"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()

    // Low-priority queue for background thumbnail generation.
    // Serial (maxConcurrentOperationCount = 1) to avoid saturating a remote /
    // network-backed disk with parallel reads.  The priority queue can still
    // run independently because it lives on a separate OperationQueue.
    private let thumbnailQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.fastview.thumbnailqueue"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .utility
        return q
    }()

    // Tracks in-flight ops by their opKey so duplicates can be cancelled.
    private var activeOperations = [String: Operation]()
    private let lock = NSLock()
    public private(set) var isLoadingMainImage: Bool = false

    // Cancel every pending thumbnail and full-image operation.
    public func cancelAllPendingTasks() {
        lock.lock()
        priorityQueue.cancelAllOperations()
        thumbnailQueue.cancelAllOperations()
        activeOperations.removeAll()
        isLoadingMainImage = false
        lock.unlock()
    }

    // Cancel only in-flight / queued full-image (priority) operations, leaving
    // background thumbnail work untouched.
    public func cancelAllPriorityTasks() {
        lock.lock()
        priorityQueue.cancelAllOperations()
        activeOperations = activeOperations.filter { $0.key.hasPrefix("thumb_") }
        isLoadingMainImage = false
        lock.unlock()
    }

    // Cancel only background thumbnail operations, leaving any in-flight
    // priority (full-image / archive-open) work untouched.
    public func cancelAllThumbnailTasks() {
        lock.lock()
        thumbnailQueue.cancelAllOperations()
        // Remove thumbnail keys from the tracking dict so stale completions
        // are never delivered.
        activeOperations = activeOperations.filter { $0.key.hasPrefix("full_") }
        lock.unlock()
    }

    public func setMainImageLoading(_ loading: Bool) {
        lock.lock()
        self.isLoadingMainImage = loading
        lock.unlock()
    }

    public func generateThumbnail(for item: FileItem, targetSize: CGSize = CGSize(width: 256, height: 256), completion: @escaping (NSImage?) -> Void) {
        let cacheKey = "thumb_\(item.id)_\(targetSize.width)x\(targetSize.height)"

        if let cached = MemoryLRUCache.shared.object(forKey: cacheKey) {
            completion(cached)
            return
        }

        let opKey = "thumb_\(item.id)"

        lock.lock()
        // Cancel any previous thumbnail request for the same item before
        // queuing a new one – avoids duplicate IO for the same entry.
        if let existing = activeOperations[opKey] {
            existing.cancel()
        }

        let op = BlockOperation()
        op.addExecutionBlock { [weak self, weak op] in
            guard let self = self, let currentOp = op, !currentOp.isCancelled else { return }

            guard let cgImage = self.loadAndScaleCGImage(for: item, targetSize: targetSize, isCancelled: { currentOp.isCancelled }) else {
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

        activeOperations[opKey] = op
        lock.unlock()

        // Thumbnail ops go on the background queue so they never block the
        // priority queue that loads the full selected image.
        thumbnailQueue.addOperation(op)
    }

    public func peekFirstImage(in item: FileItem) -> FileItem? {
        if item.type == .parentDirectory { return nil }

        var entries: [FileItem] = []
        if item.type == .archiveZip {
            // listZipContents caches after the first open, so subsequent calls
            // for the same archive cost no disk IO.
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

        return findPreferredArchiveImage(in: entries)
    }

    private func findPreferredArchiveImage(in items: [FileItem]) -> FileItem? {
        var imageItems: [FileItem] = []
        for item in items {
            if item.type == .parentDirectory { continue }
            if item.type == .image {
                imageItems.append(item)
            }
        }

        let nonCSImages = imageItems.filter { item in
            let stem = (item.name as NSString).pathExtension == "" ? item.name : (item.name as NSString).deletingPathExtension
            return !stem.lowercased().hasSuffix("_cs")
        }

        if nonCSImages.count >= 2 {
            return nonCSImages[1]
        } else if let firstNonCS = nonCSImages.first {
            return firstNonCS
        } else if imageItems.count >= 2 {
            return imageItems[1]
        } else {
            return imageItems.first
        }
    }

    public func loadAndScaleCGImage(for item: FileItem, targetSize: CGSize, isCancelled: (() -> Bool)? = nil) -> CGImage? {
        if isCancelled?() == true { return nil }

        if item.type == .archiveZip || item.type == .archiveRar || item.isDirectory {
            if let peeked = peekFirstImage(in: item) {
                return loadAndScaleCGImage(for: peeked, targetSize: targetSize, isCancelled: isCancelled)
            }
            return nil
        }

        var imageData: Data?
        if let archivePath = item.archivePath {
            let ext = (archivePath as NSString).pathExtension.lowercased()
            if ext == "zip" {
                imageData = ArchiveReader.loadZipData(archivePath: archivePath, entryPath: item.path, isCancelled: isCancelled)
            } else if ext == "rar" {
                imageData = ArchiveReader.loadRarData(archivePath: archivePath, entryPath: item.path, isCancelled: isCancelled)
            }
        } else if item.type == .image {
            imageData = try? Data(contentsOf: URL(fileURLWithPath: item.path))
        }

        guard let data = imageData, isCancelled?() != true else { return nil }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let maxDimension = max(targetSize.width, targetSize.height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Hint the JPEG decoder to subsample rather than decode full
            // resolution; dramatically reduces memory and CPU for large images.
            kCGImageSourceShouldAllowFloat: false,
            kCGImageSourceShouldCache: false
        ]

        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    public func loadFullImage(for item: FileItem, completion: @escaping (NSImage?) -> Void) {
        let cacheKey = "full_\(item.id)"

        if let cached = MemoryLRUCache.shared.object(forKey: cacheKey) {
            completion(cached)
            return
        }

        // Cancel any stale full-image op that may still be running or queued
        // for a previously selected item.  Without this, the old op would sit
        // ahead of the new one in the serial priority queue even though the
        // selection has already changed.
        cancelAllPriorityTasks()

        // Cancel all queued background thumbnail work so the priority queue
        // can service this request without waiting for a backlog of thumbnails.
        cancelAllThumbnailTasks()
        setMainImageLoading(true)

        let opKey = "full_\(item.id)"

        lock.lock()
        // (opKey collision guard kept for safety, though cancelAllPriorityTasks
        // above already cleared every prior full_ entry.)

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
                    imageData = ArchiveReader.loadZipData(archivePath: archivePath, entryPath: targetItem.path, isCancelled: { currentOp.isCancelled })
                } else if ext == "rar" {
                    imageData = ArchiveReader.loadRarData(archivePath: archivePath, entryPath: targetItem.path, isCancelled: { currentOp.isCancelled })
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

        activeOperations[opKey] = op
        lock.unlock()

        // Full-image and archive-open operations run on the priority queue so
        // they are never blocked behind queued thumbnail work.
        priorityQueue.addOperation(op)
    }
}
