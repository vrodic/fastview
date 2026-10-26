import Foundation
#if os(macOS)
import Darwin
#endif

/// Lists archives and extracts entries, keeping the archives it has opened.
///
/// It runs inside the long-lived FastViewReader helper, so archive bytes
/// never enter FastView; only entry lists and extracted images are sent back.
/// FastView stops a request by raising a flag the service checks between
/// reads (`isCancelled`), and kills the helper if a read does not return.
///
/// ZIP archives are never read whole.  Opening one reads its tail and its
/// central directory (`ZipDirectory`); each entry is then one ranged read.
/// `prefetch` reads the images that follow the one being viewed into memory,
/// so browsing on does not wait for the disk.
///
/// RAR archives have no central directory, and unrar reads the file itself.
/// One on a network volume is read whole into a named shared-memory region
/// (`ArchiveRequest.regionName`) first, as FastView has always done, which
/// leaves unrar's many small reads to the page cache.  The region outlives a
/// killed helper: the next one adopts it and, if the read was cut short,
/// resumes at the offset published in its header.  Local RAR archives are
/// mapped directly (`.mappedIfSafe`).
public final class ArchiveService {
    public struct Config {
        public var readChunkSize: Int
        // Tests slow the service down to exercise stopping and resuming.
        public var readChunkDelay: useconds_t
        public var requestDelay: useconds_t
        /// Images read ahead after the one being viewed.
        public var prefetchCount: Int
        public var prefetchByteLimit: Int
        /// Bytes of prefetched entries kept per archive.
        public var prefetchCacheLimit: Int

        public init(readChunkSize: Int = 16 * 1024 * 1024, readChunkDelay: useconds_t = 0, requestDelay: useconds_t = 0,
                    prefetchCount: Int = 8, prefetchByteLimit: Int = 64 * 1024 * 1024,
                    prefetchCacheLimit: Int = 128 * 1024 * 1024) {
            self.readChunkSize = readChunkSize
            self.readChunkDelay = readChunkDelay
            self.requestDelay = requestDelay
            self.prefetchCount = prefetchCount
            self.prefetchByteLimit = prefetchByteLimit
            self.prefetchCacheLimit = prefetchCacheLimit
        }
    }

    public typealias Progress = (_ completed: Int64, _ total: Int64, _ unit: ProgressUnit) -> Void

    public struct Outcome {
        public let result: Data?
        public let evictedRegions: [String]
        /// The request stopped because `isCancelled` became true.
        public let cancelled: Bool
    }

    private final class OpenZip {
        let fd: Int32
        let directory: ZipDirectory
        let indexByPath: [String: Int]
        // Stored bytes of entries read ahead, oldest first.
        var prefetched: [Int: Data] = [:]
        var prefetchOrder: [Int] = []
        var prefetchedBytes = 0
        var lastUsed = Date()

        init(fd: Int32, directory: ZipDirectory) {
            self.fd = fd
            self.directory = directory
            var index: [String: Int] = [:]
            for (i, entry) in directory.entries.enumerated() where index[entry.path] == nil {
                index[entry.path] = i
            }
            self.indexByPath = index
        }

        deinit {
            close(fd)
        }
    }

    private final class OpenRar {
        let data: Data
        let region: SharedMemoryRegion?
        var entries: [ArchiveEntryRecord]?
        var lastUsed = Date()

        init(data: Data, region: SharedMemoryRegion?) {
            self.data = data
            self.region = region
        }
    }

    private let config: Config
    private let maxOpenArchives = 4
    private var zips: [String: OpenZip] = [:]
    private var rars: [String: OpenRar] = [:]

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Handles one request.  `progress` reports the slowest phase only: a
    /// whole-archive read when one happens, otherwise reading the ZIP
    /// directory, the RAR header scan or the extraction itself.
    public func handle(_ request: ArchiveRequest, progress: @escaping Progress, isCancelled: @escaping () -> Bool) -> Outcome {
        if config.requestDelay > 0 { usleep(config.requestDelay) }

        var evicted: [String] = []
        let result: Data?
        switch request.kind {
        case .zip: result = handleZip(request, progress: progress, isCancelled: isCancelled)
        case .rar: result = handleRar(request, progress: progress, isCancelled: isCancelled, evicted: &evicted)
        }
        return Outcome(result: result, evictedRegions: evicted, cancelled: result == nil && isCancelled())
    }

    // MARK: ZIP

    private func handleZip(_ request: ArchiveRequest, progress: @escaping Progress, isCancelled: @escaping () -> Bool) -> Data? {
        guard let zip = openZip(request.path, progress: progress, isCancelled: isCancelled) else { return nil }
        let records = zip.directory.entries.map(\.record)

        switch request.operation {
        case .list:
            return try? JSONEncoder().encode(records)

        case .extract:
            guard let entryPath = request.entryPath, let index = zip.indexByPath[entryPath] else { return nil }
            return extract(zip, index: index, isCancelled: isCancelled)

        case .preview:
            return preview(records: records, request: request, isCancelled: isCancelled) { record in
                zip.indexByPath[record.path].flatMap { self.extract(zip, index: $0, isCancelled: isCancelled) }
            }

        case .prefetch:
            guard let entryPath = request.entryPath else { return nil }
            let count = prefetch(zip, records: records, after: entryPath, isCancelled: isCancelled)
            return try? JSONEncoder().encode(count)
        }
    }

    private func openZip(_ path: String, progress: @escaping Progress, isCancelled: () -> Bool) -> OpenZip? {
        if let existing = zips[path] {
            existing.lastUsed = Date()
            return existing
        }

        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0,
              let directory = ZipDirectory.read(fileSize: UInt64(info.st_size), chunkSize: config.readChunkSize,
                                                reader: reader(fd), progress: { progress($0, $1, .bytes) },
                                                isCancelled: isCancelled) else {
            close(fd)
            return nil
        }

        while zips.count >= maxOpenArchives, let oldest = zips.min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
            zips.removeValue(forKey: oldest.key)
        }
        let opened = OpenZip(fd: fd, directory: directory)
        zips[path] = opened
        return opened
    }

    private func reader(_ fd: Int32) -> ZipDirectory.Reader {
        let delay = config.readChunkDelay
        return { offset, count in
            var data = Data(count: count)
            var done = 0
            let ok = data.withUnsafeMutableBytes { raw -> Bool in
                while done < count {
                    let n = pread(fd, raw.baseAddress! + done, count - done, off_t(offset) + off_t(done))
                    if n < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    if n == 0 { break }
                    done += n
                }
                return true
            }
            if delay > 0 { usleep(delay) }
            guard ok else { return nil }
            data.count = done
            return data
        }
    }

    private func extract(_ zip: OpenZip, index: Int, isCancelled: () -> Bool) -> Data? {
        let entry = zip.directory.entries[index]
        // Kept after use: a thumbnail and the full view read the same entry.
        if let stored = zip.prefetched[index] {
            return ZipDirectory.decode(stored, entry: entry)
        }
        return ZipDirectory.extract(entry, chunkSize: config.readChunkSize, reader: reader(zip.fd), isCancelled: isCancelled)
    }

    /// Reads the stored bytes of the images following `entryPath` (in
    /// display order), in file order so the disk reads sequentially.
    /// Returns how many entries were read; stops early when cancelled.
    private func prefetch(_ zip: OpenZip, records: [ArchiveEntryRecord], after entryPath: String, isCancelled: () -> Bool) -> Int {
        let images = ArchivePreview.imagesInDisplayOrder(records)
        guard let current = images.firstIndex(where: { $0.path == entryPath }) else { return 0 }

        var wanted: [Int] = []
        var bytes = 0
        for record in images[(current + 1)...] {
            guard wanted.count < config.prefetchCount, bytes < config.prefetchByteLimit else { break }
            guard let index = zip.indexByPath[record.path], zip.prefetched[index] == nil else { continue }
            wanted.append(index)
            bytes += Int(zip.directory.entries[index].compressedSize)
        }
        wanted.sort { zip.directory.entries[$0].localHeaderOffset < zip.directory.entries[$1].localHeaderOffset }

        var read = 0
        for index in wanted {
            if isCancelled() { break }
            guard let stored = ZipDirectory.readStored(zip.directory.entries[index], chunkSize: config.readChunkSize,
                                                       reader: reader(zip.fd), isCancelled: isCancelled) else { break }
            zip.prefetched[index] = stored
            zip.prefetchOrder.append(index)
            zip.prefetchedBytes += stored.count
            read += 1
            while zip.prefetchedBytes > config.prefetchCacheLimit, let oldest = zip.prefetchOrder.first {
                zip.prefetchOrder.removeFirst()
                zip.prefetchedBytes -= zip.prefetched.removeValue(forKey: oldest)?.count ?? 0
            }
        }
        return read
    }

    // MARK: RAR

    private func handleRar(_ request: ArchiveRequest, progress: @escaping Progress, isCancelled: @escaping () -> Bool,
                           evicted: inout [String]) -> Data? {
        var readReportedProgress = false
        guard let rar = openRar(request, progress: progress, isCancelled: isCancelled,
                                readReportedProgress: &readReportedProgress, evicted: &evicted) else { return nil }
        let report: Progress = readReportedProgress ? { _, _, _ in } : progress

        switch request.operation {
        case .list:
            guard let records = rarEntries(rar, request: request, progress: { report($0, $1, .bytes) },
                                           isCancelled: isCancelled) else { return nil }
            return try? JSONEncoder().encode(records)

        case .extract:
            guard let entryPath = request.entryPath, let entrySize = request.entrySize else { return nil }
            return extractRar(rar, request: request, entryPath: entryPath, entrySize: entrySize,
                              report: report, isCancelled: isCancelled)

        case .preview:
            guard let records = rarEntries(rar, request: request, progress: { report($0, $1, .bytes) },
                                           isCancelled: isCancelled) else { return nil }
            return preview(records: records, request: request, isCancelled: isCancelled) { record in
                self.extractRar(rar, request: request, entryPath: record.path, entrySize: record.uncompressedSize,
                                report: { _, _, _ in }, isCancelled: isCancelled)
            }

        case .prefetch:
            // A RAR archive on a network volume is already in memory whole.
            return try? JSONEncoder().encode(0)
        }
    }

    private func openRar(_ request: ArchiveRequest, progress: Progress, isCancelled: () -> Bool,
                         readReportedProgress: inout Bool, evicted: inout [String]) -> OpenRar? {
        if let existing = rars[request.path] {
            existing.lastUsed = Date()
            return existing
        }

        let opened: OpenRar
        if let regionName = request.regionName {
            guard let region = readIntoRegion(path: request.path, name: regionName, fileSize: request.fileSize,
                                              progress: progress, isCancelled: isCancelled,
                                              reportedProgress: &readReportedProgress) else { return nil }
            opened = OpenRar(data: region.payloadData(), region: region)
        } else {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: request.path), options: .mappedIfSafe) else { return nil }
            opened = OpenRar(data: data, region: nil)
        }
        applyMemoryMapAdvisories(to: opened.data)

        while rars.count >= maxOpenArchives, let oldest = rars.min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
            rars.removeValue(forKey: oldest.key)
            if let region = oldest.value.region {
                region.unlinkName()
                evicted.append(region.name)
            }
        }
        rars[request.path] = opened
        return opened
    }

    /// Reads the file into the region `name`, creating it or adopting one a
    /// killed helper left behind, and resuming at its published offset.
    private func readIntoRegion(path: String, name: String, fileSize: Int, progress: Progress,
                                isCancelled: () -> Bool, reportedProgress: inout Bool) -> SharedMemoryRegion? {
        guard let region = SharedMemoryRegion.open(name: name, payloadSize: fileSize)
                ?? SharedMemoryRegion.create(name: name, payloadSize: fileSize, ownsName: false) else { return nil }

        var done = Int(region.word(HelperControlWord.archiveBytesRead))
        guard done < fileSize else { return region }

        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard lseek(fd, off_t(done), SEEK_SET) >= 0 else { return nil }

        reportedProgress = true
        while done < fileSize {
            if isCancelled() { return nil }
            let count = read(fd, region.payload + done, min(config.readChunkSize, fileSize - done))
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { return nil }  // The file shrank while being read.
            done += count
            region.setWord(HelperControlWord.archiveBytesRead, UInt64(done))
            progress(Int64(done), Int64(fileSize), .bytes)
            if config.readChunkDelay > 0 { usleep(config.readChunkDelay) }
        }
        return region
    }

    private func rarEntries(_ rar: OpenRar, request: ArchiveRequest, progress: (Int64, Int64) -> Void,
                            isCancelled: () -> Bool) -> [ArchiveEntryRecord]? {
        if rar.entries == nil {
            rar.entries = RarArchive.scan(fileURL: URL(fileURLWithPath: request.path),
                                          archiveSize: Int64(rar.data.count),
                                          progress: progress, isCancelled: isCancelled)
        }
        return rar.entries
    }

    private func extractRar(_ rar: OpenRar, request: ArchiveRequest, entryPath: String, entrySize: UInt64,
                            report: @escaping Progress, isCancelled: @escaping () -> Bool) -> Data? {
        guard let records = rarEntries(rar, request: request, progress: { _, _ in }, isCancelled: isCancelled),
              let index = records.firstIndex(where: { $0.path == entryPath }) else { return nil }
        // Packed bytes up to the end of the target: what a solid archive has
        // to get through to reach it.
        let total = records[...index].reduce(Int64(0)) { $0 + Int64($1.compressedSize) }
        return RarArchive.extract(fileURL: URL(fileURLWithPath: request.path), entryName: entryPath,
                                  expectedSize: entrySize,
                                  progress: { report(min($0, total), total, .bytes) },
                                  isCancelled: isCancelled)
    }

    /// Asks the kernel to read the mapped archive ahead (as FastView has
    /// always done for RAR archives, whose entries unrar reads from the file).
    private func applyMemoryMapAdvisories(to data: Data) {
        data.withUnsafeBytes { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress {
                #if os(macOS)
                let ptr = UnsafeMutableRawPointer(mutating: baseAddress)
                _ = posix_madvise(ptr, rawBuffer.count, POSIX_MADV_WILLNEED)
                _ = posix_madvise(ptr, rawBuffer.count, POSIX_MADV_SEQUENTIAL)
                #endif
            }
        }
    }

    // MARK: Preview

    /// One request instead of a listing plus an extraction (plus decoding the
    /// full image in FastView just to shrink it): picks the preview image the
    /// way the sidebar does, extracts it and, for thumbnails, downscales it.
    private func preview(records: [ArchiveEntryRecord], request: ArchiveRequest, isCancelled: () -> Bool,
                         extract: (ArchiveEntryRecord) -> Data?) -> Data? {
        let returnedEntries = request.includeEntries == true ? records : nil

        let images = ArchivePreview.imagesInDisplayOrder(records)
        let names = images.map { ($0.path.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent }
        guard let index = ArchivePreview.preferredIndex(names: names) else {
            return ArchivePreviewHeader(entries: returnedEntries, imagePath: nil, pixelFormat: nil).encode(with: Data())
        }
        let chosen = images[index]
        guard let imageData = extract(chosen) else { return nil }

        guard let maxPixelSize = request.previewMaxPixelSize else {
            return ArchivePreviewHeader(entries: returnedEntries, imagePath: chosen.path, pixelFormat: nil).encode(with: imageData)
        }
        guard let thumbnail = ArchivePreview.thumbnail(from: imageData, maxPixelSize: maxPixelSize),
              let (format, pixels) = ArchivePreview.pixels(of: thumbnail) else {
            return ArchivePreviewHeader(entries: returnedEntries, imagePath: chosen.path, pixelFormat: nil).encode(with: Data())
        }
        return ArchivePreviewHeader(entries: returnedEntries, imagePath: chosen.path, pixelFormat: format).encode(with: pixels)
    }
}
