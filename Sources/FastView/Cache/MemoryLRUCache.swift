import Foundation
import AppKit

public class MemoryLRUCache {
    public static let shared = MemoryLRUCache()

    private class CacheEntry {
        let key: String
        let data: Data
        let cost: Int // Byte size (defaults to data.count)
        var lastAccessed: Date

        init(key: String, data: Data, cost: Int? = nil) {
            self.key = key
            self.data = data
            self.cost = cost ?? data.count
            self.lastAccessed = Date()
        }
    }

    private var cache = [String: CacheEntry]()
    private var totalCost: Int = 0
    private let maxMemoryLimit: Int
    private let lock = NSLock()

    public init(memoryFraction: Double = 0.30) {
        let sysMemory = ProcessInfo.processInfo.physicalMemory
        self.maxMemoryLimit = Int(Double(sysMemory) * memoryFraction)
    }

    public func object(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = cache[key] else { return nil }
        entry.lastAccessed = Date()
        printCacheStats()
        return entry.data
    }

    public func setObject(_ data: Data, forKey key: String, cost: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }

        if let existing = cache[key] {
            totalCost -= existing.cost
        }

        let entry = CacheEntry(key: key, data: data, cost: cost)
        cache[key] = entry
        totalCost += entry.cost

        evictIfNecessary()
        printCacheStats()
    }

    private func evictIfNecessary() {
        while totalCost > maxMemoryLimit && !cache.isEmpty {
            guard let oldest = cache.values.min(by: { $0.lastAccessed < $1.lastAccessed }) else { break }
            cache.removeValue(forKey: oldest.key)
            totalCost -= oldest.cost
        }
    }

    private func printCacheStats() {
        let usedMB = Double(totalCost) / (1024.0 * 1024.0)
        let maxMB = Double(maxMemoryLimit) / (1024.0 * 1024.0)
        print(String(format: "[CacheStats] Count: %d items | Memory: %.2f MB / %.2f MB (%.1f%%)",
                     cache.count, usedMB, maxMB, (usedMB / maxMB) * 100.0))
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
        totalCost = 0
        print("[CacheStats] Memory cache cleared.")
    }
}
