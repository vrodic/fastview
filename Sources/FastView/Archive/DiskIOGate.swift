import Foundation

/// Serialises disk I/O across every queue that touches the image library.
///
/// The library typically lives on a network share backed by a mechanical
/// drive, where two concurrent readers just make the heads seek back and forth
/// and both finish later.  Each operation that reads from disk runs inside
/// `perform`, so only one runs at a time.
///
/// Interactive work (opening a location, loading the selected image) is
/// admitted before any waiting background work.  The gate never interrupts a
/// running operation: callers cancel background work they no longer need
/// (`ThumbnailGenerator.cancelAllThumbnailTasks`), and the I/O loops check
/// cancellation between reads.
///
/// Not reentrant: code running inside `perform` must not call it again.
public final class DiskIOGate {
    public static let shared = DiskIOGate()

    public enum Priority {
        case interactive
        case background
    }

    private let condition = NSCondition()
    private var isBusy = false
    private var waitingInteractive = 0

    /// Runs `body` once no other disk operation is running.  Waits longer
    /// than 50 ms are logged as IO_GATE_WAIT with `label`, so slow operations
    /// can be told apart from operations queued behind them.
    /// True while an interactive request is waiting for the gate.  Background
    /// work checks it as part of its cancellation so it gets out of the way
    /// (a helper read is killed and later resumes where it stopped).
    public var hasInteractiveWaiting: Bool {
        condition.lock()
        defer { condition.unlock() }
        return waitingInteractive > 0
    }

    public func perform<T>(_ priority: Priority, label: String, _ body: () -> T) -> T {
        let waitStart = CFAbsoluteTimeGetCurrent()
        condition.lock()
        if priority == .interactive {
            waitingInteractive += 1
        }
        while isBusy || (priority == .background && waitingInteractive > 0) {
            condition.wait()
        }
        if priority == .interactive {
            waitingInteractive -= 1
        }
        isBusy = true
        condition.unlock()

        let waitedMs = (CFAbsoluteTimeGetCurrent() - waitStart) * 1000.0
        if waitedMs >= 50 {
            FileLogger.shared.log(priority == .interactive ? "IO_GATE_WAIT_INTERACTIVE" : "IO_GATE_WAIT_BACKGROUND", path: label, durationMs: waitedMs)
        }

        defer {
            condition.lock()
            isBusy = false
            condition.broadcast()
            condition.unlock()
        }
        return body()
    }
}
