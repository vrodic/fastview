import XCTest
import ImageIO
import ZIPFoundation
@testable import FastView

final class ArchiveProgressTests: XCTestCase {
    private var workDir: URL!
    private var sourceFiles: [URL] = []
    private let fileSize = 3 * 1024 * 1024

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FastViewProgressTests-\(UUID().uuidString)")
        let srcDir = workDir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)

        // Random bytes are incompressible, so packed size ~= unpacked size.
        ArchiveThumbCache.rootDirectory = workDir.appendingPathComponent("thumb-cache")

        sourceFiles = try (1...3).map { i in
            let url = srcDir.appendingPathComponent("image\(i).jpg")
            let words = (0..<fileSize / 8).map { _ in UInt64.random(in: .min ... .max) }
            try words.withUnsafeBytes { Data($0) }.write(to: url)
            return url
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.currentDirectoryURL = workDir.appendingPathComponent("src")
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) failed")
    }

    private let rarTool = "/opt/homebrew/bin/rar"

    private func makeRar(solid: Bool) throws -> String {
        try makeRar(solid ? "solid.rar" : "plain.rar", files: sourceFiles, solid: solid)
    }

    private func makeRar(_ name: String, files: [URL], solid: Bool = false) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: rarTool) else {
            throw XCTSkip("rar is not installed")
        }
        let path = workDir.appendingPathComponent(name).path
        try run(rarTool, ["a", "-ep", solid ? "-s" : "-s-", path] + files.map { $0.lastPathComponent })
        return path
    }

    /// Collects updates and checks they never go backwards and end at 100%.
    private final class Recorder {
        var updates: [LoadProgress] = []
        lazy var handler: LoadProgressHandler = { [unowned self] in self.updates.append($0) }

        func assertCompleted(unit: LoadProgress.Unit, total: Int64? = nil, file: StaticString = #file, line: UInt = #line) {
            guard let last = updates.last else {
                return XCTFail("no progress reported", file: file, line: line)
            }
            XCTAssertEqual(last.unit, unit, file: file, line: line)
            XCTAssertEqual(last.completed, last.total, file: file, line: line)
            if let total = total {
                XCTAssertEqual(last.total, total, file: file, line: line)
            }
            for (a, b) in zip(updates, updates.dropFirst()) {
                XCTAssertLessThanOrEqual(a.fraction, b.fraction, "progress went backwards", file: file, line: line)
            }
        }
    }

    func testZipListingReportsCentralDirectoryBytes() throws {
        let zipPath = workDir.appendingPathComponent("test.zip").path
        try run("/usr/bin/zip", ["-q", "-0", zipPath] + sourceFiles.map { $0.lastPathComponent })

        let listing = Recorder()
        let items = ArchiveReader.listAllZipImages(archivePath: zipPath, progress: listing.handler)
        XCTAssertEqual(items.count, 3)
        // Reading the central directory is the listing's only I/O.
        listing.assertCompleted(unit: .bytes)
        XCTAssertLessThan(try XCTUnwrap(listing.updates.last).total, 4096)

        let data = ArchiveReader.loadZipData(archivePath: zipPath, entryPath: "image2.jpg")
        XCTAssertEqual(data, try Data(contentsOf: sourceFiles[1]))
    }

    func testRarListingReportsArchiveBytes() throws {
        let rarPath = try makeRar(solid: false)
        let archiveSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: rarPath)[.size] as? NSNumber).int64Value

        let listing = Recorder()
        let items = ArchiveReader.listAllRarImages(archivePath: rarPath, progress: listing.handler)
        XCTAssertEqual(items.count, 3)
        listing.assertCompleted(unit: .bytes, total: archiveSize)

        let data = ArchiveReader.loadRarData(archivePath: rarPath, entryPath: "image3.jpg")
        XCTAssertEqual(data, try Data(contentsOf: sourceFiles[2]))
    }

    func testSolidRarExtraction() throws {
        let rarPath = try makeRar(solid: true)
        let data = ArchiveReader.loadRarData(archivePath: rarPath, entryPath: "image3.jpg")
        XCTAssertEqual(data, try Data(contentsOf: sourceFiles[2]))
    }

    func testStatsReportListingProgressAndSkipCachingWhenCancelled() throws {
        let rarPath = try makeRar(solid: true)
        let item = FileItem(id: rarPath, name: "solid.rar", path: rarPath, type: .archiveRar)

        // Cancel while the (slowed) archive read runs: no count may be cached.
        withSlowReads {
            let start = Date()
            let cancelledStats = FolderStatsCalculator.stats(for: item, isCancelled: { Date().timeIntervalSince(start) > 0.1 })
            XCTAssertNil(cancelledStats)
        }
        XCTAssertNil(FolderStatsCalculator.cachedStats(for: item))

        let listing = Recorder()
        let stats = FolderStatsCalculator.stats(for: item, progress: listing.handler)
        XCTAssertEqual(stats?.totalImages, 3)
        XCTAssertEqual(FolderStatsCalculator.cachedStats(for: item)?.totalImages, 3)
        listing.assertCompleted(unit: .bytes)
    }

    func testDiskIOGateRunsOneOperationAtATimeAndAdmitsInteractiveFirst() {
        let gate = DiskIOGate()
        let lock = NSLock()
        var active = 0
        var maxActive = 0
        var order: [String] = []

        func work(_ name: String) {
            lock.lock(); active += 1; maxActive = max(maxActive, active); order.append(name); lock.unlock()
            Thread.sleep(forTimeInterval: 0.05)
            lock.lock(); active -= 1; lock.unlock()
        }

        let group = DispatchGroup()
        let blockerStarted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async(group: group) {
            gate.perform(.background, label: "test") { blockerStarted.signal(); work("blocker") }
        }
        blockerStarted.wait()
        // Queue background work first, then interactive work, while busy.
        for i in 0..<3 {
            DispatchQueue.global().async(group: group) { gate.perform(.background, label: "test") { work("bg\(i)") } }
        }
        Thread.sleep(forTimeInterval: 0.01)
        DispatchQueue.global().async(group: group) { gate.perform(.interactive, label: "test") { work("interactive") } }
        group.wait()

        XCTAssertEqual(maxActive, 1)
        XCTAssertEqual(order.first, "blocker")
        XCTAssertEqual(order.dropFirst().first, "interactive")
    }

    /// Runs `body` with the archive service reading as from a slow network
    /// volume: RAR archives are read whole, 256 KiB every 20 ms.
    private func withSlowReads(_ body: () throws -> Void) rethrows {
        let saved = ArchiveService.shared.config
        ArchiveService.shared.config.readChunkSize = 256 * 1024
        ArchiveService.shared.config.readChunkDelay = 20_000
        ArchiveService.treatLocalVolumesAsRemote = true
        defer {
            ArchiveService.shared.config = saved
            ArchiveService.treatLocalVolumesAsRemote = false
        }
        try body()
    }

    private func makeZip(_ name: String, files: [URL]) throws -> String {
        let path = workDir.appendingPathComponent(name).path
        try run("/usr/bin/zip", ["-q", "-0", path] + files.map { $0.lastPathComponent })
        return path
    }

    func testZipOpensWithoutReadingTheWholeArchive() throws {
        ArchiveService.treatLocalVolumesAsRemote = true
        defer { ArchiveService.treatLocalVolumesAsRemote = false }
        let zipPath = try makeZip("network.zip", files: sourceFiles)
        let zipSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: zipPath)[.size] as? NSNumber).int64Value

        let recorder = Recorder()
        let items = ArchiveReader.listAllZipImages(archivePath: zipPath, progress: recorder.handler)
        XCTAssertEqual(items.count, 3)
        // Only the central directory is read to list it, never the whole file.
        recorder.assertCompleted(unit: .bytes)
        XCTAssertLessThan(try XCTUnwrap(recorder.updates.last).total, 4096)
        XCTAssertLessThan(try XCTUnwrap(recorder.updates.last).total, zipSize)
        XCTAssertNil(ArchiveService.shared.partialReadOffset(for: zipPath))

        let data = ArchiveReader.loadZipData(archivePath: zipPath, entryPath: "image2.jpg")
        XCTAssertEqual(data, try Data(contentsOf: sourceFiles[1]))
    }

    func testZipDirectoryMatchesZIPFoundation() throws {
        // Folders, a nested file, a UTF-8 name, compressible (deflated) and
        // stored entries.
        let src = workDir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("Set A/inner"), withIntermediateDirectories: true)
        try String(repeating: "compressible text ", count: 20_000).write(to: src.appendingPathComponent("Set A/notes.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(at: sourceFiles[0], to: src.appendingPathComponent("Set A/inner/Žena ćevap.jpg"))
        let zipPath = workDir.appendingPathComponent("mixed.zip").path
        try run("/usr/bin/zip", ["-q", "-r", zipPath, "Set A", sourceFiles[1].lastPathComponent])

        let fd = open(zipPath, O_RDONLY)
        defer { close(fd) }
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: zipPath)[.size] as? NSNumber).uint64Value
        let reader: ZipDirectory.Reader = { offset, count in
            var data = Data(count: count)
            let n = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, count, off_t(offset)) }
            guard n >= 0 else { return nil }
            data.count = n
            return data
        }
        let directory = try XCTUnwrap(ZipDirectory.read(fileSize: size, chunkSize: 4096, reader: reader,
                                                        progress: { _, _ in }, isCancelled: { false }))

        let reference = try ZIPFoundation.Archive(url: URL(fileURLWithPath: zipPath), accessMode: .read, pathEncoding: nil)
        let expected = Array(reference)
        XCTAssertEqual(directory.entries.map(\.path), expected.map(\.path))
        XCTAssertEqual(directory.entries.map(\.uncompressedSize), expected.map { UInt64($0.uncompressedSize) })
        XCTAssertEqual(directory.entries.map(\.kind), expected.map { entry -> ArchiveEntryRecord.Kind in
            switch entry.type {
            case .file: return .file
            case .directory: return .directory
            case .symlink: return .symlink
            }
        })
        XCTAssertTrue(directory.entries.contains { $0.method == 8 }, "expected a deflated entry")

        for (entry, referenceEntry) in zip(directory.entries, expected) where entry.kind == .file {
            var referenceData = Data()
            _ = try reference.extract(referenceEntry, consumer: { referenceData.append($0) })
            XCTAssertEqual(ZipDirectory.extract(entry, chunkSize: 4096, reader: reader, isCancelled: { false }),
                           referenceData, entry.path)
        }
    }

    func testStoppedArchiveReadResumesWhereItStopped() throws {
        let rarPath = try makeRar(solid: false)
        let rarSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: rarPath)[.size] as? NSNumber).intValue

        // Reading the ~9 MiB archive takes ~0.7 s.
        try withSlowReads {
            var readSoFar: Int64 = 0
            let stopped = ArchiveReader.listAllRarImages(archivePath: rarPath,
                                                         progress: { readSoFar = $0.completed },
                                                         isCancelled: { readSoFar >= 1024 * 1024 })
            XCTAssertTrue(stopped.isEmpty)

            let offset = try XCTUnwrap(ArchiveService.shared.partialReadOffset(for: rarPath))
            XCTAssertGreaterThanOrEqual(offset, 1024 * 1024)
            XCTAssertLessThan(offset, rarSize)

            // The next request reads only the rest.
            let resumed = Recorder()
            let items = ArchiveReader.listAllRarImages(archivePath: rarPath, progress: resumed.handler)
            XCTAssertEqual(items.count, 3)
            XCTAssertGreaterThan(try XCTUnwrap(resumed.updates.first).completed, Int64(offset))
            resumed.assertCompleted(unit: .bytes, total: Int64(rarSize))
            XCTAssertNil(ArchiveService.shared.partialReadOffset(for: rarPath))
        }
        XCTAssertEqual(ArchiveReader.loadRarData(archivePath: rarPath, entryPath: "image1.jpg"),
                       try Data(contentsOf: sourceFiles[0]))
    }

    func testPrefetchServesNextImageFromMemoryAndStopsCooperatively() throws {
        let zipPath = try makeZip("prefetch.zip", files: sourceFiles)

        // A 3 MiB image takes ~240 ms from "disk".
        try withSlowReads {
            XCTAssertNotNil(ArchiveReader.loadZipData(archivePath: zipPath, entryPath: "image1.jpg"))

            // Stopped part-way it reports what it finished.
            let start = Date()
            let stopped = ArchiveService.shared.prefetch(zipPath: zipPath, after: "image1.jpg",
                                                         isCancelled: { Date().timeIntervalSince(start) > 0.1 })
            XCTAssertLessThan(stopped ?? 0, 2)
            XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)

            XCTAssertEqual(ArchiveService.shared.prefetch(zipPath: zipPath, after: "image1.jpg", isCancelled: nil), 2)
            let readStart = Date()
            XCTAssertEqual(ArchiveReader.loadZipData(archivePath: zipPath, entryPath: "image2.jpg"),
                           try Data(contentsOf: sourceFiles[1]))
            XCTAssertLessThan(Date().timeIntervalSince(readStart), 0.1)
        }
    }

    func testThumbsCacheRoundTripsAndInvalidatesOnChange() throws {
        let zipPath = try makeZip("cached.zip", files: [sourceFiles[0]])
        let image = try XCTUnwrap(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage())

        XCTAssertNil(ArchiveThumbCache.load(archivePath: zipPath, thumbnailSize: 256))
        ArchiveThumbCache.save(archivePath: zipPath, thumbnailSize: 256, thumbnail: image, imageIDs: ["image1.jpg"])
        // Cached locally, nothing written next to the archive.
        let cacheFiles = FileManager.default.enumerator(atPath: ArchiveThumbCache.rootDirectory.path)?.allObjects as? [String] ?? []
        XCTAssertEqual(cacheFiles.filter { $0.hasSuffix(".jpg") }.count, 1)
        XCTAssertEqual(cacheFiles.filter { $0.hasSuffix(".json") }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workDir.appendingPathComponent(".thumbs").path))

        let cached = try XCTUnwrap(ArchiveThumbCache.load(archivePath: zipPath, thumbnailSize: 256))
        XCTAssertEqual(cached.imageIDs, ["image1.jpg"])
        XCTAssertEqual(cached.thumbnail?.width, 64)
        XCTAssertNil(ArchiveThumbCache.load(archivePath: zipPath, thumbnailSize: 128))

        // Sub-second differences (network file systems vary in precision)
        // still hit; a changed archive is not served from the cache.
        let modified = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: zipPath)[.modificationDate] as? Date)
        try FileManager.default.setAttributes([.modificationDate: modified.addingTimeInterval(0.4)], ofItemAtPath: zipPath)
        XCTAssertNotNil(ArchiveThumbCache.load(archivePath: zipPath, thumbnailSize: 256))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: zipPath)
        XCTAssertNil(ArchiveThumbCache.load(archivePath: zipPath, thumbnailSize: 256))
    }

    func testThumbsCacheWorksForArchivesInReadOnlyFolders() throws {
        let folder = workDir.appendingPathComponent("readonly")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let zipPath = folder.appendingPathComponent("a.zip").path
        try FileManager.default.copyItem(atPath: try makeZip("ro.zip", files: [sourceFiles[0]]), toPath: zipPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        ArchiveThumbCache.save(archivePath: zipPath, thumbnailSize: 256, thumbnail: nil, imageIDs: [])
        XCTAssertEqual(ArchiveThumbCache.load(archivePath: zipPath, thumbnailSize: 256)?.imageIDs, [])
        XCTAssertNil(ArchiveThumbCache.load(archivePath: zipPath, thumbnailSize: 256)?.thumbnail)
    }

    func testRarThumbnailIsWrittenToThumbsCache() throws {
        let images = [try writePNG("t1.png", width: 120, height: 80), try writePNG("t2.png", width: 80, height: 120)]
        let rarPath = try makeRar("thumbed.rar", files: images)
        let item = FileItem(id: rarPath, name: "thumbed.rar", path: rarPath, type: .archiveRar)

        let done = expectation(description: "thumbnail")
        ThumbnailGenerator.shared.generateThumbnailWithStats(for: item) { image, stats in
            XCTAssertNotNil(image)
            XCTAssertEqual(stats?.totalImages, 2)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)

        let cached = try XCTUnwrap(ArchiveThumbCache.load(archivePath: rarPath, thumbnailSize: 256))
        XCTAssertEqual(cached.imageIDs.sorted(), ["t1.png", "t2.png"])
        XCTAssertNotNil(cached.thumbnail)
        // As after a restart: nothing in memory.  The thumbnail and count must
        // come from the thumbnail cache, without any archive request.
        MemoryLRUCache.shared.clear()
        FolderStatsCalculator.clearCache()
        let before = ArchiveService.shared.requestCount
        let again = expectation(description: "cached thumbnail")
        ThumbnailGenerator.shared.generateThumbnailWithStats(for: item) { image, stats in
            XCTAssertNotNil(image)
            XCTAssertEqual(stats?.totalImages, 2)
            again.fulfill()
        }
        wait(for: [again], timeout: 10)
        XCTAssertEqual(ArchiveService.shared.requestCount, before)
    }

    func testZipThumbnailIsNotWrittenToThumbsCache() throws {
        let images = [try writePNG("z1.png", width: 120, height: 80), try writePNG("z2.png", width: 80, height: 120)]
        let zipPath = try makeZip("unthumbed.zip", files: images)
        let item = FileItem(id: zipPath, name: "unthumbed.zip", path: zipPath, type: .archiveZip)

        let done = expectation(description: "thumbnail")
        ThumbnailGenerator.shared.generateThumbnailWithStats(for: item) { image, stats in
            XCTAssertNotNil(image)
            XCTAssertEqual(stats?.totalImages, 2)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertNil(ArchiveThumbCache.load(archivePath: zipPath, thumbnailSize: 256))
    }

    func testScrollCancellationDropsOnlyRowsNoLongerVisibleInThatSidebar() throws {
        let archives: [FileItem] = try (1...4).map { i in
            let path = workDir.appendingPathComponent("thumbs\(i).zip").path
            try run("/usr/bin/zip", ["-q", "-0", path, sourceFiles[0].lastPathComponent])
            return FileItem(id: path, name: "thumbs\(i).zip", path: path, type: .archiveZip)
        }

        // Hold the I/O gate so none of the queued thumbnail jobs can start.
        let release = DispatchSemaphore(value: 0)
        let holding = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            DiskIOGate.shared.perform(.background, label: "test") {
                holding.signal()
                release.wait()
            }
        }
        holding.wait()

        let lock = NSLock()
        var completed: [String] = []
        let kept = expectation(description: "kept rows complete")
        kept.expectedFulfillmentCount = 2
        for (index, item) in archives.enumerated() {
            let group = index == 3 ? "other-sidebar" : "scrolled-sidebar"
            ThumbnailGenerator.shared.generateThumbnailWithStats(for: item, group: group) { _, _ in
                lock.lock(); completed.append(item.name); lock.unlock()
                if item.name == "thumbs3.zip" || item.name == "thumbs4.zip" { kept.fulfill() }
            }
        }

        // The sidebar scrolled: only thumbs3 is still visible in it.
        ThumbnailGenerator.shared.cancelThumbnailTasks(inGroup: "scrolled-sidebar", keeping: [archives[2].id])
        release.signal()

        wait(for: [kept], timeout: 10)
        // Give any wrongly surviving job time to report.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(Set(completed), ["thumbs3.zip", "thumbs4.zip"])
    }

    /// Writes a solid-colour PNG of the given size.
    private func writePNG(_ name: String, width: Int, height: Int) throws -> URL {
        let url = workDir.appendingPathComponent("src").appendingPathComponent(name)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testArchivePreviewIsOneRequestAndFeedsTheImageCount() throws {
        // The sidebar previews the second image: b.png, the only wide one.
        let images = [try writePNG("a.png", width: 300, height: 300),
                      try writePNG("b.png", width: 400, height: 200),
                      try writePNG("c.png", width: 300, height: 300)]
        var archives = [(try makeZip("preview.zip", files: images), FileType.archiveZip)]
        if FileManager.default.isExecutableFile(atPath: rarTool) {
            let rarPath = workDir.appendingPathComponent("preview.rar").path
            try run(rarTool, ["a", "-ep", rarPath] + images.map { $0.lastPathComponent })
            archives.append((rarPath, .archiveRar))
        }

        for (path, type) in archives {
            let before = ArchiveService.shared.requestCount
            let preview = try XCTUnwrap(ArchiveReader.loadArchivePreview(archivePath: path, type: type, maxPixelSize: 64))
            let thumbnail = try XCTUnwrap(preview.thumbnail, "no thumbnail for \(path)")
            XCTAssertEqual(thumbnail.width, 64)
            XCTAssertEqual(thumbnail.height, 32)

            // The count is served from the listing that came with the preview.
            let item = FileItem(id: path, name: (path as NSString).lastPathComponent, path: path, type: type)
            XCTAssertEqual(FolderStatsCalculator.stats(for: item)?.totalImages, 3)
            XCTAssertEqual(ArchiveService.shared.requestCount - before, 1, "\(path)")

            // Full size: the image file itself, still one request.
            let full = try XCTUnwrap(ArchiveReader.loadArchivePreview(archivePath: path, type: type, maxPixelSize: nil))
            XCTAssertEqual(full.imageData, try Data(contentsOf: images[1]))
        }
    }

    func testSelectingARarArchiveWritesItsThumbsEntry() throws {
        let images = [try writePNG("s1.png", width: 90, height: 60), try writePNG("s2.png", width: 60, height: 90)]
        let rarPath = try makeRar("selected.rar", files: images)
        let item = FileItem(id: rarPath, name: "selected.rar", path: rarPath, type: .archiveRar)

        let done = expectation(description: "full preview")
        ThumbnailGenerator.shared.loadFullImage(for: item) { image in
            XCTAssertNotNil(image)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)

        let cached = try XCTUnwrap(ArchiveThumbCache.load(archivePath: rarPath, thumbnailSize: 256))
        XCTAssertEqual(cached.imageIDs.sorted(), ["s1.png", "s2.png"])
        XCTAssertNotNil(cached.thumbnail)
    }
}
