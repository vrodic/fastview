import Foundation
import AppKit

/// In-memory image cache (full images and thumbnails), least recently used first out. Bounded
/// by a share of physical memory, by an item count in Low Memory Mode, and trimmed when the
/// system reports memory pressure.
public class MemoryLRUCache {
    public static let shared = MemoryLRUCache()

    /// Items kept in Low Memory Mode, thumbnails included.
    public static let lowMemoryItemLimit = 50

    /// A node in the recency list: `head` is the most recently used, `tail` the least.
    private final class CacheEntry {
        let key: String
        let image: NSImage
        let cost: Int // Byte size
        var newer: CacheEntry?
        weak var older: CacheEntry?

        init(key: String, image: NSImage, cost: Int) {
            self.key = key
            self.image = image
            self.cost = cost
        }
    }

    private var cache = [String: CacheEntry]()
    private var head: CacheEntry?
    private var tail: CacheEntry?
    private var totalCost: Int = 0
    private let maxMemoryLimit: Int
    private let lock = NSLock()
    private var lowMemoryMode: Bool
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    public var isLowMemoryMode: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return lowMemoryMode
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "FastViewLowMemoryMode")
            lock.lock()
            lowMemoryMode = newValue
            evictIfNecessary()
            lock.unlock()
        }
    }

    public init(memoryFraction: Double = 0.30, watchesMemoryPressure: Bool = true) {
        let sysMemory = ProcessInfo.processInfo.physicalMemory
        self.maxMemoryLimit = Int(Double(sysMemory) * memoryFraction)
        self.lowMemoryMode = UserDefaults.standard.bool(forKey: "FastViewLowMemoryMode")
        if watchesMemoryPressure {
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
            source.setEventHandler { [weak self, weak source] in
                guard let event = source?.data else { return }
                self?.handleMemoryPressure(critical: event.contains(.critical))
            }
            source.resume()
            memoryPressureSource = source
        }
    }

    deinit {
        memoryPressureSource?.cancel()
    }

    /// Bytes held by the cached images (as their `cost`s say).
    public var currentCost: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalCost
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    public func object(forKey key: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = cache[key] else { return nil }
        moveToHead(entry)
        return entry.image
    }

    public func setObject(_ image: NSImage, forKey key: String, cost: Int) {
        lock.lock()
        defer { lock.unlock() }

        if let existing = cache.removeValue(forKey: key) {
            unlink(existing)
            totalCost -= existing.cost
        }

        let entry = CacheEntry(key: key, image: image, cost: cost)
        cache[key] = entry
        insertAtHead(entry)
        totalCost += cost

        evictIfNecessary()
    }

    public func removeObject(forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        if let existing = cache.removeValue(forKey: key) {
            unlink(existing)
            totalCost -= existing.cost
        }
    }

    /// A warning halves what the cache holds (oldest first); a critical level empties it.
    /// Shown images stay alive through their views, so nothing on screen goes blank.
    func handleMemoryPressure(critical: Bool) {
        lock.lock()
        defer { lock.unlock() }
        evict(downTo: critical ? 0 : totalCost / 2, maxCount: Int.max)
    }

    private func evictIfNecessary() {
        evict(downTo: maxMemoryLimit, maxCount: lowMemoryMode ? Self.lowMemoryItemLimit : Int.max)
    }

    /// Drops the least recently used images until both bounds hold. Call with `lock` held.
    private func evict(downTo costLimit: Int, maxCount: Int) {
        while totalCost > costLimit || cache.count > maxCount, let oldest = tail {
            unlink(oldest)
            cache.removeValue(forKey: oldest.key)
            totalCost -= oldest.cost
        }
    }

    private func insertAtHead(_ entry: CacheEntry) {
        entry.older = head
        entry.newer = nil
        head?.newer = entry
        head = entry
        if tail == nil { tail = entry }
    }

    private func unlink(_ entry: CacheEntry) {
        if let newer = entry.newer { newer.older = entry.older } else { head = entry.older }
        if let older = entry.older { older.newer = entry.newer } else { tail = entry.newer }
        entry.newer = nil
        entry.older = nil
    }

    private func moveToHead(_ entry: CacheEntry) {
        guard head !== entry else { return }
        unlink(entry)
        insertAtHead(entry)
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
        head = nil
        tail = nil
        totalCost = 0
    }
}
