import Foundation
import Testing
@testable import MouthtypeCore
@testable import MouthtypeMac

@MainActor @Suite struct TypingCalibrationModelTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 500
        var now: TimeInterval { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let name = "TypingCalibrationModelTests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    private func makeModel(
        _ defaults: UserDefaults, clock: Clock, accepted: @escaping @MainActor () -> Void = {}
    ) -> TypingCalibrationModel {
        TypingCalibrationModel(
            defaults: defaults, now: { clock.now }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            onAccepted: accepted)
    }

    /// Types like a keyboard: a few characters per change.
    private func feed(_ model: TypingCalibrationModel, characters: Int) {
        var end = model.text.count
        while end < characters {
            end = min(characters, end + 5)
            model.text = String(TypingCalibrationModel.passage.prefix(end))
        }
    }

    private func run(_ model: TypingCalibrationModel, clock: Clock, characters: Int, seconds: TimeInterval) {
        model.start()
        model.text = String(TypingCalibrationModel.passage.prefix(1))
        feed(model, characters: characters)
        clock.advance(seconds)
        model.stop()
    }

    @Test func acceptingStoresOnlyTheSpeedAndSurvivesRelaunch() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let clock = Clock()
        var notified = 0
        let model = makeModel(defaults, clock: clock, accepted: { notified += 1 })
        run(model, clock: clock, characters: 300, seconds: 60)  // 60 words in a minute
        #expect(model.result?.roundedWPM == 60)
        #expect(model.baseline == 40, "the prior baseline stands until the result is accepted")
        model.accept()
        #expect(model.baseline == 60 && notified == 1)
        #expect(Set((defaults.persistentDomain(forName: name) ?? [:]).keys) == [TypingBaselinePreference.key])
        let relaunched = makeModel(try #require(UserDefaults(suiteName: name)), clock: clock)
        #expect(relaunched.baseline == 60 && relaunched.isCustomBaseline)
        relaunched.reset()
        #expect(relaunched.baseline == 40 && !relaunched.isCustomBaseline)
    }

    @Test func retryAndCancelLeaveTheBaselineAlone() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let clock = Clock()
        let model = makeModel(defaults, clock: clock)
        run(model, clock: clock, characters: 300, seconds: 60)
        model.retry()
        #expect(model.result == nil && model.phase == .idle && model.text.isEmpty)
        model.start()
        model.text = "abc"
        clock.advance(30)
        model.cancel()  // the app went to the background
        #expect(model.result == nil && model.phase == .cancelled && model.text.isEmpty)
        model.accept()  // nothing to accept
        #expect(model.baseline == 40)
        #expect(defaults.persistentDomain(forName: name)?.isEmpty ?? true)
    }

    @Test func acceptedSpeedChangesMinutesSavedInTheSnapshot() async throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-typing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TranscriptStore(url: dir.appendingPathComponent("mouthtype.sqlite"))
        let id = try store.begin(DictationStart(startedAt: Date().addingTimeInterval(-600), target: DictationTarget(appName: "Notes")))
        try store.recordCapture(id, CaptureRecord(audioMs: 61_000, voicedMs: 60_000))
        try store.recordInsertion(id, InsertionRecord(finalText: Array(repeating: "word", count: 400).joined(separator: " ")))
        let model = StatsModel(store: store, observing: false, defaults: defaults)
        await model.load()
        let before = try #require(model.snapshot).report
        #expect(before.typingWPM == 40)
        TypingBaselinePreference.accept(
            TypingCalibrationResult(wpm: 100, correctCharacters: 500, errorCharacters: 0, elapsed: 60), in: defaults)
        await model.load()
        let after = try #require(model.snapshot).report
        #expect(after.typingWPM == 100)
        #expect(after.minutesSaved < before.minutesSaved)
        TypingBaselinePreference.reset(in: defaults)
        await model.load()
        #expect(model.snapshot?.report.typingWPM == 40)
    }

    @Test func pastedPassageOffersNoResultAndNothingToAccept() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let clock = Clock()
        let model = makeModel(defaults, clock: clock)
        model.start()
        model.text = String(TypingCalibrationModel.passage.prefix(1))
        clock.advance(30)
        model.text = TypingCalibrationModel.passage  // pasted whole
        model.stop()
        #expect(model.phase == .pasted && model.result == nil)
        model.accept()
        #expect(model.baseline == 40)
        model.retry()
        #expect(model.phase == .idle)
    }

    @Test func tickingPastTheMinuteFinishesTheRun() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let clock = Clock()
        let model = makeModel(defaults, clock: clock)
        model.start()
        feed(model, characters: 100)
        clock.advance(61)
        model.tick()
        #expect(model.result?.elapsed == 60)
        #expect(model.remaining == 0)
    }
}
