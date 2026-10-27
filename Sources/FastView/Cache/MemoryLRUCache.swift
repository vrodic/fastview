import Foundation
import AppKit

public class MemoryLRUCache {
    public static let shared = MemoryLRUCache()

    private class CacheEntry {
        let key: String
        let image: NSImage
        let cost: Int // Byte size
        var lastAccessed: Date

        init(key: String, image: NSImage, cost: Int) {
            self.key = key
            self.image = image
            self.cost = cost
            self.lastAccessed = Date()
        }
    }

    private var cache = [String: CacheEntry]()
    private var totalCost: Int = 0
    private let maxMemoryLimit: Int
    private let lock = NSLock()

    public var isLowMemoryMode: Bool = UserDefaults.standard.bool(forKey: "FastViewLowMemoryMode") {
        didSet {
            UserDefaults.standard.set(isLowMemoryMode, forKey: "FastViewLowMemoryMode")
            lock.lock()
            evictIfNecessary()
            lock.unlock()
        }
    }

    public init(memoryFraction: Double = 0.30) {
        let sysMemory = ProcessInfo.processInfo.physicalMemory
        self.maxMemoryLimit = Int(Double(sysMemory) * memoryFraction)
    }

    public func object(forKey key: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = cache[key] else { return nil }
        entry.lastAccessed = Date()
        return entry.image
    }

    public func setObject(_ image: NSImage, forKey key: String, cost: Int) {
        lock.lock()
        defer { lock.unlock() }

        if let existing = cache[key] {
            totalCost -= existing.cost
        }

        let entry = CacheEntry(key: key, image: image, cost: cost)
        cache[key] = entry
        totalCost += cost

        evictIfNecessary()
    }

    public func removeObject(forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        if let existing = cache.removeValue(forKey: key) {
            totalCost -= existing.cost
        }
    }

    private func evictIfNecessary() {
        let effectiveLimit = isLowMemoryMode ? 50 : Int.max
        while (totalCost > maxMemoryLimit || cache.count > effectiveLimit) && !cache.isEmpty {
            guard let oldest = cache.values.min(by: { $0.lastAccessed < $1.lastAccessed }) else { break }
            cache.removeValue(forKey: oldest.key)
            totalCost -= oldest.cost
        }
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
        totalCost = 0
        print("[CacheStats] Memory cache cleared.")
    }
}
