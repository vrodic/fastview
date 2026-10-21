import XCTest
@testable import FastView

final class ArchiveBufferSizeTests: XCTestCase {
    func testDefaultBufferSizeIs4MB() {
        XCTAssertEqual(ArchiveReader.archiveBufferSize, 4 * 1024 * 1024)
    }

    func testAdjustableBufferSize() {
        let originalSize = ArchiveReader.archiveBufferSize
        defer { ArchiveReader.archiveBufferSize = originalSize }

        ArchiveReader.archiveBufferSize = 2 * 1024 * 1024
        XCTAssertEqual(ArchiveReader.archiveBufferSize, 2 * 1024 * 1024)

        ArchiveReader.archiveBufferSize = 8 * 1024 * 1024
        XCTAssertEqual(ArchiveReader.archiveBufferSize, 8 * 1024 * 1024)
    }
}
