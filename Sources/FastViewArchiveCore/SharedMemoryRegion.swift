import Foundation
import CFastViewShm

/// A POSIX shared-memory object mapped into this process: a
/// `FASTVIEW_SHM_HEADER_SIZE` header of 64-bit control words, followed by a
/// payload.  FastView and its FastViewReader helper exchange archive data
/// through these regions without copying it through a pipe.
public final class SharedMemoryRegion {
    private static var counter = 0
    private static let counterLock = NSLock()

    public let name: String
    public let payloadSize: Int
    private let base: UnsafeMutableRawPointer
    private let length: Int
    // Whether releasing this object (or `unlink()`) removes the name.
    private var ownsName: Bool

    private init(name: String, payloadSize: Int, base: UnsafeMutableRawPointer, length: Int, ownsName: Bool) {
        self.name = name
        self.payloadSize = payloadSize
        self.base = base
        self.length = length
        self.ownsName = ownsName
    }

    /// A name unique to this process.  macOS limits names to 31 characters.
    public static func makeName() -> String {
        counterLock.lock()
        counter += 1
        let serial = counter
        counterLock.unlock()
        return "/fv.\(getpid()).\(serial)"
    }

    /// Creates a new, zero-filled region.  With `ownsName` the name is
    /// unlinked when the region is released; without it the name is left for
    /// another process to pick up.
    public static func create(name: String = makeName(), payloadSize: Int, ownsName: Bool = true) -> SharedMemoryRegion? {
        let fd = fastview_shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let length = Int(FASTVIEW_SHM_HEADER_SIZE) + payloadSize
        guard ftruncate(fd, off_t(length)) == 0, let base = fastview_map_shared(fd, length) else {
            shm_unlink(name)
            return nil
        }
        return SharedMemoryRegion(name: name, payloadSize: payloadSize, base: base, length: length, ownsName: ownsName)
    }

    /// Maps a region another process created.  With `takeOwnership` the name
    /// is unlinked when this object is released.
    public static func open(name: String, payloadSize: Int, takeOwnership: Bool = false) -> SharedMemoryRegion? {
        let fd = fastview_shm_open(name, O_RDWR, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let length = Int(FASTVIEW_SHM_HEADER_SIZE) + payloadSize
        guard let base = fastview_map_shared(fd, length) else { return nil }
        return SharedMemoryRegion(name: name, payloadSize: payloadSize, base: base, length: length, ownsName: takeOwnership)
    }

    public func word(_ index: Int32) -> UInt64 {
        fastview_load_word(base, index)
    }

    public func setWord(_ index: Int32, _ value: UInt64) {
        fastview_store_word(base, index, value)
    }

    public var payload: UnsafeMutableRawPointer { base + Int(FASTVIEW_SHM_HEADER_SIZE) }

    /// The first `count` payload bytes as Data, without copying.  The Data
    /// keeps this region mapped for as long as it lives.
    public func payloadData(count: Int? = nil) -> Data {
        Data(bytesNoCopy: payload, count: count ?? payloadSize, deallocator: .custom { [self] _, _ in
            withExtendedLifetime(self) {}
        })
    }

    /// Removes the name (if owned); existing mappings stay valid.
    public func unlink() {
        if ownsName {
            shm_unlink(name)
            ownsName = false
        }
    }

    /// Removes the name whether or not this object owns it.
    public func unlinkName() {
        shm_unlink(name)
        ownsName = false
    }

    deinit {
        unlink()
        munmap(base, length)
    }
}
