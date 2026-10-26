import Foundation
import CoreGraphics
#if os(macOS)
import Darwin
#endif

/// Lists archives and extracts entries, keeping the archives it has opened.
///
/// Requests are serialised.  Each takes an `isCancelled` check, polled
/// between reads, so a request that is no longer wanted (a new selection,
/// scroll or open has priority) stops at its next read.
///
/// ZIP archives are never read whole.  Opening one reads its tail and its
/// central directory (`ZipDirectory`); each entry is then one ranged read.
/// `prefetch` reads the images that follow the one being viewed into memory,
/// so browsing on does not wait for the disk.
///
/// RAR archives have no central directory, and unrar reads the file itself.
/// One on a network volume is read whole into memory first, as FastView has
/// always done, which leaves unrar's many small reads to the page cache.  A
/// read that is stopped is kept, so the next request for the archive resumes
/// where it stopped.  Local RAR archives are mapped directly (`.mappedIfSafe`).
public final class ArchiveService {
    public static let shared = ArchiveService()

    /// Tests set this to exercise the whole-file read on a local disk.
    static var treatLocalVolumesAsRemote = false

    public struct Config {
        public var readChunkSize: Int
        // Tests slow the service down to exercise stopping and resuming.
        public var readChunkDelay: useconds_t
        /// Images read ahead after the one being viewed.
        public var prefetchCount: Int
        public var prefetchByteLimit: Int
        /// Bytes of prefetched entries kept per archive.
        public var prefetchCacheLimit: Int

        public init(readChunkSize: Int = 2 * 1024 * 1024, readChunkDelay: useconds_t = 0,
                    prefetchCount: Int = 8, prefetchByteLimit: Int = 64 * 1024 * 1024,
                    prefetchCacheLimit: Int = 128 * 1024 * 1024) {
            self.readChunkSize = readChunkSize
            self.readChunkDelay = readChunkDelay
            self.prefetchCount = prefetchCount
            self.prefetchByteLimit = prefetchByteLimit
            self.prefetchCacheLimit = prefetchCacheLimit
        }
    }

    public enum Kind {
        case zip
        case rar
    }

    /// Bytes completed out of a total.
    typealias Progress = (_ completed: Int64, _ total: Int64) -> Void

    public struct Preview {
        /// The archive's entries, when requested.
        public let entries: [ArchiveEntryRecord]?
        /// The downscaled preview, for thumbnail requests.
        public let thumbnail: CGImage?
        /// The preview image file, for full-size requests.
        public let imageData: Data?
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
        var entries: [ArchiveEntryRecord]?
        var lastUsed = Date()

        init(data: Data) {
            self.data = data
        }
    }

    /// A whole-file read of a network RAR archive that was stopped part-way.
    private struct PartialRead {
        let path: String
        let data: Data
        let bytesRead: Int
    }

    var config: Config
    private let lock = NSLock()
    private let maxOpenArchives = 4
    private var zips: [String: OpenZip] = [:]
    private var rars: [String: OpenRar] = [:]
    private var partialRead: PartialRead?
    /// Requests performed so far (tests check that work is combined).
    private(set) var requestCount = 0

    public init(config: Config = Config()) {
        self.config = config
    }

    // MARK: Requests

    /// `progress` reports the slowest phase only: a whole-archive read when
    /// one happens, otherwise reading the ZIP directory or the RAR header scan.
    func list(_ kind: Kind, archivePath: String, progress: LoadProgressHandler?, isCancelled: (() -> Bool)?) -> [ArchiveEntryRecord]? {
        perform(kind, logName: "LIST", label: archivePath, progress: progress, isCancelled: isCancelled) { report, isCancelled in
            switch kind {
            case .zip:
                return self.openZip(archivePath, progress: report, isCancelled: isCancelled)?.directory.entries.map(\.record)
            case .rar:
                var readReportedProgress = false
                guard let rar = self.openRar(archivePath, progress: report, isCancelled: isCancelled,
                                             readReportedProgress: &readReportedProgress) else { return nil }
                return self.rarEntries(rar, path: archivePath, progress: readReportedProgress ? { _, _ in } : report,
                                       isCancelled: isCancelled)
            }
        }
    }

    func extract(_ kind: Kind, archivePath: String, entryPath: String,
                 progress: LoadProgressHandler?, isCancelled: (() -> Bool)?) -> Data? {
        perform(kind, logName: "EXTRACT", label: "\(archivePath) -> \(entryPath)", progress: progress, isCancelled: isCancelled) { report, isCancelled in
            switch kind {
            case .zip:
                guard let zip = self.openZip(archivePath, progress: report, isCancelled: isCancelled),
                      let index = zip.indexByPath[entryPath] else { return nil }
                return self.extract(zip, index: index, isCancelled: isCancelled)
            case .rar:
                var readReportedProgress = false
                guard let rar = self.openRar(archivePath, progress: report, isCancelled: isCancelled,
                                             readReportedProgress: &readReportedProgress) else { return nil }
                return self.extractRar(rar, path: archivePath, entryPath: entryPath,
                                       progress: readReportedProgress ? { _, _ in } : report, isCancelled: isCancelled)
            }
        }
    }

    /// Lists the archive, picks its preview image and extracts it in one
    /// request: downscaled to `maxPixelSize` (a thumbnail) or, when nil, the
    /// whole image file.  A nil image in the result means the archive has no
    /// images.
    func preview(_ kind: Kind, archivePath: String, maxPixelSize: Int?, includeEntries: Bool,
                 progress: LoadProgressHandler?, isCancelled: (() -> Bool)?) -> Preview? {
        perform(kind, logName: "PREVIEW", label: archivePath, progress: progress, isCancelled: isCancelled) { report, isCancelled in
            let records: [ArchiveEntryRecord]
            let extract: (ArchiveEntryRecord) -> Data?
            switch kind {
            case .zip:
                guard let zip = self.openZip(archivePath, progress: report, isCancelled: isCancelled) else { return nil }
                records = zip.directory.entries.map(\.record)
                extract = { record in zip.indexByPath[record.path].flatMap { self.extract(zip, index: $0, isCancelled: isCancelled) } }
            case .rar:
                var readReportedProgress = false
                guard let rar = self.openRar(archivePath, progress: report, isCancelled: isCancelled,
                                             readReportedProgress: &readReportedProgress),
                      let entries = self.rarEntries(rar, path: archivePath, progress: readReportedProgress ? { _, _ in } : report,
                                                    isCancelled: isCancelled) else { return nil }
                records = entries
                extract = { record in
                    self.extractRar(rar, path: archivePath, entryPath: record.path, progress: { _, _ in }, isCancelled: isCancelled)
                }
            }
            return self.preview(records: records, maxPixelSize: maxPixelSize, includeEntries: includeEntries, extract: extract)
        }
    }

    /// Reads ahead the images following `entryPath` in a ZIP archive, so
    /// viewing them next needs no disk access.  Returns how many were read.
    func prefetch(zipPath: String, after entryPath: String, isCancelled: (() -> Bool)?) -> Int? {
        perform(.zip, logName: "PREFETCH", label: "\(zipPath) after \(entryPath)", progress: nil, isCancelled: isCancelled) { report, isCancelled in
            guard let zip = self.openZip(zipPath, progress: report, isCancelled: isCancelled) else { return nil }
            return self.prefetch(zip, after: entryPath, isCancelled: isCancelled)
        }
    }

    /// Runs `body` alone, with throttled progress, and logs how it went.
    private func perform<T>(_ kind: Kind, logName: String, label: String,
                            progress: LoadProgressHandler?, isCancelled: (() -> Bool)?,
                            _ body: (@escaping Progress, @escaping () -> Bool) -> T?) -> T? {
        lock.lock()
        defer { lock.unlock() }
        let cancelled = { isCancelled?() == true }
        if cancelled() { return nil }
        let start = CFAbsoluteTimeGetCurrent()
        requestCount += 1

        let throttle = progress.map { ProgressThrottle($0, unit: .bytes) }
        let result = body({ throttle?.report($0, of: $1) }, cancelled)

        let name = (kind == .zip ? "ZIP_" : "RAR_") + logName
        let durationMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        if result != nil {
            FileLogger.shared.log(name, path: label, durationMs: durationMs)
        } else if cancelled() {
            FileLogger.shared.log("\(name)_STOPPED", path: label, durationMs: durationMs)
        } else {
            FileLogger.shared.log("\(name)_FAILED", path: label)
        }
        return result
    }

    // MARK: ZIP

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
                                                reader: reader(fd), progress: progress,
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
    private func prefetch(_ zip: OpenZip, after entryPath: String, isCancelled: () -> Bool) -> Int {
        let images = ArchivePreview.imagesInDisplayOrder(zip.directory.entries.map(\.record))
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

    /// Whether `path` is read whole before unrar opens it (network volumes).
    private static func readsWhole(_ path: String) -> Bool {
        if treatLocalVolumesAsRemote { return true }
        let isLocal = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal ?? true
        return !isLocal
    }

    private func openRar(_ path: String, progress: Progress, isCancelled: () -> Bool,
                         readReportedProgress: inout Bool) -> OpenRar? {
        if let existing = rars[path] {
            existing.lastUsed = Date()
            return existing
        }

        let data: Data
        if ArchiveService.readsWhole(path) {
            readReportedProgress = true
            guard let read = readWhole(path, progress: progress, isCancelled: isCancelled) else { return nil }
            data = read
        } else {
            guard let mapped = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return nil }
            data = mapped
        }
        applyMemoryMapAdvisories(to: data)

        while rars.count >= maxOpenArchives, let oldest = rars.min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
            rars.removeValue(forKey: oldest.key)
        }
        let opened = OpenRar(data: data)
        rars[path] = opened
        return opened
    }

    /// Reads the whole file, resuming a stopped read of the same file.
    private func readWhole(_ path: String, progress: Progress, isCancelled: () -> Bool) -> Data? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        let fileSize = Int(info.st_size)

        var data: Data
        var done: Int
        if let partial = partialRead, partial.path == path, partial.data.count == fileSize {
            data = partial.data
            done = partial.bytesRead
        } else {
            data = Data(count: fileSize)
            done = 0
        }
        // Dropped first so `data` is not copied when it is written to.
        partialRead = nil

        while done < fileSize {
            if isCancelled() {
                partialRead = PartialRead(path: path, data: data, bytesRead: done)
                return nil
            }
            let offset = done
            let count = data.withUnsafeMutableBytes { raw in
                pread(fd, raw.baseAddress! + offset, min(config.readChunkSize, fileSize - offset), off_t(offset))
            }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { return nil }  // The file shrank while being read.
            done += count
            progress(Int64(done), Int64(fileSize))
            if config.readChunkDelay > 0 { usleep(config.readChunkDelay) }
        }
        return data
    }

    /// Bytes of `path` read so far by a stopped whole-file read, if any.
    func partialReadOffset(for path: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return partialRead?.path == path ? partialRead?.bytesRead : nil
    }

    private func rarEntries(_ rar: OpenRar, path: String, progress: Progress,
                            isCancelled: () -> Bool) -> [ArchiveEntryRecord]? {
        if rar.entries == nil {
            rar.entries = RarArchive.scan(fileURL: URL(fileURLWithPath: path),
                                          archiveSize: Int64(rar.data.count),
                                          progress: progress, isCancelled: isCancelled)
        }
        return rar.entries
    }

    private func extractRar(_ rar: OpenRar, path: String, entryPath: String,
                            progress: @escaping Progress, isCancelled: @escaping () -> Bool) -> Data? {
        guard let records = rarEntries(rar, path: path, progress: { _, _ in }, isCancelled: isCancelled),
              let index = records.firstIndex(where: { $0.path == entryPath }) else { return nil }
        // Packed bytes up to the end of the target: what a solid archive has
        // to get through to reach it.
        let total = records[...index].reduce(Int64(0)) { $0 + Int64($1.compressedSize) }
        return RarArchive.extract(fileURL: URL(fileURLWithPath: path), entryName: entryPath,
                                  expectedSize: records[index].uncompressedSize,
                                  progress: { progress(min($0, total), total) },
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
    /// full image just to shrink it): picks the preview image the way the
    /// sidebar does, extracts it and, for thumbnails, downscales it.
    private func preview(records: [ArchiveEntryRecord], maxPixelSize: Int?, includeEntries: Bool,
                         extract: (ArchiveEntryRecord) -> Data?) -> Preview? {
        let returnedEntries = includeEntries ? records : nil

        let images = ArchivePreview.imagesInDisplayOrder(records)
        let names = images.map { ($0.path.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent }
        guard let index = ArchivePreview.preferredIndex(names: names) else {
            return Preview(entries: returnedEntries, thumbnail: nil, imageData: nil)
        }
        guard let imageData = extract(images[index]) else { return nil }

        guard let maxPixelSize = maxPixelSize else {
            return Preview(entries: returnedEntries, thumbnail: nil, imageData: imageData)
        }
        return Preview(entries: returnedEntries,
                       thumbnail: ArchivePreview.thumbnail(from: imageData, maxPixelSize: maxPixelSize), imageData: nil)
    }
}
