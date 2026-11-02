import Foundation
import Testing
@testable import MouthtypeCore

/// The slice 1 achievements on fixtures: every threshold at n-1, n and n+1, tiers, hidden entries, dates for a backfill, and the
/// store's idempotence. Pure: no real defaults and no real library.
@Suite struct AchievementEngineTests {
    struct Fixture {
        var words = 0
        var takes = 0
        var longestWords = 0
        var longestStreak = 0
        var bestWPM: Double?
        var averageWPM: Double?
        var typingWPM = 40.0
        var saved = 0.0
        var extras = AchievementExtras()

        var input: AchievementInput {
            let report = StatsReport(
                wordsToday: 0, wordsThisWeek: 0, wordsAllTime: words, dictationCount: takes, averageWPM: averageWPM, bestWPM: bestWPM,
                currentStreakDays: 0, longestStreakDays: longestStreak, biggestDay: nil,
                longestDictation: longestWords > 0 ? LongestDictation(words: longestWords, durationMs: nil, day: "2026-10-12") : nil,
                minutesSaved: saved, typingWPM: typingWPM, firstDay: takes > 0 ? "2026-09-19" : nil)
            return AchievementInput(report: report, records: ArcadeRecords(), extras: extras)
        }

        func status(_ id: String) -> AchievementStatus {
            AchievementEngine.evaluate(input).first { $0.id == id }!
        }
    }

    private func isolatedDefaults() -> (UserDefaults, () -> Void) {
        let name = "mouthtype-achievement-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    // MARK: Thresholds

    private static let edges: [(id: String, n: Int, set: @Sendable (inout Fixture, Int) -> Void)] = [
        ("first_words", 1, { $0.takes = $1 }),
        ("hands_free", 1, { $0.extras.handsFreeCount = $1 }),
        ("many_apps", 3, { $0.extras.distinctApps = $1 }),
        ("four_figures", 1_000, { $0.words = $1 }),
        ("five_figures", 10_000, { $0.words = $1 }),
        ("six_figures", 100_000, { $0.words = $1 }),
        ("hundred_takes", 100, { $0.takes = $1 }),
        ("thousand_takes", 1_000, { $0.takes = $1 }),
        ("monologue", 300, { $0.longestWords = $1 }),
        ("three_row", 3, { $0.longestStreak = $1 }),
        ("no_days_off", 7, { $0.longestStreak = $1 }),
        ("month", 30, { $0.longestStreak = $1 }),
        ("century", 100, { $0.longestStreak = $1 }),
        ("fast_talker", 150, { $0.bestWPM = Double($1) }),
        ("auctioneer", 200, { $0.bestWPM = Double($1) }),
        ("triple_speed", 120, { $0.averageWPM = Double($1) }),
        ("hour_back", 60, { $0.saved = Double($1) }),
        ("workday_back", 480, { $0.saved = Double($1) }),
        ("proper_noun", 1, { $0.extras.rememberedCount = $1 }),
        ("second_draft", 1, { $0.extras.counters.voiceEdits = $1 }),
        ("editor", 25, { $0.extras.counters.voiceEdits = $1 }),
        ("reworded", 1, { $0.extras.counters.transforms = $1 }),
        ("tongue_out", 1, { $0.extras.counters.mouthTricks = $1 }),
        ("read_credits", 1, { $0.extras.counters.creditsViews = $1 }),
        ("shortcut", 10, { $0.extras.snippetCount = $1 }),
        ("filibuster", 300_000, { $0.extras.longestDurationMs = $1 }),
    ]

    @Test func everyThresholdHoldsAtNMinusOneNAndNPlusOne() {
        for (id, n, set) in Self.edges {
            for (delta, earned) in [(-1, false), (0, true), (1, true)] {
                var fixture = Fixture()
                set(&fixture, n + delta)
                #expect(fixture.status(id).isEarned == earned, "\(id) at \(n + delta)")
            }
        }
    }

    @Test func tripleSpeedIsARatioToTheTypingBaseline() {
        var fixture = Fixture()
        fixture.averageWPM = 119.9
        #expect(!fixture.status("triple_speed").isEarned)
        fixture.averageWPM = 120
        #expect(fixture.status("triple_speed").isEarned)
        // A calibrated 60 WPM typist needs 180.
        fixture.typingWPM = 60
        #expect(!fixture.status("triple_speed").isEarned)
        fixture.averageWPM = 180
        #expect(fixture.status("triple_speed").isEarned)
        fixture.averageWPM = nil
        #expect(!fixture.status("triple_speed").isEarned)
    }

    @Test func flagsAndHiddenDaysEarnOnlyWhenSet() {
        var fixture = Fixture()
        #expect(!fixture.status("honest_baseline").isEarned && fixture.status("night_owl").state == .hidden)
        fixture.extras.calibrated = true
        fixture.extras.nightOwlDay = "2026-10-09"
        #expect(fixture.status("honest_baseline").isEarned)
        #expect(fixture.status("night_owl").state == .earned(day: "2026-10-09"))
    }

    @Test func tiersMatchTheDesign() {
        let tiers = Dictionary(uniqueKeysWithValues: AchievementCatalog.all.map { ($0.id, $0.tier) })
        let gold: Set = ["six_figures", "month", "century", "workday_back"]
        let silver: Set = ["five_figures", "thousand_takes", "monologue", "no_days_off", "auctioneer", "triple_speed", "shortcut", "filibuster", "editor"]
        for (id, tier) in tiers {
            #expect(tier == (gold.contains(id) ? .gold : silver.contains(id) ? .silver : .bronze), "\(id)")
        }
        #expect(AchievementCatalog.all.count == 29)
        #expect(Set(AchievementCatalog.all.map(\.id)).count == 29)
    }

    @Test func hiddenOnesSayNothingUntilEarned() {
        let fixture = Fixture()
        for definition in AchievementCatalog.all where definition.isHidden {
            #expect(fixture.status(definition.id).state == .hidden)
        }
        #expect(Set(AchievementCatalog.all.filter(\.isHidden).map(\.id)) == ["night_owl", "filibuster", "welcome_back", "tongue_out", "read_credits"])
        var earned = Fixture()
        earned.extras.longestDurationMs = 300_000
        earned.extras.days = [.init(day: "2026-08-01", takes: 1, words: 5), .init(day: "2026-09-01", takes: 1, words: 5)]
        #expect(earned.status("filibuster").isEarned)
        #expect(earned.status("welcome_back").state == .earned(day: "2026-09-01"))
    }

    @Test func lockedLinesAreThePlainProgress() {
        var fixture = Fixture()
        fixture.words = 7_420
        fixture.takes = 49
        fixture.longestStreak = 10
        fixture.saved = 71
        fixture.extras.distinctApps = 2
        fixture.extras.snippetCount = 3
        func line(_ id: String) -> String? {
            if case .locked(let progress) = fixture.status(id).state { return progress.line }
            return nil
        }
        #expect(line("five_figures") == "7,420 of 10,000 words")
        #expect(line("thousand_takes") == "49 of 1,000 takes")
        #expect(line("month") == "10 of 30 days")
        #expect(line("workday_back") == "1 h 11 min of 8 h saved")
        #expect(line("many_apps") == "2 of 3 apps")
        #expect(line("shortcut") == "3 of 10 snippets")
        #expect(line("proper_noun") == "No spellings saved yet")
        fixture.averageWPM = 84
        #expect(line("triple_speed") == "Average speed is 2.1x your typing")
    }

    /// The Stats screenshot: 11,296 words, 49 takes, a 10-day streak, 202 best WPM, a 640-word longest take.
    @Test func theScreenshotFixtureEarnsExactlyTheExpectedSet() {
        var fixture = Fixture()
        fixture.words = 11_296
        fixture.takes = 49
        fixture.longestStreak = 10
        fixture.bestWPM = 202
        fixture.averageWPM = 158
        fixture.longestWords = 640
        fixture.saved = 71
        fixture.extras.distinctApps = 2
        let earned = Set(AchievementEngine.evaluate(fixture.input).filter(\.isEarned).map(\.id))
        #expect(
            earned == [
                "first_words", "four_figures", "five_figures", "monologue", "three_row", "no_days_off", "fast_talker", "auctioneer",
                "triple_speed", "hour_back",
            ])
        if case .locked(let progress) = fixture.status("six_figures").state { #expect(progress.line == "11,296 of 100,000 words") }
    }

    // MARK: Dates for a backfill

    private func days(_ list: [(String, Int)]) -> [AchievementExtras.Day] {
        list.map { .init(day: $0.0, takes: 1, words: $0.1) }
    }

    @Test func cumulativeDatesAreTheDayTheTotalCrossed() {
        let list = days([("2026-10-01", 600), ("2026-10-02", 399), ("2026-10-03", 1), ("2026-10-04", 5)])
        #expect(AchievementCatalog.crossingDay(list, target: 1_000) { $0.words } == "2026-10-03")
        #expect(AchievementCatalog.crossingDay(list, target: 1_001) { $0.words } == "2026-10-04")
        #expect(AchievementCatalog.crossingDay(list, target: 2_000) { $0.words } == nil)
        #expect(AchievementCatalog.crossingDay(list, target: 3) { $0.takes } == "2026-10-03")
    }

    @Test func streakDatesSurviveABrokenStreakAndMonthEdges() {
        let list = days([("2026-10-28", 5), ("2026-10-29", 5), ("2026-10-30", 5), ("2026-11-02", 5), ("2026-11-03", 5), ("2026-11-04", 5), ("2026-11-05", 5)])
        #expect(AchievementCatalog.streakDay(list, length: 3) == "2026-10-30")
        #expect(AchievementCatalog.streakDay(list, length: 4) == "2026-11-05")
        #expect(AchievementCatalog.streakDay(list, length: 5) == nil)
        let leap = days([("2028-02-28", 1), ("2028-02-29", 1), ("2028-03-01", 1)])
        #expect(AchievementCatalog.streakDay(leap, length: 3) == "2028-03-01")
    }

    @Test func welcomeBackNeedsThirtyEmptyDays() {
        // 2026-09-01 to 2026-10-01 leaves 29 empty days; to 2026-10-02 leaves 30.
        #expect(AchievementCatalog.returnDay(days([("2026-09-01", 5), ("2026-10-01", 5)]), gapDays: 30) == nil)
        #expect(AchievementCatalog.returnDay(days([("2026-09-01", 5), ("2026-10-02", 5)]), gapDays: 30) == "2026-10-02")
        #expect(AchievementCatalog.returnDay(days([("2026-09-01", 5)]), gapDays: 30) == nil)
    }

    @Test func timeSavedDateFollowsTheRunningTotal() {
        // 80 timed words at 40 WPM is 2 minutes of typing, against 1 minute of talking: 1 minute saved a day.
        let list = (1...3).map { AchievementExtras.Day(day: "2026-10-0\($0)", takes: 1, words: 80, timedWords: 80, timedMs: 60_000) }
        #expect(AchievementCatalog.savedDay(list, typingWPM: 40, minutes: 3) == "2026-10-03")
        #expect(AchievementCatalog.savedDay(list, typingWPM: 40, minutes: 4) == nil)
        #expect(AchievementCatalog.savedDay(list, typingWPM: 0, minutes: 1) == nil)
    }

    @Test func earnedStatusesCarryTheirRealDay() {
        var fixture = Fixture()
        fixture.words = 1_500
        fixture.takes = 3
        fixture.longestStreak = 3
        fixture.extras.days = [.init(day: "2026-09-19", takes: 1, words: 600), .init(day: "2026-09-20", takes: 1, words: 500), .init(day: "2026-09-21", takes: 1, words: 400)]
        #expect(fixture.status("first_words").state == .earned(day: "2026-09-19"))
        #expect(fixture.status("four_figures").state == .earned(day: "2026-09-20"))
        #expect(fixture.status("three_row").state == .earned(day: "2026-09-21"))
    }

    // MARK: Store

    @Test func backfillMarksEverythingSeenWithRealDates() {
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        let store = AchievementStore(defaults: defaults)
        let statuses = [
            AchievementStatus(id: "first_words", state: .earned(day: "2026-09-19")),
            AchievementStatus(id: "honest_baseline", state: .earned(day: nil)),
            AchievementStatus(id: "month", state: .locked(AchievementProgress(current: 3, target: 30, line: "3 of 30 days"))),
        ]
        let added = store.apply(statuses, today: "2026-11-02")
        #expect(Set(added) == ["first_words", "honest_baseline"])
        #expect(store.earned == ["first_words": "2026-09-19", "honest_baseline": "2026-11-02"])
        #expect(store.approximate == ["honest_baseline"])
        #expect(store.seen == ["first_words", "honest_baseline"])
        #expect(store.isBackfilled)
        let shelf = AchievementEngine.shelf(statuses, store: store)
        #expect(shelf.filter(\.isNew).isEmpty)
        #expect(shelf.first { $0.id == "honest_baseline" }?.isApproximate == true)
    }

    @Test func runningTwiceEarnsNothingNew() {
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        let store = AchievementStore(defaults: defaults)
        let statuses = [AchievementStatus(id: "first_words", state: .earned(day: "2026-09-19"))]
        #expect(store.apply(statuses, today: "2026-11-02") == ["first_words"])
        #expect(store.apply(statuses, today: "2026-11-03").isEmpty)
        #expect(store.earned == ["first_words": "2026-09-19"])
    }

    @Test func earnsAfterTheBackfillAreNewUntilTheShelfIsSeen() {
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        let store = AchievementStore(defaults: defaults)
        store.apply([], today: "2026-11-02")
        #expect(store.isBackfilled)
        let statuses = [AchievementStatus(id: "four_figures", state: .earned(day: "2026-11-05"))]
        #expect(store.apply(statuses, today: "2026-11-05") == ["four_figures"])
        #expect(AchievementEngine.shelf(statuses, store: store).first { $0.id == "four_figures" }?.isNew == true)
        store.markAllSeen()
        #expect(AchievementEngine.shelf(statuses, store: store).first { $0.id == "four_figures" }?.isNew == false)
    }

    @Test func nothingIsRevokedWhenHistoryGoesAway() {
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        let store = AchievementStore(defaults: defaults)
        var fixture = Fixture()
        fixture.words = 1_200
        fixture.takes = 4
        fixture.extras.days = [.init(day: "2026-10-01", takes: 4, words: 1_200)]
        store.apply(AchievementEngine.evaluate(fixture.input), today: "2026-10-02")
        // History cleared.
        let empty = AchievementEngine.evaluate(Fixture().input)
        #expect(store.apply(empty, today: "2026-12-01").isEmpty)
        let shelf = AchievementEngine.shelf(empty, store: store)
        #expect(shelf.first { $0.id == "four_figures" }?.state == .earned(day: "2026-10-01"))
        #expect(shelf.first { $0.id == "first_words" }?.state == .earned(day: "2026-09-19"))
    }

    @Test func theSwitchAndTheHiddenShelfPersistAndDefaultOn() {
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        let store = AchievementStore(defaults: defaults)
        #expect(store.isEnabled && !store.isShelfHidden)
        store.setEnabled(false)
        store.setShelfHidden(true)
        #expect(!AchievementStore(defaults: defaults).isEnabled && AchievementStore(defaults: defaults).isShelfHidden)
    }
}
