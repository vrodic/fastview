import Foundation

/// One archive entry, as listed by the archive service.
public struct ArchiveEntryRecord: Codable, Equatable {
    public enum Kind: Int, Codable {
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

/// A request to the archive service, sent to the FastViewReader helper as
/// one JSON line on its stdin.
public struct ArchiveRequest: Codable {
    public enum Operation: String, Codable {
        /// Result: JSON-encoded `[ArchiveEntryRecord]`.
        case list
        /// Result: the bytes of `entryPath`.
        case extract
        /// Lists the archive, picks its preview image and extracts it (as a
        /// thumbnail when `previewMaxPixelSize` is set) in one go.  Result:
        /// see `ArchivePreviewHeader`.
        case preview
        /// Reads ahead the images following `entryPath`, so viewing them next
        /// does not wait for the disk.  Result: JSON number of entries read.
        case prefetch
    }

    public enum Kind: String, Codable {
        case zip
        case rar
    }

    public let operation: Operation
    public let kind: Kind
    public let path: String
    /// For archives on network volumes: the shared-memory object holding the
    /// whole archive.  It outlives a killed helper, so the next one adopts
    /// it, resuming an unfinished read at its published offset.  `nil` maps
    /// the file directly (local volumes).
    public let regionName: String?
    public let fileSize: Int
    public let entryPath: String?
    public let entrySize: UInt64?
    /// Where the helper writes the result (a new shared-memory object).
    public let resultName: String
    /// `preview`: downscale to at most this many pixels (nil: the image file).
    public let previewMaxPixelSize: Int?
    /// `preview`: also return the entry list (FastView may have it already).
    public let includeEntries: Bool?

    public init(operation: Operation, kind: Kind, path: String, regionName: String?, fileSize: Int,
                entryPath: String? = nil, entrySize: UInt64? = nil, resultName: String,
                previewMaxPixelSize: Int? = nil, includeEntries: Bool? = nil) {
        self.operation = operation
        self.kind = kind
        self.path = path
        self.regionName = regionName
        self.fileSize = fileSize
        self.entryPath = entryPath
        self.entrySize = entrySize
        self.resultName = resultName
        self.previewMaxPixelSize = previewMaxPixelSize
        self.includeEntries = includeEntries
    }
}

/// The helper's reply to an `ArchiveRequest`, one JSON line on its stdout.
public struct ArchiveResponse: Codable {
    public let ok: Bool
    public let resultLength: Int
    /// Archive regions the service dropped from its cache (and unlinked).
    public let evictedRegions: [String]
    /// The request stopped because FastView asked it to (not a failure).
    public let cancelled: Bool

    public init(ok: Bool, resultLength: Int, evictedRegions: [String], cancelled: Bool = false) {
        self.ok = ok
        self.resultLength = resultLength
        self.evictedRegions = evictedRegions
        self.cancelled = cancelled
    }
}

public enum ProgressUnit: UInt64 {
    case bytes = 0
    case entries = 1
}

/// Header words of the helper's control region, which carries the progress
/// of the request in flight.  Word 1 of an archive region is its bytes read.
public enum HelperControlWord {
    public static let progressCompleted: Int32 = 1
    public static let progressTotal: Int32 = 2
    public static let progressUnit: Int32 = 4
    /// Set by FastView to stop the request in flight at its next check; the
    /// helper (and its open archives) survive.  Cleared for each request.
    public static let stopRequested: Int32 = 5
    public static let archiveBytesRead: Int32 = 1
}
