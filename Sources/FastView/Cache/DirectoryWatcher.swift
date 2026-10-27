import Foundation
import CoreServices

/// Watches folders for files appearing, disappearing or changing in them (not in their
/// subfolders) with FSEvents, and reports changed folders on the main thread. Hidden files
/// (.DS_Store and the like) are ignored, as the listings skip them. Changes made on another
/// machine to a network volume are usually not reported by macOS.
public final class DirectoryWatcher {
    /// Called on the main thread with each watched folder that changed, and the paths in it
    /// that were modified in place (files whose contents changed).
    public var onChange: ((_ folder: String, _ modifiedPaths: Set<String>) -> Void)?

    /// Events arriving within this many seconds are delivered together.
    private let latency: CFTimeInterval
    private var stream: FSEventStreamRef?
    /// Watched folders by their path with symlinks resolved, which is how FSEvents reports them.
    private var folders: [String: String] = [:]

    public init(latency: CFTimeInterval = 0.5) {
        self.latency = latency
    }

    deinit {
        stopStream()
    }

    /// Watches exactly `paths` (folders). Call on the main thread.
    public func watch(_ paths: Set<String>) {
        var resolved: [String: String] = [:]
        for path in paths {
            // realpath, not resolvingSymlinksInPath, which strips /private and so misses /var paths.
            let real = realpath(path, nil).map { p -> String in defer { free(p) }; return String(cString: p) }
            resolved[real ?? path] = path
        }
        guard resolved != folders else { return }
        stopStream()
        folders = resolved
        guard !resolved.isEmpty else { return }

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, DirectoryWatcher.callback, &context,
                                               Array(resolved.keys) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               latency, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func stopStream() {
        guard let stream = stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
        guard let info = info else { return }
        let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
        let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
        watcher.handle(paths: paths, flags: Array(UnsafeBufferPointer(start: eventFlags, count: count)))
    }

    private func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        var changed: [String: Set<String>] = [:]
        for (path, flag) in zip(paths, flags) {
            let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
            if (flag & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)) != 0
                || (flag & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)) != 0 {
                // Events were dropped, or a watched folder itself moved: rescan what it covers.
                for (resolved, original) in folders where resolved.hasPrefix(trimmed) || trimmed.hasPrefix(resolved) {
                    if changed[original] == nil { changed[original] = [] }
                }
                continue
            }
            let name = (trimmed as NSString).lastPathComponent
            // A subfolder whose own contents changed: the listing shows it the same.
            let addedOrRemoved = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed)
            let isDir = (flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)) != 0
            guard !name.hasPrefix("."), !isDir || (flag & addedOrRemoved) != 0,
                  let original = folders[(trimmed as NSString).deletingLastPathComponent] else { continue }
            var modified = changed[original, default: []]
            if (flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)) != 0 {
                modified.insert((original as NSString).appendingPathComponent(name))
            }
            changed[original] = modified
        }
        for (folder, modified) in changed {
            onChange?(folder, modified)
        }
    }
}
