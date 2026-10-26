import Foundation

/// One archive entry, as listed by the archive service.
public struct ArchiveEntryRecord: Equatable {
    public enum Kind: Int {
        case file
        case directory
        case symlink
    }

    /// Path inside the archive, exactly as stored (RAR may use backslashes).
    public let path: String
    public let uncompressedSize: UInt64
    public let compressedSize: UInt64
    public let kind: Kind

    public init(path: String, uncompressedSize: UInt64, compressedSize: UInt64 = 0, kind: Kind) {
        self.path = path
        self.uncompressedSize = uncompressedSize
        self.compressedSize = compressedSize
        self.kind = kind
    }
}
