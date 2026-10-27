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
    // Requester group of each thumbnail op (one per sidebar), so a sidebar
    // can drop the work for rows it no longer shows.
    private var thumbnailGroups = [String: String]()
    private let lock = NSLock()
    public private(set) var isLoadingMainImage: Bool = false

    // Cancel every pending thumbnail and full-image operation.
    public func cancelAllPendingTasks() {
        lock.lock()
        priorityQueue.cancelAllOperations()
        thumbnailQueue.cancelAllOperations()
        activeOperations.removeAll()
        thumbnailGroups.removeAll()
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
        thumbnailGroups.removeAll()
        lock.unlock()
    }

    // Cancel the full-image operations started for `group` (one per pane), so
    // one pane's new selection never drops the other pane's image.
    public func cancelPriorityTasks(inGroup group: String) {
        lock.lock()
        let prefix = "full_\(group)_"
        for (opKey, op) in activeOperations where opKey.hasPrefix(prefix) {
            op.cancel()
            activeOperations.removeValue(forKey: opKey)
        }
        lock.unlock()
    }

    /// Whether a full-image load of `group` is queued or running.
    public func hasPendingFullImageLoad(inGroup group: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let prefix = "full_\(group)_"
        return activeOperations.contains { $0.key.hasPrefix(prefix) && !$0.value.isFinished && !$0.value.isCancelled }
    }

    public func setMainImageLoading(_ loading: Bool) {
        lock.lock()
        self.isLoadingMainImage = loading
        lock.unlock()
    }

    public func generateThumbnail(for item: FileItem, targetSize: CGSize = CGSize(width: 256, height: 256), completion: @escaping (NSImage?) -> Void) {
        generateThumbnailWithStats(for: item, targetSize: targetSize) { img, _ in
            completion(img)
        }
    }

    /// Cancels queued and running thumbnail ops requested by `group` except
    /// those for `keepIDs`.  A running archive read stops at its next read; a
    /// whole-file RAR read keeps what it read, so a later request resumes.
    public func cancelThumbnailTasks(inGroup group: String, keeping keepIDs: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        let dropped = thumbnailGroups.filter { opKey, opGroup in
            opGroup == group && !keepIDs.contains(String(opKey.dropFirst("thumb_".count)))
        }.keys
        for opKey in dropped {
            activeOperations.removeValue(forKey: opKey)?.cancel()
            thumbnailGroups.removeValue(forKey: opKey)
        }
    }

    public func generateThumbnailWithStats(for item: FileItem, targetSize: CGSize = CGSize(width: 256, height: 256), group: String? = nil, completion: @escaping (NSImage?, FolderStats?) -> Void) {
        let cacheKey = "thumb_\(item.id)_\(targetSize.width)x\(targetSize.height)"

        let cachedImg = MemoryLRUCache.shared.object(forKey: cacheKey)
        let cachedStats = FolderStatsCalculator.cachedStats(for: item)

        if let cached = cachedImg {
            completion(cached, cachedStats)
            return
        }

        let opKey = "thumb_\(item.id)"

        lock.lock()
        if let existing = activeOperations[opKey], !existing.isFinished, !existing.isCancelled {
            lock.unlock()
            return
        }

        let op = BlockOperation()
        op.addExecutionBlock { [weak self, weak op] in
            // Thumbnails yield to interactive I/O and never run alongside it.
            DiskIOGate.shared.perform(.background, label: item.path) {
                guard let self = self, let currentOp = op, !currentOp.isCancelled else { return }

                // Stop as soon as foreground I/O is waiting; the visible
                // thumbnails are requested again once it has finished.
                let shouldStop = { currentOp.isCancelled || DiskIOGate.shared.hasInteractiveWaiting }

                let startTime = CFAbsoluteTimeGetCurrent()

                // An archive's thumbnail and image count come from one
                // archive request: it lists the archive (for the count),
                // extracts the preview image and downscales it.
                var archiveThumbnail: CGImage?
                let isArchive = item.type == .archiveZip || item.type == .archiveRar
                if isArchive {
                    let thumbnailSize = Int(max(targetSize.width, targetSize.height))
                    // The local thumbnail cache saves reading the archive at all.
                    if ArchiveThumbCache.isUsed(for: item.type),
                       let cached = ArchiveThumbCache.load(archivePath: item.path, thumbnailSize: thumbnailSize) {
                        archiveThumbnail = cached.thumbnail
                        if FolderStatsCalculator.cachedStats(for: item) == nil {
                            FolderStatsCalculator.store(imageIDs: cached.imageIDs, for: item)
                        }
                        FileLogger.shared.log("THUMBS_CACHE_HIT", path: item.path, durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0)
                    } else {
                        FileLogger.shared.log("THUMB_GENERATE_START", path: item.path)
                        let preview = ArchiveReader.loadArchivePreview(archivePath: item.path, type: item.type,
                                                                       maxPixelSize: thumbnailSize, isCancelled: shouldStop)
                        archiveThumbnail = preview?.thumbnail
                        // Saved even if we are about to yield: the work is done.
                        if preview != nil && ArchiveThumbCache.isUsed(for: item.type) {
                            self.saveArchiveThumbnail(for: item, thumbnail: archiveThumbnail, thumbnailSize: thumbnailSize)
                        }
                        if shouldStop() { return }
                    }
                } else {
                    FileLogger.shared.log("THUMB_GENERATE_START", path: item.path)
                }

                var stats: FolderStats? = cachedStats
                if stats == nil && (item.isDirectory || isArchive) {
                    let statsStart = CFAbsoluteTimeGetCurrent()
                    FileLogger.shared.log("COUNT_GENERATE_START", path: item.path)
                    stats = FolderStatsCalculator.stats(for: item, isCancelled: shouldStop)
                    let statsDuration = (CFAbsoluteTimeGetCurrent() - statsStart) * 1000.0
                    FileLogger.shared.log("COUNT_GENERATE_END", path: item.path, durationMs: statsDuration)
                }

                if shouldStop() { return }

                guard let cgImage = isArchive
                        ? archiveThumbnail
                        : self.loadAndScaleCGImage(for: item, targetSize: targetSize, isCancelled: shouldStop) else {
                    let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
                    FileLogger.shared.log("THUMB_GENERATE_END", path: item.path, durationMs: duration)
                    DispatchQueue.main.async {
                        if !currentOp.isCancelled { completion(nil, stats) }
                    }
                    return
                }

                if currentOp.isCancelled { return }

                let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
                FileLogger.shared.log("THUMB_GENERATE_END", path: item.path, durationMs: duration)

                DispatchQueue.main.async {
                    if !currentOp.isCancelled {
                        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                        let cost = Int(cgImage.width * cgImage.height * 4)
                        MemoryLRUCache.shared.setObject(image, forKey: cacheKey, cost: cost)
                        completion(image, stats)
                    }
                }
            }
        }

        activeOperations[opKey] = op
        thumbnailGroups[opKey] = group
        lock.unlock()

        thumbnailQueue.addOperation(op)
    }

    /// Writes `item`'s thumbnail and image ids to the local thumbnail
    /// cache (`ArchiveThumbCache`).  The listing is already cached from the preview request, so
    /// this needs no archive request.
    private func saveArchiveThumbnail(for item: FileItem, thumbnail: CGImage?, thumbnailSize: Int) {
        let images = item.type == .archiveZip
            ? ArchiveReader.listAllZipImages(archivePath: item.path)
            : ArchiveReader.listAllRarImages(archivePath: item.path)
        ArchiveThumbCache.save(archivePath: item.path, thumbnailSize: thumbnailSize,
                               thumbnail: thumbnail, imageIDs: images.map(\.id))
    }

    /// Reads ahead the images that follow `item` in its ZIP
    /// archive, so viewing them next needs no disk access.  Runs on the
    /// background queue behind thumbnail work, yields to interactive I/O and
    /// is dropped by the next selection (`cancelAllThumbnailTasks`).
    public func prefetchFollowingImages(after item: FileItem) {
        guard item.type == .image, let archivePath = item.archivePath,
              (archivePath as NSString).pathExtension.lowercased() == "zip" else { return }

        let op = BlockOperation()
        op.addExecutionBlock { [weak op] in
            DiskIOGate.shared.perform(.background, label: archivePath) {
                guard let currentOp = op, !currentOp.isCancelled else { return }
                _ = ArchiveService.shared.prefetch(zipPath: archivePath, after: item.path,
                                                   isCancelled: { currentOp.isCancelled || DiskIOGate.shared.hasInteractiveWaiting })
            }
        }
        thumbnailQueue.addOperation(op)
    }

    public func peekFirstImage(in item: FileItem) -> FileItem? {
        if item.type == .parentDirectory { return nil }

        var entries: [FileItem] = []
        if item.type == .archiveZip {
            entries = ArchiveReader.listAllZipImages(archivePath: item.path)
        } else if item.type == .archiveRar {
            entries = ArchiveReader.listAllRarImages(archivePath: item.path)
        } else if item.isDirectory {
            if let archivePath = item.archivePath {
                let ext = (archivePath as NSString).pathExtension.lowercased()
                let cleanSub = item.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let prefix = cleanSub.isEmpty ? "" : cleanSub + "/"

                let all: [FileItem]
                if ext == "zip" {
                    all = ArchiveReader.listAllZipImages(archivePath: archivePath)
                } else {
                    all = ArchiveReader.listAllRarImages(archivePath: archivePath)
                }

                if !prefix.isEmpty {
                    entries = all.filter { $0.path.hasPrefix(prefix) || $0.id.hasPrefix(prefix) }
                } else {
                    entries = all
                }
            } else {
                let mgr = NavigationManager(initialLocation: NavigationLocation(physicalPath: item.path))
                entries = mgr.contents().filter { $0.type != .parentDirectory }
            }
        }

        if let preferred = findPreferredArchiveImage(in: entries) {
            return preferred
        }

        // If no direct image was found, recursively peek into subdirectories / sub-archives sorted naturally
        let subItems = entries.filter { $0.isDirectory || $0.type == .archiveZip || $0.type == .archiveRar }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        for subItem in subItems {
            if let found = peekFirstImage(in: subItem) {
                return found
            }
        }

        return nil
    }

    // Same choice as the archive service makes for previews (ArchivePreview).
    private func findPreferredArchiveImage(in items: [FileItem]) -> FileItem? {
        let imageItems = items.filter { $0.type == .image }
        return ArchivePreview.preferredIndex(names: imageItems.map(\.name)).map { imageItems[$0] }
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

    /// For archives and folders the preview pass computes the folder stats
    /// (image count) from the same listing used to pick the preview image.
    /// `progress` receives, on the main queue, the progress of slow archive
    /// work: that listing, or the first read of the archive holding an image.
    /// Loads `item` at full size. A new request cancels the earlier requests of
    /// the same `group`; their completions are not called.
    public func loadFullImage(for item: FileItem, group: String = "main", progress: LoadProgressHandler? = nil, completion: @escaping (NSImage?) -> Void) {
        let cacheKey = "full_\(item.id)"

        if let cached = MemoryLRUCache.shared.object(forKey: cacheKey) {
            completion(cached)
            return
        }

        // Cancel any stale full-image op of this group that may still be running
        // or queued for a previously selected item.  Without this, the old op
        // would sit ahead of the new one in the serial priority queue even
        // though the selection has already changed.
        cancelPriorityTasks(inGroup: group)

        // Cancel all queued background thumbnail work so the priority queue
        // can service this request without waiting for a backlog of thumbnails.
        cancelAllThumbnailTasks()
        setMainImageLoading(true)

        let opKey = "full_\(group)_\(item.id)"

        lock.lock()

        let op = BlockOperation()
        op.addExecutionBlock { [weak self, weak op] in
            // Admitted ahead of queued thumbnail I/O; never runs alongside it.
            DiskIOGate.shared.perform(.interactive, label: item.path) {
                guard let self = self, let currentOp = op, !currentOp.isCancelled else { return }

                let startTime = CFAbsoluteTimeGetCurrent()
                FileLogger.shared.log("FULL_IMAGE_LOAD_START", path: item.path)

                let mainQueueProgress: LoadProgressHandler? = progress.map { handler in
                    return { [weak currentOp] update in
                        DispatchQueue.main.async {
                            guard let op = currentOp, !op.isCancelled else { return }
                            handler(update)
                        }
                    }
                }

                var targetItem = item
                var imageData: Data?
                if item.type == .archiveZip || item.type == .archiveRar {
                    // One archive request lists the archive (for the count),
                    // picks the preview image and extracts it.
                    let preview = ArchiveReader.loadArchivePreview(archivePath: item.path, type: item.type, maxPixelSize: nil,
                                                                   progress: mainQueueProgress, isCancelled: { currentOp.isCancelled })
                    _ = FolderStatsCalculator.stats(for: item, isCancelled: { currentOp.isCancelled })
                    // The sidebar shows this image as the archive's thumbnail
                    // (it is not generated separately), so cache it too.
                    if let preview = preview, ArchiveThumbCache.isUsed(for: item.type) {
                        let thumbnailSize = 256
                        let thumbnail = preview.imageData.flatMap { ArchivePreview.thumbnail(from: $0, maxPixelSize: thumbnailSize) }
                        if ArchiveThumbCache.load(archivePath: item.path, thumbnailSize: thumbnailSize) == nil {
                            self.saveArchiveThumbnail(for: item, thumbnail: thumbnail, thumbnailSize: thumbnailSize)
                        }
                    }
                    guard let data = preview?.imageData else {
                        DispatchQueue.main.async {
                            self.setMainImageLoading(false)
                            completion(nil)
                        }
                        return
                    }
                    imageData = data
                } else if item.isDirectory {
                    // Count and preview share one listing (cached by
                    // DirectoryCache), so computing the stats here is what makes
                    // the subsequent peek cheap.
                    _ = FolderStatsCalculator.stats(for: item, progress: mainQueueProgress, isCancelled: { currentOp.isCancelled })

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

                if imageData != nil {
                    // Already extracted with the archive preview.
                } else if let archivePath = targetItem.archivePath {
                    let ext = (archivePath as NSString).pathExtension.lowercased()
                    if ext == "zip" {
                        imageData = ArchiveReader.loadZipData(archivePath: archivePath, entryPath: targetItem.path, progress: mainQueueProgress, isCancelled: { currentOp.isCancelled })
                    } else if ext == "rar" {
                        imageData = ArchiveReader.loadRarData(archivePath: archivePath, entryPath: targetItem.path, progress: mainQueueProgress, isCancelled: { currentOp.isCancelled })
                    }
                } else {
                    imageData = try? Data(contentsOf: URL(fileURLWithPath: targetItem.path))
                }

                guard let data = imageData, !currentOp.isCancelled else {
                    let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
                    FileLogger.shared.log("FULL_IMAGE_LOAD_END", path: item.path, durationMs: duration)
                    DispatchQueue.main.async {
                        self.setMainImageLoading(false)
                        completion(nil)
                    }
                    return
                }

                let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
                FileLogger.shared.log("FULL_IMAGE_LOAD_END", path: item.path, durationMs: duration)

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
        }

        activeOperations[opKey] = op
        lock.unlock()

        // Full-image and archive-open operations run on the priority queue so
        // they are never blocked behind queued thumbnail work.
        priorityQueue.addOperation(op)
    }
}
