import AppKit
import SwiftUI
import Testing
import MouthtypeCore
@testable import MouthtypeMac

/// Offscreen renders of the trophy shelf on the Stats page. Set `MOUTHTYPE_SETTINGS_PREVIEWS` to a directory to keep the PNGs.
@MainActor @Suite(.serialized) struct AchievementShelfRenderTests {
    private func isolatedDefaults() -> (UserDefaults, () -> Void) {
        let name = "mouthtype-achievement-render-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    /// The Stats screenshot from the design doc: 11,296 words, 49 takes, a 10-day streak, 202 best WPM, a 640-word longest take.
    private var screenshotSnapshot: StatsSnapshot {
        var snapshot = StatsPagesRenderTests.snapshot
        snapshot.report.wordsAllTime = 11_296
        snapshot.report.dictationCount = 49
        snapshot.report.currentStreakDays = 10
        snapshot.report.longestStreakDays = 10
        snapshot.report.bestWPM = 202
        snapshot.report.averageWPM = 158
        snapshot.report.minutesSaved = 71
        snapshot.report.typingWPM = 40
        snapshot.report.firstDay = "2026-09-19"
        snapshot.report.longestDictation = LongestDictation(words: 640, durationMs: 190_000, day: "2026-10-12")
        snapshot.records = ArcadeRecords(
            wpm: Record(value: 202, setOn: "2026-10-12"), biggestDay: Record(value: 1_900, setOn: "2026-10-12"),
            longestStreak: Record(value: 10, setOn: "2026-10-04"),
            longestDictation: Record(value: LongestDictation(words: 640, durationMs: 190_000, day: "2026-10-12"), setOn: "2026-10-12"))
        return snapshot
    }

    /// Days for the dated backfill: 49 takes over the streak.
    private var screenshotExtras: AchievementExtras {
        let days = (0..<10).map { offset in
            AchievementExtras.Day(
                day: String(format: "2026-10-%02d", 1 + offset), takes: offset < 9 ? 5 : 4, words: 1_100 + offset * 40,
                timedWords: 1_100 + offset * 40, timedMs: (1_100 + offset * 40) * 380)
        }
        return AchievementExtras(days: days, distinctApps: 2)
    }

    private func model(extras: AchievementExtras, snapshot: StatsSnapshot, defaults: UserDefaults) async -> AchievementModel {
        let model = AchievementModel(defaults: defaults)
        await model.refresh(snapshot: snapshot, now: StatsPagesRenderTests.now, timeZone: StatsPagesRenderTests.zone) { _ in extras }
        return model
    }

    private func render(_ snapshot: StatsSnapshot, model: AchievementModel, dark: Bool, width: CGFloat = 800, height: CGFloat = 2_700, name: String?) throws {
        FontRegistry.registerBundledFonts()
        let page = DesignPage(title: SettingsPage.stats.headline, summary: SettingsPage.stats.summary) {
            StatsPage(snapshot: snapshot, now: StatsPagesRenderTests.now, timeZone: StatsPagesRenderTests.zone, achievements: model)
        }
        let bitmap = try SettingsRender.render(page, dark: dark, size: NSSize(width: width, height: height))
        #expect(bitmap.pixelsWide >= Int(width))
        if let name { try SettingsRender.save(bitmap, name: name) }
    }

    @Test func screenshotFixtureEarnsExactlyTheExpectedSetAndRenders() async throws {
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        let snapshot = screenshotSnapshot
        let model = await model(extras: screenshotExtras, snapshot: snapshot, defaults: defaults)
        let earned = Set(model.entries.filter { if case .earned = $0.state { true } else { false } }.map(\.id))
        #expect(
            earned == [
                "first_words", "four_figures", "five_figures", "monologue", "three_row", "no_days_off", "fast_talker", "auctioneer",
                "triple_speed", "hour_back",
            ])
        // A correct progress line on the locked ones.
        func line(_ id: String) -> String? {
            if case .locked(let progress) = model.entries.first(where: { $0.id == id })?.state { return progress.line }
            return nil
        }
        #expect(line("thousand_takes") == "49 of 1,000 takes")
        #expect(line("month") == "10 of 30 days")
        #expect(line("six_figures") == "11,296 of 100,000 words")
        #expect(line("workday_back") == "1 h 11 min of 8 h saved")
        #expect(line("many_apps") == "2 of 3 apps")
        #expect(model.entries.filter { $0.group == .hidden }.allSatisfy { $0.state == .hidden })
        try render(snapshot, model: model, dark: false, name: "shelf-light")
        try render(snapshot, model: model, dark: true, name: "shelf-dark")
        try render(snapshot, model: model, dark: false, width: 520, height: 3_900, name: "shelf-narrow-light")
    }

    @Test func richFixtureShowsHiddenEarnsAndBeforeTrophiesDates() async throws {
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        var extras = screenshotExtras
        extras.calibrated = true
        extras.nightOwlDay = "2026-10-09"
        extras.handsFreeCount = 3
        extras.handsFreeFirstDay = "2026-09-24"
        extras.distinctApps = 5
        extras.thirdAppDay = "2026-09-30"
        extras.longestDurationMs = 301_000
        extras.longestDurationDay = "2026-10-12"
        let snapshot = screenshotSnapshot
        let model = await model(extras: extras, snapshot: snapshot, defaults: defaults)
        #expect(model.entries.first { $0.id == "honest_baseline" }?.isApproximate == true)
        #expect(model.entries.first { $0.id == "night_owl" }?.state == .earned(day: "2026-10-09"))
        try render(snapshot, model: model, dark: false, name: "shelf-rich-light")
        try render(snapshot, model: model, dark: true, name: "shelf-rich-dark")
    }

    @Test func hiddenShelfDrawsOneLineAndSwitchedOffDrawsNothing() async throws {
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        let snapshot = screenshotSnapshot
        let model = await model(extras: screenshotExtras, snapshot: snapshot, defaults: defaults)
        model.setShelfHidden(true)
        try render(snapshot, model: model, dark: false, height: 1_300, name: "shelf-hidden-light")
        model.setEnabled(false)
        try render(snapshot, model: model, dark: false, height: 1_300, name: nil)
        #expect(model.entries.isEmpty)
    }

    @Test func emptyStateShowsThreeLockedTiles() async throws {
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        var empty = StatsSnapshot.make(samples: [], now: StatsPagesRenderTests.now, timeZone: StatsPagesRenderTests.zone)
        empty.daily = []
        let model = await model(extras: AchievementExtras(), snapshot: empty, defaults: defaults)
        #expect(model.earnedCount == 0 && !model.entries.isEmpty)
        FontRegistry.registerBundledFonts()
        for dark in [false, true] {
            let card = AchievementShelfCard(model: model, today: "2026-10-18", isEmptyState: true).padding(20)
            let bitmap = try SettingsRender.render(card, dark: dark, size: NSSize(width: 800, height: 300))
            try SettingsRender.save(bitmap, name: dark ? "shelf-empty-dark" : "shelf-empty-light")
        }
    }
}
