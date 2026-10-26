import Foundation

/// The central directory of a ZIP archive, read with ranged reads: the tail
/// of the file (end-of-central-directory record), then the directory itself
/// in one sequential pass.  Entries are then extracted with one read each,
/// at the offsets recorded here, so opening an archive never reads it whole.
///
/// Names and entry types are decoded exactly as ZIPFoundation does (FastView
/// keys favourites and viewed images by entry path).
public struct ZipDirectory {
    public struct Entry {
        public let path: String
        public let kind: ArchiveEntryRecord.Kind
        public let flags: UInt16
        public let method: UInt16
        public let compressedSize: UInt64
        public let uncompressedSize: UInt64
        public let localHeaderOffset: UInt64

        public var record: ArchiveEntryRecord {
            ArchiveEntryRecord(path: path, uncompressedSize: uncompressedSize, compressedSize: compressedSize, kind: kind)
        }
    }

    /// Reads `count` bytes at `offset`; nil on error.  Short reads only at EOF.
    public typealias Reader = (_ offset: UInt64, _ count: Int) -> Data?

    public let entries: [Entry]
    public let centralDirectorySize: Int64

    private static let codepage437: String.Encoding = {
        let dosLatinUS = CFStringEncoding(0x400)
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(dosLatinUS))
    }()

    /// Reads and parses the central directory of a file of `fileSize` bytes.
    /// `progress` reports bytes of the directory read; `isCancelled` is
    /// checked between `chunkSize` reads.
    public static func read(fileSize: UInt64, chunkSize: Int, reader: Reader,
                            progress: (Int64, Int64) -> Void, isCancelled: () -> Bool) -> ZipDirectory? {
        guard let location = locateCentralDirectory(fileSize: fileSize, reader: reader) else { return nil }

        var directory = Data(capacity: Int(location.size))
        while directory.count < Int(location.size) {
            if isCancelled() { return nil }
            let count = min(chunkSize, Int(location.size) - directory.count)
            guard let chunk = reader(location.offset + UInt64(directory.count), count), !chunk.isEmpty else { return nil }
            directory.append(chunk)
            progress(Int64(directory.count), Int64(location.size))
        }
        guard let entries = parse(centralDirectory: [UInt8](directory), expectedCount: location.count) else { return nil }
        return ZipDirectory(entries: entries, centralDirectorySize: Int64(location.size))
    }

    /// Extracts `entry`: one read of its local header, one (chunked) read of
    /// its data, inflated if it is deflate-compressed.
    public static func extract(_ entry: Entry, chunkSize: Int, reader: Reader, isCancelled: () -> Bool) -> Data? {
        guard let stored = readStored(entry, chunkSize: chunkSize, reader: reader, isCancelled: isCancelled) else { return nil }
        return decode(stored, entry: entry)
    }

    /// The entry's bytes as stored in the archive (compressed or not).
    public static func readStored(_ entry: Entry, chunkSize: Int, reader: Reader, isCancelled: () -> Bool) -> Data? {
        guard entry.flags & 1 == 0, entry.kind == .file else { return nil }  // Encrypted, or not a file.
        guard let header = reader(entry.localHeaderOffset, 30), header.count == 30 else { return nil }
        let bytes = [UInt8](header)
        guard uint(bytes, 0, 4) == 0x04034b50 else { return nil }
        let dataOffset = entry.localHeaderOffset + 30 + uint(bytes, 26, 2) + uint(bytes, 28, 2)

        var stored = Data(capacity: Int(entry.compressedSize))
        while stored.count < Int(entry.compressedSize) {
            if isCancelled() { return nil }
            let count = min(chunkSize, Int(entry.compressedSize) - stored.count)
            guard let chunk = reader(dataOffset + UInt64(stored.count), count), !chunk.isEmpty else { return nil }
            stored.append(chunk)
        }
        return stored
    }

    /// Turns an entry's stored bytes into its contents.
    public static func decode(_ compressed: Data, entry: Entry) -> Data? {
        let output: Data?
        switch entry.method {
        case 0:
            output = compressed
        case 8:
            // NSData's .zlib is raw DEFLATE (RFC 1951), the ZIP format.
            output = try? (compressed as NSData).decompressed(using: .zlib) as Data
        default:
            output = nil
        }
        guard let data = output, UInt64(data.count) == entry.uncompressedSize else { return nil }
        return data
    }

    // MARK: Parsing

    private static func uint(_ bytes: [UInt8], _ offset: Int, _ width: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in (0..<width).reversed() {
            value = (value << 8) | UInt64(bytes[offset + i])
        }
        return value
    }

    private static func locateCentralDirectory(fileSize: UInt64, reader: Reader) -> (offset: UInt64, size: UInt64, count: Int)? {
        let eocdSize = 22
        guard fileSize >= UInt64(eocdSize) else { return nil }

        // The EOCD record sits at the end, optionally followed by a comment
        // of up to 64 KiB.
        let tailSize = Int(min(fileSize, UInt64(eocdSize + 0xFFFF)))
        guard let tailData = reader(fileSize - UInt64(tailSize), tailSize), tailData.count == tailSize else { return nil }
        let tail = [UInt8](tailData)

        var offset = tailSize - eocdSize
        while offset >= 0 {
            if uint(tail, offset, 4) == 0x06054b50 {
                var count = uint(tail, offset + 10, 2)
                var size = uint(tail, offset + 12, 4)
                var start = uint(tail, offset + 16, 4)
                if count == 0xFFFF || size == 0xFFFFFFFF || start == 0xFFFFFFFF, offset >= 20,
                   uint(tail, offset - 20, 4) == 0x07064b50,
                   let zip64Data = reader(uint(tail, offset - 20 + 8, 8), 56), zip64Data.count == 56 {
                    let zip64 = [UInt8](zip64Data)
                    guard uint(zip64, 0, 4) == 0x06064b50 else { return nil }
                    count = uint(zip64, 32, 8)
                    size = uint(zip64, 40, 8)
                    start = uint(zip64, 48, 8)
                }
                guard start + size <= fileSize else { return nil }
                return (start, size, Int(clamping: count))
            }
            offset -= 1
        }
        return nil
    }

    private static func parse(centralDirectory bytes: [UInt8], expectedCount: Int) -> [Entry]? {
        var entries: [Entry] = []
        entries.reserveCapacity(expectedCount)
        var offset = 0

        while offset + 46 <= bytes.count, uint(bytes, offset, 4) == 0x02014b50 {
            let versionMadeBy = uint(bytes, offset + 4, 2)
            let flags = UInt16(uint(bytes, offset + 8, 2))
            let method = UInt16(uint(bytes, offset + 10, 2))
            var compressedSize = uint(bytes, offset + 20, 4)
            var uncompressedSize = uint(bytes, offset + 24, 4)
            let nameLength = Int(uint(bytes, offset + 28, 2))
            let extraLength = Int(uint(bytes, offset + 30, 2))
            let commentLength = Int(uint(bytes, offset + 32, 2))
            let externalAttributes = uint(bytes, offset + 38, 4)
            var localHeaderOffset = uint(bytes, offset + 42, 4)

            let nameStart = offset + 46
            let extraStart = nameStart + nameLength
            let next = extraStart + extraLength + commentLength
            guard next <= bytes.count else { return nil }

            // ZIP64 extended information: present fields follow in this order.
            var extra = extraStart
            while extra + 4 <= extraStart + extraLength {
                let headerID = uint(bytes, extra, 2)
                let dataSize = Int(uint(bytes, extra + 2, 2))
                if headerID == 0x0001 {
                    var field = extra + 4
                    let end = field + dataSize
                    if uncompressedSize == 0xFFFFFFFF, field + 8 <= end { uncompressedSize = uint(bytes, field, 8); field += 8 }
                    if compressedSize == 0xFFFFFFFF, field + 8 <= end { compressedSize = uint(bytes, field, 8); field += 8 }
                    if localHeaderOffset == 0xFFFFFFFF, field + 8 <= end { localHeaderOffset = uint(bytes, field, 8) }
                }
                extra += 4 + dataSize
            }

            let nameData = Data(bytes[nameStart..<extraStart])
            let encoding = flags & (1 << 11) != 0 ? String.Encoding.utf8 : codepage437
            let path = String(data: nameData, encoding: encoding) ?? ""

            entries.append(Entry(path: path,
                                 kind: kind(path: path, versionMadeBy: versionMadeBy, externalAttributes: externalAttributes),
                                 flags: flags, method: method,
                                 compressedSize: compressedSize, uncompressedSize: uncompressedSize,
                                 localHeaderOffset: localHeaderOffset))
            offset = next
        }
        return entries
    }

    /// As ZIPFoundation's `Entry.type`.
    private static func kind(path: String, versionMadeBy: UInt64, externalAttributes: UInt64) -> ArchiveEntryRecord.Kind {
        let isDirectory = path.hasSuffix("/")
        switch versionMadeBy >> 8 {
        case 3, 19:  // Unix, macOS: the mode is in the upper half.
            switch mode_t(UInt16(truncatingIfNeeded: externalAttributes >> 16)) & S_IFMT {
            case S_IFREG: return .file
            case S_IFDIR: return .directory
            case S_IFLNK: return .symlink
            default: return isDirectory ? .directory : .file
            }
        case 0:  // MS-DOS
            return isDirectory || (externalAttributes >> 4) == 0x01 ? .directory : .file
        default:
            return isDirectory ? .directory : .file
        }
    }
}
