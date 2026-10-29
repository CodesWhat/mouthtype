import Foundation
import Testing

@testable import MouthtypeMac

@Suite struct SendTargetPreparationTests {
    private let claude = "com.anthropic.claudefordesktop"

    private func decide(_ focus: FocusSnapshot, listed: Set<String>) -> Bool {
        SendTargetPreparation.shouldEnable(focus: focus, isListed: { listed.contains($0) })
    }

    @Test func listedAppWithAPidIsEnabled() {
        #expect(decide(FocusSnapshot(pid: 10, bundleID: claude), listed: [claude]))
    }

    @Test func unlistedAppIsNotEnabled() {
        #expect(!decide(FocusSnapshot(pid: 10, bundleID: "com.apple.Notes"), listed: [claude]))
    }

    @Test func secureFocusIsNotEnabled() {
        #expect(!decide(FocusSnapshot(pid: 10, bundleID: claude, isSecure: true), listed: [claude]))
    }

    @Test(arguments: [nil, 0, -1] as [pid_t?])
    func missingOrNonPositivePidIsNotEnabled(pid: pid_t?) {
        #expect(!decide(FocusSnapshot(pid: pid, bundleID: claude), listed: [claude]))
    }

    @Test func missingBundleIDIsNotEnabled() {
        #expect(!decide(FocusSnapshot(pid: 10, bundleID: nil), listed: [claude]))
    }
}

@Suite struct SendTargetReadinessTests {
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private let succeedsOnCall: Int?
        convenience init(succeedsOnCall: Int?) { self.init(succeedsOnCall: succeedsOnCall, latency: nil) }
        var count: Int { lock.withLock { calls } }
        private var timeouts: [Duration] = []
        private let latency: (@Sendable () -> Void)?
        var seenTimeouts: [Duration] { lock.withLock { timeouts } }
        init(succeedsOnCall: Int?, latency: (@Sendable () -> Void)?) {
            self.succeedsOnCall = succeedsOnCall
            self.latency = latency
        }
        func read(_ timeout: Duration) -> Bool {
            latency?()
            return lock.withLock {
                timeouts.append(timeout)
                calls += 1
                return succeedsOnCall.map { calls >= $0 } ?? false
            }
        }
    }

    /// A handle on a fake clock whose sleep moves the clock instead of waiting.
    private func readiness(
        clock: TestInstants, enabledAgo: Duration?, probe: Probe,
        sleep: (@Sendable (Duration) async throws -> Void)? = nil
    ) -> SendTargetReadiness {
        let setAt = enabledAgo.map { clock.now - $0 }
        return SendTargetReadiness(
            pid: 5, enable: Task {}, enabledAt: { _ in setAt }, probe: { _, timeout in probe.read(timeout) },
            now: { clock.now }, sleep: sleep ?? { clock.advance($0) }
        )
    }

    @Test func returnsAtOnceWhenTheFlagWasSetLongAgo() async {
        let probe = Probe(succeedsOnCall: nil)
        await readiness(clock: TestInstants(), enabledAgo: .seconds(10), probe: probe).waitUntilReady()
        #expect(probe.count == 0)
    }

    @Test func returnsAtOnceWhenTheFlagWasExactlyTheLimitAgo() async {
        let probe = Probe(succeedsOnCall: nil)
        await readiness(clock: TestInstants(), enabledAgo: SendTargetReadiness.settleLimit, probe: probe).waitUntilReady()
        #expect(probe.count == 0)
    }

    @Test func returnsAtOnceWhenTheFlagWasNeverSet() async {
        let probe = Probe(succeedsOnCall: nil)
        await readiness(clock: TestInstants(), enabledAgo: nil, probe: probe).waitUntilReady()
        #expect(probe.count == 0)
    }

    @Test func returnsAsSoonAsTheProbeTurnsTrue() async {
        let clock = TestInstants()
        let probe = Probe(succeedsOnCall: 4)
        let start = clock.now
        await readiness(clock: clock, enabledAgo: .zero, probe: probe).waitUntilReady()
        #expect(probe.count == 4)
        #expect(clock.now - start == .milliseconds(300))
    }

    @Test func returnsAtTheDeadlineWhenTheProbeNeverTurnsTrue() async {
        let clock = TestInstants()
        let probe = Probe(succeedsOnCall: nil)
        let start = clock.now
        await readiness(clock: clock, enabledAgo: .milliseconds(500), probe: probe).waitUntilReady()
        #expect(clock.now - start == .seconds(2))
        #expect(probe.count == 20)
    }

    @Test func returnsOnCancellationBeforeItStarts() async {
        let clock = TestInstants()
        let probe = Probe(succeedsOnCall: nil)
        let handle = readiness(clock: clock, enabledAgo: .zero, probe: probe, sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        let waiting = Task { await handle.waitUntilReady() }
        waiting.cancel()
        _ = await waiting.value
        #expect(probe.count <= 1)
    }

    private static func blocking(_ work: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                work()
                continuation.resume()
            }
        }
    }

    @Test func returnsWhenCancelledDuringTheWaitAndTheTakeDoesNotDeliver() async {
        let clock = TestInstants()
        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let probe = Probe(
            succeedsOnCall: nil,
            latency: {
                entered.signal()
                gate.wait()
            })
        let handle = readiness(clock: clock, enabledAgo: .zero, probe: probe, sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        let delivered = Flag()
        let take = Task {
            await handle.waitUntilReady()
            if !Task.isCancelled { delivered.set() }
        }
        await Self.blocking { entered.wait() }
        take.cancel()
        gate.signal()
        _ = await take.value
        #expect(probe.count == 1)
        #expect(!delivered.value)
    }

    @Test func theWaitNeverOvershootsTheLimitWhenProbesAreSlowAndTheDeadlineIsOffTheGrid() async {
        let clock = TestInstants()
        let probe = Probe(succeedsOnCall: nil, latency: { clock.advance(.milliseconds(70)) })
        let start = clock.now
        // 130 ms already used, so 2370 ms remain: not a multiple of the 100 ms poll.
        let deadline = start - .milliseconds(130) + SendTargetReadiness.settleLimit
        await readiness(clock: clock, enabledAgo: .milliseconds(130), probe: probe).waitUntilReady()
        #expect(clock.now <= deadline)
        #expect(probe.seenTimeouts.allSatisfy { $0 <= SendTargetReadiness.pollInterval })
        #expect(probe.seenTimeouts.last.map { $0 <= .milliseconds(100) } == true)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
