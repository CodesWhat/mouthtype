import Foundation
import Testing
@testable import MouthtypeCore

final class FakeMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval
    init(_ start: TimeInterval = 1_000) { value = start }
    var now: TimeInterval { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

@Suite struct TypingCalibrationTests {
    private let passage = String(repeating: "abcde", count: 100)  // 500 characters

    private func make(_ clock: FakeMonotonicClock) -> TypingCalibration {
        TypingCalibration(passage: passage, now: { clock.now })
    }

    private func typed(_ count: Int, wrong: Int = 0) -> String {
        let right = String(passage.prefix(count - wrong))
        return right + String(repeating: "#", count: wrong)
    }

    @Test func clockWaitsForTheFirstTypedCharacter() {
        let clock = FakeMonotonicClock()
        var test = make(clock)
        test.start()
        #expect(test.phase == .ready)
        clock.advance(30)  // sitting on Start does not count
        test.input("")
        #expect(test.phase == .ready)
        test.input("a")
        #expect(test.phase == .running(startedAt: clock.now))
        #expect(test.remaining == 60)
    }

    @Test func scoresFiveCharactersToAWordOverTheElapsedTime() {
        let clock = FakeMonotonicClock()
        var test = make(clock)
        test.start()
        test.input("a")
        clock.advance(30)
        test.input(typed(150))  // 150 chars = 30 words in half a minute = 60 WPM
        test.stop()
        guard case .finished(let result) = test.phase else { Issue.record("no result: \(test.phase)"); return }
        #expect(result.wpm == 60)
        #expect(result.correctCharacters == 150)
        #expect(result.errorCharacters == 0)
        #expect(result.elapsed == 30)
        #expect(result.roundedWPM == 60)
    }

    @Test func errorsAreCountedSeparatelyAndNotScoredAsCorrect() {
        let clock = FakeMonotonicClock()
        var test = make(clock)
        test.start()
        test.input("a")
        clock.advance(60)
        test.input(typed(200, wrong: 10))  // 190 right in a full minute = 38 WPM
        guard case .finished(let result) = test.phase else { Issue.record("no result: \(test.phase)"); return }
        #expect(result.correctCharacters == 190)
        #expect(result.errorCharacters == 10)
        #expect(abs(result.wpm - 38) < 0.0001)
    }

    @Test func correctingAMistakeRemovesTheError() {
        let clock = FakeMonotonicClock()
        var test = make(clock)
        test.start()
        test.input("abcdX")
        #expect(test.errorCharacters == 1)
        clock.advance(5)
        test.input("abcde")
        #expect(test.errorCharacters == 0 && test.correctCharacters == 5)
    }

    @Test func endsAtTheMinuteEvenWithoutAKey() {
        let clock = FakeMonotonicClock()
        var test = make(clock)
        test.start()
        test.input(typed(120))
        clock.advance(59.9)
        test.tick()
        #expect(test.isActive)
        clock.advance(0.2)
        test.tick()
        guard case .finished(let result) = test.phase else { Issue.record("no result: \(test.phase)"); return }
        #expect(result.elapsed == 60)
        #expect(result.wpm == 24)
    }

    @Test func finishingThePassageEarlyScoresOverTheTimeTaken() {
        let clock = FakeMonotonicClock()
        var test = make(clock)
        test.start()
        test.input("a")
        clock.advance(30)
        test.input(typed(500))  // 100 words in half a minute
        guard case .finished(let result) = test.phase else { Issue.record("no result: \(test.phase)"); return }
        #expect(result.wpm == 200)
    }

    @Test func stoppingTooSoonIsNotAResult() {
        let clock = FakeMonotonicClock()
        var test = make(clock)
        test.start()
        test.input("abc")
        clock.advance(4)
        test.stop()
        #expect(test.phase == .tooShort)
    }

    @Test func anImplausibleSpeedIsNotAResult() {
        let clock = FakeMonotonicClock()
        var test = make(clock)
        test.start()
        test.input("#")  // nothing correct: 0 WPM
        clock.advance(20)
        test.stop()
        #expect(test.phase == .tooShort)
    }

    @Test func cancellingLeavesNoResultAndDropsTheCounts() {
        let clock = FakeMonotonicClock()
        var test = make(clock)
        test.start()
        test.input(typed(100))
        clock.advance(40)
        test.cancel()
        #expect(test.phase == .cancelled)
        #expect(test.correctCharacters == 0 && test.errorCharacters == 0)
        clock.advance(100)
        test.tick()
        test.input(typed(100))
        test.stop()
        #expect(test.phase == .cancelled)
    }

    @Test func textTypedBeforeStartIsIgnoredAndRetryStartsOver() {
        let clock = FakeMonotonicClock()
        var test = make(clock)
        test.input("abc")
        #expect(test.phase == .idle)
        test.start()
        test.input("a")
        clock.advance(20)
        test.input(typed(100))
        test.stop()
        #expect(test.phase != .idle)
        test.retry()
        #expect(test.phase == .idle && test.correctCharacters == 0)
    }

    @Test func baselinePreferencePersistsAcrossRelaunchAndResets() throws {
        let name = "TypingCalibrationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(TypingBaselinePreference.current(defaults) == 40)
        TypingBaselinePreference.accept(
            TypingCalibrationResult(wpm: 87.6, correctCharacters: 438, errorCharacters: 2, elapsed: 60), in: defaults)
        let relaunched = try #require(UserDefaults(suiteName: name))
        #expect(TypingBaselinePreference.current(relaunched) == 88)
        TypingBaselinePreference.reset(in: relaunched)
        #expect(TypingBaselinePreference.current(relaunched) == 40)
        // Garbage in the defaults falls back to the default rather than skewing the numbers.
        defaults.set(-5.0, forKey: TypingBaselinePreference.key)
        #expect(TypingBaselinePreference.current(defaults) == 40)
    }

    @Test func nothingButTheSpeedIsStored() throws {
        let name = "TypingCalibrationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        TypingBaselinePreference.accept(
            TypingCalibrationResult(wpm: 70, correctCharacters: 350, errorCharacters: 3, elapsed: 60), in: defaults)
        let stored = defaults.persistentDomain(forName: name) ?? [:]
        #expect(Set(stored.keys) == [TypingBaselinePreference.key])
    }

    @Test func acceptedSpeedChangesMinutesSaved() {
        let sample = DictationSample(
            day: "2026-10-18", startedAt: Date(timeIntervalSince1970: 0), words: 400, durationMs: 120_000)
        let slow = StatsEngine(samples: [sample], typingWPM: 40).report(today: "2026-10-18")
        let fast = StatsEngine(samples: [sample], typingWPM: 100).report(today: "2026-10-18")
        #expect(slow.minutesSaved > fast.minutesSaved)
        #expect(fast.typingWPM == 100)
    }
}
