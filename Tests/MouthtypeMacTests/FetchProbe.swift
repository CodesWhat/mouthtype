import Foundation

/// Lets a test hold a fake fetch open, know it is really in flight, and know it has returned, so a "stale result is dropped"
/// check waits for the stale result instead of guessing how long it takes.
final class FetchProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _started = false
    private var _finished = false
    private let gate = DispatchSemaphore(value: 0)

    var started: Bool { lock.withLock { _started } }
    var finished: Bool { lock.withLock { _finished } }

    func markStarted() { lock.withLock { _started = true } }
    func markFinished() { lock.withLock { _finished = true } }

    /// For a synchronous fetch closure: marks it started, blocks until `release()`, then marks it finished.
    /// The 60 second cap only bounds a hang.
    func hold() {
        markStarted()
        _ = gate.wait(timeout: .now() + 60)
        markFinished()
    }

    func release() { gate.signal() }

    func waitUntilStarted(timeout: Duration = .seconds(10)) async -> Bool {
        await Self.wait(timeout: timeout) { self.started }
    }

    func waitUntilFinished(timeout: Duration = .seconds(10)) async -> Bool {
        await Self.wait(timeout: timeout) { self.finished }
    }

    /// Polls until `condition` holds or the deadline passes. Returns whether it held.
    static func wait(timeout: Duration, until condition: @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
}
