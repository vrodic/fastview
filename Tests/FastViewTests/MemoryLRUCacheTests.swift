import XCTest
import AppKit
@testable import FastView

final class MemoryLRUCacheTests: XCTestCase {
    /// A cache holding at most `bytes` of cost.
    private func cache(holding bytes: Int) -> MemoryLRUCache {
        let fraction = Double(bytes) / Double(ProcessInfo.processInfo.physicalMemory)
        return MemoryLRUCache(memoryFraction: fraction, watchesMemoryPressure: false)
    }

    private let image = NSImage(size: NSSize(width: 1, height: 1))

    func testLeastRecentlyUsedIsEvictedFirst() {
        let cache = cache(holding: 30)
        cache.setObject(image, forKey: "a", cost: 10)
        cache.setObject(image, forKey: "b", cost: 10)
        cache.setObject(image, forKey: "c", cost: 10)
        XCTAssertNotNil(cache.object(forKey: "a")) // "b" is now the oldest
        cache.setObject(image, forKey: "d", cost: 10)
        XCTAssertNil(cache.object(forKey: "b"))
        XCTAssertNotNil(cache.object(forKey: "a"))
        XCTAssertNotNil(cache.object(forKey: "c"))
        XCTAssertNotNil(cache.object(forKey: "d"))
        XCTAssertEqual(cache.currentCost, 30)
    }

    func testReplacingAKeyCountsItsCostOnce() {
        let cache = cache(holding: 100)
        cache.setObject(image, forKey: "a", cost: 10)
        cache.setObject(image, forKey: "a", cost: 25)
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.currentCost, 25)
        cache.removeObject(forKey: "a")
        XCTAssertEqual(cache.currentCost, 0)
        XCTAssertNil(cache.object(forKey: "a"))
    }

    func testMemoryWarningHalvesTheCacheOldestFirst() {
        let cache = cache(holding: 1000)
        for key in ["a", "b", "c", "d"] { cache.setObject(image, forKey: key, cost: 10) }
        cache.handleMemoryPressure(critical: false)
        XCTAssertEqual(cache.currentCost, 20)
        XCTAssertNil(cache.object(forKey: "a"))
        XCTAssertNil(cache.object(forKey: "b"))
        XCTAssertNotNil(cache.object(forKey: "c"))
        XCTAssertNotNil(cache.object(forKey: "d"))
    }

    func testCriticalMemoryPressureEmptiesTheCache() {
        let cache = cache(holding: 1000)
        for key in ["a", "b", "c"] { cache.setObject(image, forKey: key, cost: 10) }
        cache.handleMemoryPressure(critical: true)
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.currentCost, 0)
        // Still usable afterwards.
        cache.setObject(image, forKey: "e", cost: 10)
        XCTAssertNotNil(cache.object(forKey: "e"))
    }
}
