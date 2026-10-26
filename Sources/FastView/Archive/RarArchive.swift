import Foundation
import Cunrar

/// RAR listing and extraction through the unrar DLL API (Cunrar), which
/// reads the archive file itself.
public enum RarArchive {
    private static func open(fileURL: URL, flags: inout RAROpenArchiveDataEx) -> UnsafeMutableRawPointer? {
        let handle = fileURL.path.utf8CString.withUnsafeBufferPointer { ptr -> UnsafeMutableRawPointer? in
            flags.ArcName = UnsafeMutablePointer(mutating: ptr.baseAddress)
            return UnsafeMutableRawPointer(RAROpenArchiveEx(&flags))
        }
        guard let handle = handle else { return nil }
        if flags.OpenResult != ERAR_SUCCESS {
            RARCloseArchive(handle)
            return nil
        }
        return handle
    }

    private static func fileName(of header: inout RARHeaderDataEx) -> String {
        return withUnsafePointer(to: &header.FileName.0) { String(cString: $0) }
    }

    /// Walks every file header, in on-disk order.  This touches the whole
    /// archive (one header before each file's data), so progress is reported
    /// as the packed bytes passed so far relative to `archiveSize`.
    public static func scan(fileURL: URL, archiveSize: Int64, progress: (Int64, Int64) -> Void, isCancelled: () -> Bool) -> [ArchiveEntryRecord]? {
        var flags = RAROpenArchiveDataEx()
        flags.OpenMode = UInt32(RAR_OM_LIST)
        guard let handle = open(fileURL: fileURL, flags: &flags) else { return nil }
        defer { RARCloseArchive(handle) }

        var header = RARHeaderDataEx()
        var records: [ArchiveEntryRecord] = []
        var scannedBytes: Int64 = 0

        while true {
            if isCancelled() { return nil }

            let result = RARReadHeaderEx(handle, &header)
            if result == ERAR_END_ARCHIVE { break }
            guard result == ERAR_SUCCESS else { return nil }

            let isDirectory = header.Flags & UInt32(RHDF_DIRECTORY) != 0
            let packedSize = UInt64(header.PackSizeHigh) << 32 | UInt64(header.PackSize)
            records.append(ArchiveEntryRecord(
                path: fileName(of: &header),
                uncompressedSize: UInt64(header.UnpSizeHigh) << 32 | UInt64(header.UnpSize),
                compressedSize: packedSize,
                kind: isDirectory ? .directory : .file
            ))
            scannedBytes += Int64(packedSize)
            progress(min(scannedBytes, archiveSize), archiveSize)

            guard RARProcessFile(handle, RAR_SKIP, nil, nil) == ERAR_SUCCESS else { break }
        }

        progress(archiveSize, archiveSize)
        return records
    }

    private final class ExtractContext {
        var data: Data
        let isCancelled: () -> Bool
        let onWrite: (Int) -> Void

        init(capacity: Int, isCancelled: @escaping () -> Bool, onWrite: @escaping (Int) -> Void) {
            self.data = Data(capacity: capacity)
            self.isCancelled = isCancelled
            self.onWrite = onWrite
        }
    }

    /// Extracts the entry stored as `entryName` into memory.  Cancellation is
    /// checked between skipped entries and while the entry is decompressed.
    ///
    /// `progress` receives the packed bytes passed so far: entries skipped
    /// (a solid archive decompresses each of them to reach the target) plus
    /// the decompressed share of the target itself.
    public static func extract(fileURL: URL, entryName: String, expectedSize: UInt64,
                               progress: @escaping (Int64) -> Void = { _ in },
                               isCancelled: @escaping () -> Bool) -> Data? {
        if expectedSize == 0 { return Data() }

        var flags = RAROpenArchiveDataEx()
        flags.OpenMode = UInt32(RAR_OM_EXTRACT)
        guard let handle = open(fileURL: fileURL, flags: &flags) else { return nil }
        defer { RARCloseArchive(handle) }

        var header = RARHeaderDataEx()
        var packedPassed: Int64 = 0

        while true {
            if isCancelled() { return nil }
            guard RARReadHeaderEx(handle, &header) == ERAR_SUCCESS else { return nil }
            let packedSize = Int64(header.PackSizeHigh) << 32 | Int64(header.PackSize)

            if fileName(of: &header) == entryName {
                let passedBefore = packedPassed
                let context = ExtractContext(capacity: Int(expectedSize), isCancelled: isCancelled) { written in
                    progress(passedBefore + packedSize * Int64(written) / Int64(max(1, expectedSize)))
                }

                let callback: UNRARCALLBACK = { msg, userData, p1, p2 in
                    guard msg == UCM_PROCESSDATA.rawValue,
                          let contextPtr = UnsafeRawPointer(bitPattern: userData),
                          let bytes = UnsafeRawPointer(bitPattern: p1) else { return 0 }
                    let context = Unmanaged<ExtractContext>.fromOpaque(contextPtr).takeUnretainedValue()
                    if context.isCancelled() { return -1 }
                    context.data.append(bytes.assumingMemoryBound(to: UInt8.self), count: p2)
                    context.onWrite(context.data.count)
                    return 0
                }

                let result: Int32 = withExtendedLifetime(context) {
                    let contextPtr = Unmanaged.passUnretained(context).toOpaque()
                    RARSetCallback(handle, callback, Int(bitPattern: contextPtr))
                    defer { RARSetCallback(handle, nil, 0) }
                    // RAR_TEST decompresses into the callback without writing to disk.
                    return RARProcessFile(handle, RAR_TEST, nil, nil)
                }

                guard result == ERAR_SUCCESS, UInt64(context.data.count) == expectedSize else { return nil }
                return context.data
            }

            guard RARProcessFile(handle, RAR_SKIP, nil, nil) == ERAR_SUCCESS else { return nil }
            packedPassed += packedSize
            progress(packedPassed)
        }
    }
}
