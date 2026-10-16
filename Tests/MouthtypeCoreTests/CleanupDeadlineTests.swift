import Foundation
import Testing
@testable import MouthtypeCore

private final class CancellationWake: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var didStart = false
    private var didCancel = false
    let returned = DispatchSemaphore(value: 0)

    var started: Bool { lock.withLock { didStart } }
    var cancelled: Bool { lock.withLock { didCancel } }

    func sleep() async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    self.continuation = continuation
                    didStart = true
                }
            }
        } onCancel: {
            let continuation = self.lock.withLock {
                self.didCancel = true
                return self.continuation
            }
            continuation?.resume()
        }
        throw CancellationError()
    }
}

@Suite struct CleanupDeadlineTests {
    @Test func completingWorkCannotLoseToItsTimersCancellationWakeUp() async throws {
        let gate = AsyncStream<Void>.makeStream()
        let work = Task { await gate.stream.first(where: { _ in true }) }
        let timer = CancellationWake()
        let result = Task {
            let completed = await SmartCleanup.waitForCompletion(work, sleep: { try await timer.sleep() }, cancelTimer: {
                $0.cancel()
                // Let the awakened timer settle before the completing watcher continues.
                _ = timer.returned.wait(timeout: .now() + 2)
            })
            timer.returned.signal()
            return completed
        }
        for _ in 0..<500 where !timer.started { try await Task.sleep(for: .milliseconds(1)) }
        #expect(timer.started)
        gate.continuation.yield(())
        gate.continuation.finish()
        #expect(await result.value)
        for _ in 0..<500 where !timer.cancelled { try await Task.sleep(for: .milliseconds(1)) }
        #expect(timer.cancelled)
        _ = await work.value
    }

    @Test func actualDeadlineReturnsWhileUncooperativeWorkIsStillWaiting() async throws {
        let gate = AsyncStream<Void>.makeStream()
        let work = Task { await gate.stream.first(where: { _ in true }) }
        let completed = await SmartCleanup.waitForCompletion(work, sleep: {
            try await ContinuousClock().sleep(for: .milliseconds(5))
        })
        #expect(!completed)
        #expect(!work.isCancelled)
        gate.continuation.yield(())
        gate.continuation.finish()
        _ = await work.value
    }
}
