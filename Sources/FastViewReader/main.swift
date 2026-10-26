import Foundation
import FastViewArchiveCore

// FastViewReader runs FastView's archive service in a separate, long-lived
// process, so that FastView can abandon any archive I/O instantly by killing
// it, even in the middle of a read that is stuck on a slow network volume.
//
//   FastViewReader <control-shm-name>
//
// Requests arrive as JSON `ArchiveRequest` lines on stdin.  For each one the
// result (an entry list or an entry's bytes) is written to a new shared-memory
// object named by the request, and an `ArchiveResponse` line is printed on
// stdout.  Progress of the request in flight is published in the header of
// the control region, where FastView can also ask it to stop.  The process
// exits when stdin closes.

let environment = ProcessInfo.processInfo.environment
var config = ArchiveService.Config()
// Tests slow the service down to exercise killing and resuming.
if let size = environment["FASTVIEW_READER_TEST_CHUNK_SIZE"].flatMap({ Int($0) }) { config.readChunkSize = size }
if let delay = environment["FASTVIEW_READER_TEST_CHUNK_DELAY_US"].flatMap({ useconds_t($0) }) { config.readChunkDelay = delay }
if let delay = environment["FASTVIEW_READER_TEST_START_DELAY_US"].flatMap({ useconds_t($0) }) { config.requestDelay = delay }

guard CommandLine.arguments.count == 2,
      let control = SharedMemoryRegion.open(name: CommandLine.arguments[1], payloadSize: 0) else {
    exit(64)
}

let service = ArchiveService(config: config)
let encoder = JSONEncoder()
let decoder = JSONDecoder()

func respond(_ response: ArchiveResponse) {
    guard let line = try? encoder.encode(response) else { return }
    FileHandle.standardOutput.write(line + Data([0x0A]))
}

while let line = readLine(strippingNewline: true) {
    guard let request = try? decoder.decode(ArchiveRequest.self, from: Data(line.utf8)) else {
        respond(ArchiveResponse(ok: false, resultLength: 0, evictedRegions: []))
        continue
    }

    let outcome = service.handle(request, progress: { completed, total, unit in
        control.setWord(HelperControlWord.progressTotal, UInt64(max(0, total)))
        control.setWord(HelperControlWord.progressUnit, unit.rawValue)
        control.setWord(HelperControlWord.progressCompleted, UInt64(max(0, completed)))
    }, isCancelled: { control.word(HelperControlWord.stopRequested) != 0 })
    let evicted = outcome.evictedRegions

    guard let output = outcome.result else {
        respond(ArchiveResponse(ok: false, resultLength: 0, evictedRegions: evicted, cancelled: outcome.cancelled))
        continue
    }
    if !output.isEmpty {
        guard let region = SharedMemoryRegion.create(name: request.resultName, payloadSize: output.count, ownsName: false) else {
            respond(ArchiveResponse(ok: false, resultLength: 0, evictedRegions: evicted))
            continue
        }
        output.withUnsafeBytes { region.payload.copyMemory(from: $0.baseAddress!, byteCount: output.count) }
    }
    respond(ArchiveResponse(ok: true, resultLength: output.count, evictedRegions: evicted))
}
