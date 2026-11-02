import Foundation
import Testing
@testable import MouthtypeCore

/// The local action counters behind the craft trophies: increment-only integers in isolated defaults.
@Suite struct AchievementCounterTests {
    private func isolatedDefaults() -> (UserDefaults, () -> Void) {
        let name = "mouthtype-achievement-counters-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    @Test func startsAtZeroAndOnlyGoesUp() {
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        let store = AchievementStore(defaults: defaults)
        for counter in AchievementStore.Counter.allCases { #expect(store.count(counter) == 0) }
        #expect(store.increment(.voiceEdits, day: "2026-11-02"))
        #expect(store.increment(.voiceEdits, day: "2026-11-02"))
        #expect(store.count(.voiceEdits) == 2)
        #expect(store.count(.transforms) == 0)
        // Nothing but integers is stored: no text key exists for the counters.
        #expect(defaults.object(forKey: AchievementStore.Counter.voiceEdits.key) is Int)
    }

    @Test func aNegativeValueReadsAsZero() {
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        defaults.set(-4, forKey: AchievementStore.Counter.transforms.key)
        #expect(AchievementStore(defaults: defaults).count(.transforms) == 0)
    }

    @Test func offMeansNothingCounts() {
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        let store = AchievementStore(defaults: defaults)
        store.setEnabled(false)
        #expect(!store.increment(.voiceEdits, day: "2026-11-02"))
        #expect(store.count(.voiceEdits) == 0)
        store.setEnabled(true)
        #expect(store.increment(.voiceEdits, day: "2026-11-02"))
    }

    @Test func keepsTheDayTheTrophyCountWasReached() {
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        let store = AchievementStore(defaults: defaults)
        store.increment(.voiceEdits, day: "2026-11-01")
        for _ in 2...24 { store.increment(.voiceEdits, day: "2026-11-02") }
        store.increment(.voiceEdits, day: "2026-11-03")
        store.increment(.voiceEdits, day: "2026-11-04")
        let counters = store.counters
        #expect(counters.voiceEdits == 26)
        #expect(counters.day(.voiceEdits, reaching: 1) == "2026-11-01")
        #expect(counters.day(.voiceEdits, reaching: 25) == "2026-11-03")
        #expect(counters.day(.voiceEdits, reaching: 2) == nil)
    }

    @Test func countersEarnTheTrophiesOnce() {
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        let store = AchievementStore(defaults: defaults)
        func earned() -> [String] {
            var extras = AchievementExtras()
            extras.counters = store.counters
            let report = StatsReport(
                wordsToday: 0, wordsThisWeek: 0, wordsAllTime: 0, dictationCount: 0, averageWPM: nil, bestWPM: nil,
                currentStreakDays: 0, longestStreakDays: 0, biggestDay: nil, longestDictation: nil, minutesSaved: 0,
                typingWPM: 40, firstDay: nil)
            let statuses = AchievementEngine.evaluate(AchievementInput(report: report, records: ArcadeRecords(), extras: extras))
            return store.apply(statuses, today: "2026-11-02")
        }
        _ = earned()  // the backfill pass, so what follows is a live earn
        #expect(earned().isEmpty)
        store.increment(.voiceEdits, day: "2026-11-02")
        #expect(earned() == ["second_draft"])
        #expect(store.earned["second_draft"] == "2026-11-02")
        #expect(!store.approximate.contains("second_draft"))
        #expect(earned().isEmpty)
        store.increment(.transforms, day: "2026-11-02")
        #expect(earned() == ["reworded"])
        for _ in 2...25 { store.increment(.voiceEdits, day: "2026-11-02") }
        #expect(earned() == ["editor"])
    }

    @Test func counterTrophiesAreNotBackfilledFromHistory() {
        let report = StatsReport(
            wordsToday: 0, wordsThisWeek: 0, wordsAllTime: 50_000, dictationCount: 900, averageWPM: nil, bestWPM: nil,
            currentStreakDays: 0, longestStreakDays: 30, biggestDay: nil, longestDictation: nil, minutesSaved: 0,
            typingWPM: 40, firstDay: "2026-01-01")
        let statuses = AchievementEngine.evaluate(AchievementInput(report: report, records: ArcadeRecords(), extras: AchievementExtras()))
        for id in ["second_draft", "editor", "reworded"] {
            #expect(!statuses.first { $0.id == id }!.isEarned, "\(id)")
        }
    }

    @Test func theCopyAdmitsTheyCountFromInstall() {
        var extras = AchievementExtras()
        extras.counters = AchievementCounters(voiceEdits: 3)
        let report = StatsReport(
            wordsToday: 0, wordsThisWeek: 0, wordsAllTime: 0, dictationCount: 0, averageWPM: nil, bestWPM: nil,
            currentStreakDays: 0, longestStreakDays: 0, biggestDay: nil, longestDictation: nil, minutesSaved: 0, typingWPM: 40,
            firstDay: nil)
        let statuses = AchievementEngine.evaluate(AchievementInput(report: report, records: ArcadeRecords(), extras: extras))
        if case .locked(let progress) = statuses.first(where: { $0.id == "editor" })!.state {
            #expect(progress.line == "3 of 25 voice edits, counted from install")
        } else {
            Issue.record("editor should be locked at 3")
        }
    }
}
