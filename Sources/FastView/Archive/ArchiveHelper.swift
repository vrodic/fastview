import Foundation
import CoreGraphics
import FastViewArchiveCore

/// Client for the archive service running in the long-lived FastViewReader
/// helper process.
///
/// All archive I/O (reading archives, listing them, extracting entries)
/// happens in the helper; FastView only receives entry lists and extracted
/// images, through shared memory.  Requests are JSON lines on the helper's
/// stdin, replies JSON lines on its stdout, and the helper publishes the
/// progress of the request in flight in a shared control region.
///
/// Each request takes an `isCancelled` check; once it returns true (a new
/// selection, scroll or open has priority) the helper is asked to stop at its
/// next check between reads, which keeps its open archives.  A thread blocked
/// in a read cannot be stopped, but a process can be killed: a helper that
/// does not answer within `stopGracePeriod` is SIGKILLed and the request
/// returns `nil`.  The next request then starts a new helper.  Archives on network volumes live in named shared-memory
/// regions that survive the kill: FastView keeps only their names and passes
/// them along, so the new helper adopts them, resuming an interrupted read
/// where it stopped.
///
/// Without the helper executable the same `ArchiveService` runs in-process.
final class ArchiveHelper {
    static let shared = ArchiveHelper()

    /// Tests set this to exercise the shared-memory path on a local disk.
    static var treatLocalVolumesAsRemote = false

    /// FastViewReader next to the running executable (or, under `swift
    /// test`, next to the test bundle in the build directory).
    static let helperURL: URL? = {
        var directories: [URL] = []
        if let executable = Bundle.main.executableURL {
            directories.append(executable.resolvingSymlinksInPath().deletingLastPathComponent())
        }
        directories.append(Bundle(for: ArchiveHelper.self).bundleURL.deletingLastPathComponent())
        return directories
            .map { $0.appendingPathComponent("FastViewReader") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    /// Lines the helper prints, handed from the pipe reader to the waiter.
    private final class Connection {
        let process: Process
        let stdin: FileHandle
        let control: SharedMemoryRegion
        private let lock = NSLock()
        private let available = DispatchSemaphore(value: 0)
        private var buffer = Data()
        private var lines: [Data] = []
        private(set) var isAlive = true

        init(process: Process, stdin: FileHandle, control: SharedMemoryRegion) {
            self.process = process
            self.stdin = stdin
            self.control = control
        }

        func received(_ data: Data) {
            lock.lock()
            buffer.append(data)
            var complete = 0
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                complete += 1
            }
            lock.unlock()
            for _ in 0..<complete { available.signal() }
        }

        func markDead() {
            lock.lock()
            isAlive = false
            lock.unlock()
            available.signal()
        }

        /// The next reply line, or nil after `timeout` or once the helper died.
        func nextLine(timeout: DispatchTimeInterval) -> Data? {
            guard available.wait(timeout: .now() + timeout) == .success else { return nil }
            lock.lock()
            defer { lock.unlock() }
            return lines.isEmpty ? nil : lines.removeFirst()
        }

        func send(_ line: Data) -> Bool {
            let bytes = line + Data([0x0A])
            return bytes.withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let written = write(stdin.fileDescriptor, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    offset += written
                }
                return true
            }
        }
    }

    private struct ArchiveRegion {
        let name: String
        let fileSize: Int
        var lastUsed: Date
    }

    // Serialises requests; the helper handles one at a time.
    private let requestLock = NSLock()
    private var connection: Connection?
    private var inProcessService: ArchiveService?
    private let stateLock = NSLock()
    // Killed helpers are kept until they have exited, so they are reaped.
    private var exitingConnections: [ObjectIdentifier: Connection] = [:]
    // Shared-memory regions of network archives, by path.  Only names: the
    // bytes are mapped by the helper alone.
    private var regions: [String: ArchiveRegion] = [:]
    private let maxRegions = 6
    private let pollInterval = DispatchTimeInterval.milliseconds(10)
    // How long a helper asked to stop may take before it is killed.
    private let stopGracePeriod: CFAbsoluteTime = 0.2
    /// Requests performed so far (tests check that work is combined).
    private(set) var requestCount = 0
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        // Writing to a helper that has just died must fail, not kill FastView.
        signal(SIGPIPE, SIG_IGN)
    }

    /// Whether `path` is read whole into shared memory (network volumes).
    static func readsThroughSharedMemory(_ path: String) -> Bool {
        if treatLocalVolumesAsRemote { return true }
        let isLocal = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal ?? true
        return !isLocal
    }

    // MARK: Requests

    func list(archivePath: String, kind: ArchiveRequest.Kind, progress: LoadProgressHandler?, isCancelled: (() -> Bool)?) -> [ArchiveEntryRecord]? {
        guard let json = perform(.list, kind: kind, path: archivePath, entryPath: nil, entrySize: nil,
                                 logName: kind == .zip ? "ZIP_LIST" : "RAR_LIST", label: archivePath,
                                 progress: progress, isCancelled: isCancelled) else { return nil }
        return try? decoder.decode([ArchiveEntryRecord].self, from: json)
    }

    struct Preview {
        /// The archive's entries, when requested.
        let entries: [ArchiveEntryRecord]?
        /// The downscaled preview, for thumbnail requests.
        let thumbnail: CGImage?
        /// The preview image file, for full-size requests.
        let imageData: Data?
    }

    /// Lists the archive, picks its preview image and extracts it in one
    /// request: downscaled to `maxPixelSize` (a thumbnail) or, when nil, the
    /// whole image file.  A nil image in the result means the archive has no
    /// images.
    func preview(archivePath: String, kind: ArchiveRequest.Kind, maxPixelSize: Int?, includeEntries: Bool,
                 progress: LoadProgressHandler?, isCancelled: (() -> Bool)?) -> Preview? {
        guard let result = perform(.preview, kind: kind, path: archivePath, entryPath: nil, entrySize: nil,
                                   previewMaxPixelSize: maxPixelSize, includeEntries: includeEntries,
                                   logName: kind == .zip ? "ZIP_PREVIEW" : "RAR_PREVIEW", label: archivePath,
                                   progress: progress, isCancelled: isCancelled),
              let (header, payload) = ArchivePreviewHeader.decode(result) else { return nil }

        guard header.imagePath != nil, !payload.isEmpty else {
            return Preview(entries: header.entries, thumbnail: nil, imageData: nil)
        }
        if let format = header.pixelFormat {
            return Preview(entries: header.entries, thumbnail: ArchivePreview.image(fromPixels: payload, format: format), imageData: nil)
        }
        return Preview(entries: header.entries, thumbnail: nil, imageData: payload)
    }

    /// Reads ahead the images following `entryPath` in the helper, so
    /// viewing them next needs no disk access.  Returns how many were read.
    func prefetch(archivePath: String, kind: ArchiveRequest.Kind, after entryPath: String,
                  isCancelled: (() -> Bool)?) -> Int? {
        guard let json = perform(.prefetch, kind: kind, path: archivePath, entryPath: entryPath, entrySize: nil,
                                 logName: kind == .zip ? "ZIP_PREFETCH" : "RAR_PREFETCH", label: "\(archivePath) after \(entryPath)",
                                 progress: nil, isCancelled: isCancelled) else { return nil }
        return try? decoder.decode(Int.self, from: json)
    }

    func extract(archivePath: String, kind: ArchiveRequest.Kind, entryPath: String, entrySize: UInt64,
                 progress: LoadProgressHandler?, isCancelled: (() -> Bool)?) -> Data? {
        return perform(.extract, kind: kind, path: archivePath, entryPath: entryPath, entrySize: entrySize,
                       logName: kind == .zip ? "ZIP_EXTRACT" : "RAR_EXTRACT", label: "\(archivePath) -> \(entryPath)",
                       progress: progress, isCancelled: isCancelled)
    }

    private func perform(_ operation: ArchiveRequest.Operation, kind: ArchiveRequest.Kind, path: String,
                         entryPath: String?, entrySize: UInt64?,
                         previewMaxPixelSize: Int? = nil, includeEntries: Bool? = nil,
                         logName: String, label: String,
                         progress: LoadProgressHandler?, isCancelled: (() -> Bool)?) -> Data? {
        requestLock.lock()
        defer { requestLock.unlock() }
        if isCancelled?() == true { return nil }
        let start = CFAbsoluteTimeGetCurrent()
        requestCount += 1

        var region: ArchiveRegion?
        // Only RAR archives are read whole; ZIP entries are read by range.
        if kind == .rar && ArchiveHelper.readsThroughSharedMemory(path) {
            guard let known = archiveRegion(for: path) else { return nil }
            region = known
        }
        let resultName = SharedMemoryRegion.makeName()
        let request = ArchiveRequest(operation: operation, kind: kind, path: path, regionName: region?.name,
                                     fileSize: region?.fileSize ?? 0, entryPath: entryPath, entrySize: entrySize,
                                     resultName: resultName, previewMaxPixelSize: previewMaxPixelSize,
                                     includeEntries: includeEntries)

        let bytesThrottle = progress.map { ProgressThrottle($0, unit: .bytes) }
        let entriesThrottle = progress.map { ProgressThrottle($0, unit: .entries) }
        let report: (Int64, Int64, ProgressUnit) -> Void = { completed, total, unit in
            (unit == .entries ? entriesThrottle : bytesThrottle)?.report(completed, of: total)
        }

        guard ArchiveHelper.helperURL != nil else {
            let service = inProcessService ?? ArchiveService()
            inProcessService = service
            let outcome = service.handle(request, progress: report, isCancelled: { isCancelled?() == true })
            forgetRegions(named: outcome.evictedRegions)
            return outcome.result
        }

        guard let response = send(request, report: report, isCancelled: isCancelled, label: label,
                                  logName: logName, start: start) else {
            shm_unlink(resultName)
            return nil
        }
        forgetRegions(named: response.evictedRegions)

        if response.cancelled {
            FileLogger.shared.log("\(logName)_STOPPED", path: label, durationMs: (CFAbsoluteTimeGetCurrent() - start) * 1000.0)
            return nil
        }
        guard response.ok else {
            FileLogger.shared.log("\(logName)_FAILED", path: label)
            // A region that cannot be read (e.g. the file changed) is dropped
            // so the next request starts afresh.
            if let region = region { forgetRegions(named: [region.name]) }
            return nil
        }
        FileLogger.shared.log(logName, path: label, durationMs: (CFAbsoluteTimeGetCurrent() - start) * 1000.0)

        guard response.resultLength > 0 else { return Data() }
        guard let result = SharedMemoryRegion.open(name: resultName, payloadSize: response.resultLength, takeOwnership: true) else {
            return nil
        }
        result.unlink()
        return result.payloadData(count: response.resultLength)
    }

    /// Sends `request` to the helper (starting one if needed) and waits for
    /// its reply, killing the helper if `isCancelled` turns true first.
    private func send(_ request: ArchiveRequest, report: @escaping (Int64, Int64, ProgressUnit) -> Void,
                      isCancelled: (() -> Bool)?, label: String, logName: String,
                      start: CFAbsoluteTime) -> ArchiveResponse? {
        guard let line = try? encoder.encode(request) else { return nil }

        func deliver(to connection: Connection?) -> Connection? {
            guard let connection = connection else { return nil }
            for word in [HelperControlWord.progressCompleted, HelperControlWord.progressTotal,
                         HelperControlWord.progressUnit, HelperControlWord.stopRequested] {
                connection.control.setWord(word, 0)
            }
            return connection.send(line) ? connection : nil
        }
        var delivered = deliver(to: liveConnection())
        if delivered == nil {
            // The helper died since the last request; start a new one.
            discardConnection()
            delivered = deliver(to: liveConnection())
        }
        guard let helper = delivered else { return nil }

        let control = helper.control
        let poll = {
            let unit = ProgressUnit(rawValue: control.word(HelperControlWord.progressUnit)) ?? .bytes
            report(Int64(control.word(HelperControlWord.progressCompleted)),
                   Int64(control.word(HelperControlWord.progressTotal)), unit)
        }

        var stopDeadline: CFAbsoluteTime?
        while true {
            if let reply = helper.nextLine(timeout: pollInterval) {
                poll()
                return try? decoder.decode(ArchiveResponse.self, from: reply)
            }
            if !helper.isAlive {
                FileLogger.shared.log("\(logName)_HELPER_DIED", path: label)
                discardConnection()
                return nil
            }
            if let deadline = stopDeadline {
                // Still busy after being asked to stop: stuck in a read.
                if CFAbsoluteTimeGetCurrent() >= deadline {
                    killConnection()
                    FileLogger.shared.log("\(logName)_KILLED", path: label, durationMs: (CFAbsoluteTimeGetCurrent() - start) * 1000.0)
                    return nil
                }
            } else if isCancelled?() == true {
                // Ask first: a helper that stops by itself keeps its open
                // archives and read-ahead.  Kill only if it does not answer.
                control.setWord(HelperControlWord.stopRequested, 1)
                stopDeadline = CFAbsoluteTimeGetCurrent() + stopGracePeriod
                continue
            }
            poll()
        }
    }

    // MARK: Helper process

    private func liveConnection() -> Connection? {
        if let existing = connection, existing.isAlive { return existing }
        connection = nil
        guard let helperURL = ArchiveHelper.helperURL,
              let control = SharedMemoryRegion.create(payloadSize: 0) else { return nil }

        let process = Process()
        process.executableURL = helperURL
        process.arguments = [control.name]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output

        let started = Connection(process: process, stdin: input.fileHandleForWriting, control: control)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                started.received(data)
            }
        }
        process.terminationHandler = { [weak self] _ in
            started.markDead()
            guard let self = self else { return }
            self.stateLock.lock()
            self.exitingConnections.removeValue(forKey: ObjectIdentifier(started))
            self.stateLock.unlock()
        }
        do {
            try process.run()
        } catch {
            return nil
        }
        FileLogger.shared.log("HELPER_STARTED", path: "pid \(process.processIdentifier)")
        connection = started
        return started
    }

    /// SIGKILLs the helper without waiting: one blocked in a network read
    /// exits once the kernel lets go of it.
    private func killConnection() {
        guard let killed = connection else { return }
        connection = nil
        stateLock.lock()
        if killed.process.isRunning {
            exitingConnections[ObjectIdentifier(killed)] = killed
        }
        stateLock.unlock()
        kill(killed.process.processIdentifier, SIGKILL)
        try? killed.stdin.close()
    }

    private func discardConnection() {
        if let dead = connection {
            try? dead.stdin.close()
        }
        connection = nil
    }

    /// Process identifier of the running helper, if any.
    var helperProcessIdentifier: Int32? {
        requestLock.lock()
        defer { requestLock.unlock() }
        return connection.flatMap { $0.isAlive ? $0.process.processIdentifier : nil }
    }

    /// Stops the helper; the next request starts a new one.  Tests use it to
    /// pick up changed helper environment variables.
    func stopHelper() {
        requestLock.lock()
        defer { requestLock.unlock() }
        killConnection()
        inProcessService = nil
    }

    /// Stops the helper and removes every archive region.  Call on quit.
    func shutdown() {
        requestLock.lock()
        defer { requestLock.unlock() }
        killConnection()
        stateLock.lock()
        let names = regions.values.map(\.name)
        regions.removeAll()
        stateLock.unlock()
        names.forEach { shm_unlink($0) }
    }

    // MARK: Archive regions

    private func archiveRegion(for path: String) -> ArchiveRegion? {
        stateLock.lock()
        defer { stateLock.unlock() }
        if var known = regions[path] {
            known.lastUsed = Date()
            regions[path] = known
            return known
        }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue else {
            return nil
        }
        let region = ArchiveRegion(name: SharedMemoryRegion.makeName(), fileSize: size, lastUsed: Date())
        regions[path] = region

        // Regions a restarted helper never asked for again would otherwise
        // stay around until quit.
        while regions.count > maxRegions,
              let oldest = regions.min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
            regions.removeValue(forKey: oldest.key)
            shm_unlink(oldest.value.name)
        }
        return region
    }

    private func forgetRegions(named names: [String]) {
        guard !names.isEmpty else { return }
        stateLock.lock()
        regions = regions.filter { !names.contains($0.value.name) }
        stateLock.unlock()
        names.forEach { shm_unlink($0) }
    }

    /// Bytes of `path` already read into its region, if it has one.
    func partialReadOffset(for path: String) -> Int? {
        stateLock.lock()
        let name = regions[path]?.name
        stateLock.unlock()
        guard let name = name, let header = SharedMemoryRegion.open(name: name, payloadSize: 0) else { return nil }
        return Int(header.word(HelperControlWord.archiveBytesRead))
    }
}
