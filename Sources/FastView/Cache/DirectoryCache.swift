import Foundation

public class DirectoryCache {
    public static let shared = DirectoryCache()
    private var cache = [String: [FileItem]]()
    private let lock = NSLock()

    public func get(key: String) -> [FileItem]? {
        lock.lock()
        defer { lock.unlock() }
        return cache[key]
    }

    public func set(key: String, items: [FileItem]) {
        lock.lock()
        defer { lock.unlock() }
        cache[key] = items
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
    }
}
