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
        if let ms = durationMs {
            print(String(format: "[FileOp %@] %@ | %@ | %.2f ms", timestamp, operation, path, ms))
        } else {
            print("[FileOp \(timestamp)] \(operation) | \(path)")
        }
    }
}
