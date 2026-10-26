import Foundation

public class FileLogger {
    public static let shared = FileLogger()
    private let formatter = DateFormatter()
    private let lock = NSLock()

    public init() {
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    }

    public func log(_ operation: String, path: String, durationMs: Double? = nil) {
        lock.lock()
        defer { lock.unlock() }

        let timestamp = formatter.string(from: Date())
        var msg: String
        if let ms = durationMs {
            let sec = ms / 1000.0
            msg = String(format: "[DiskOp %@] %@ | %@ | %.2f ms (%.2fs)", timestamp, operation, path, ms, sec)
            if ms >= 1000.0 {
                // Mark operations over 1 sec in red using ANSI escape code
                msg = "\u{001B}[31m\(msg)\u{001B}[0m"
            }
        } else {
            msg = "[DiskOp \(timestamp)] \(operation) | \(path)"
        }

        print(msg)
    }

    /// Logs a read of `bytes` with its throughput, e.g. "path | 1.2 GB @ 98.4 MB/s".
    public func logThroughput(_ operation: String, path: String, bytes: Int64, startTime: CFAbsoluteTime) {
        let seconds = CFAbsoluteTimeGetCurrent() - startTime
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let rate = seconds > 0 ? Double(bytes) / seconds / (1024.0 * 1024.0) : 0
        log(operation, path: String(format: "%@ | %@ @ %.1f MB/s", path, size, rate), durationMs: seconds * 1000.0)
    }
}
