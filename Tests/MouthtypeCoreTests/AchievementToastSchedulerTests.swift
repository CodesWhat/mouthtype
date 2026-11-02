import Foundation
import Testing
@testable import MouthtypeCore

/// When a trophy toast may appear: window key, dictation idle, ten minutes between toasts, collapse, Reduce Motion and the sounds
/// toggle. Pure: an injected moment and no real clock or defaults.
@Suite struct AchievementToastSchedulerTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func earn(_ id: String, _ name: String, tier: AchievementTier = .bronze) -> AchievementToastEarn {
        AchievementToastEarn(id: id, name: name, copy: "\(name) copy.", tier: tier)
    }

    private func context(
        _ offset: TimeInterval = 0, key: Bool = true, busy: Bool = false, stats: Bool = false, reduceMotion: Bool = false,
        sounds: Bool = true
    ) -> AchievementToastContext {
        AchievementToastContext(
            now: t0.addingTimeInterval(offset), windowIsKey: key, dictationBusy: busy, statsOpen: stats, reduceMotion: reduceMotion,
            soundsEnabled: sounds)
    }

    @Test func showsOneEarnWhenKeyAndIdle() {
        var scheduler = AchievementToastScheduler()
        scheduler.enqueue([earn("four_figures", "Four Figures")])
        #expect(scheduler.hasQueued)
        let toast = scheduler.poll(context())
        #expect(toast?.title == "Four Figures")
        #expect(toast?.body == "Four Figures copy.")
        #expect(toast?.ids == ["four_figures"])
        #expect(toast?.spriteID == "four_figures")
        #expect(toast?.accessibilityLabel == "Trophy unlocked, Four Figures, bronze. Four Figures copy.")
        #expect(!scheduler.hasQueued)
        #expect(scheduler.poll(context(1)) == nil)
    }

    @Test func windowNotKeyQueuesSilentlyAndShowsWhenItBecomesKey() {
        var scheduler = AchievementToastScheduler()
        scheduler.enqueue([earn("a", "Alpha")])
        #expect(scheduler.readiness(context(key: false)) == .windowNotKey)
        #expect(scheduler.poll(context(key: false)) == nil)
        #expect(scheduler.hasQueued)
        #expect(scheduler.lastShown == nil)
        #expect(scheduler.poll(context(30))?.title == "Alpha")
    }

    @Test func nothingPresentsWhileDictationIsInFlight() {
        var scheduler = AchievementToastScheduler()
        scheduler.enqueue([earn("a", "Alpha")])
        #expect(scheduler.readiness(context(busy: true)) == .busy)
        #expect(scheduler.poll(context(busy: true)) == nil)
        #expect(scheduler.hasQueued)
        // Idle again: the queued earn surfaces.
        #expect(scheduler.poll(context(5, busy: false))?.title == "Alpha")
    }

    @Test func tenMinuteGapBetweenToasts() {
        var scheduler = AchievementToastScheduler()
        scheduler.enqueue([earn("a", "Alpha")])
        #expect(scheduler.poll(context()) != nil)
        scheduler.enqueue([earn("b", "Beta")])
        #expect(scheduler.readiness(context(599)) == .cooldown(until: t0.addingTimeInterval(600)))
        #expect(scheduler.poll(context(599)) == nil)
        #expect(scheduler.hasQueued)
        #expect(scheduler.poll(context(600))?.title == "Beta")
    }

    @Test func cooldownSurvivesARelaunchThroughLastShown() {
        var scheduler = AchievementToastScheduler(lastShown: t0)
        scheduler.enqueue([earn("a", "Alpha")])
        #expect(scheduler.poll(context(120)) == nil)
        #expect(scheduler.poll(context(601))?.title == "Alpha")
    }

    @Test func severalQueuedEarnsCollapseIntoOneToastNamingTheNewest() {
        var scheduler = AchievementToastScheduler()
        scheduler.enqueue([earn("a", "Alpha"), earn("b", "Beta"), earn("c", "Gamma", tier: .gold), earn("d", "Delta")])
        let toast = scheduler.poll(context())
        #expect(toast?.title == "Delta and 3 more")
        #expect(toast?.kicker == "Trophies unlocked")
        #expect(toast?.body == "Open Stats to see them all.")
        #expect(toast?.ids == ["a", "b", "c", "d"])
        #expect(toast?.accessibilityLabel == "Trophies unlocked, Delta and 3 more. Open Stats to see them all.")
        #expect(!scheduler.hasQueued)
        // Never an ellipsis.
        #expect(toast?.title.contains("\u{2026}") == false && toast?.title.contains("...") == false)
    }

    @Test func enqueueingTheSameTrophyTwiceHoldsItOnce() {
        var scheduler = AchievementToastScheduler()
        scheduler.enqueue([earn("a", "Alpha")])
        scheduler.enqueue([earn("a", "Alpha"), earn("b", "Beta")])
        #expect(scheduler.queue.count == 2)
    }

    @Test func reduceMotionAppearsInPlace() {
        var scheduler = AchievementToastScheduler()
        scheduler.enqueue([earn("a", "Alpha")])
        #expect(scheduler.poll(context(reduceMotion: true))?.slides == false)
        var other = AchievementToastScheduler()
        other.enqueue([earn("a", "Alpha")])
        #expect(other.poll(context(reduceMotion: false))?.slides == true)
    }

    @Test func soundOnlyWithTheToggleOn() {
        var on = AchievementToastScheduler()
        on.enqueue([earn("a", "Alpha")])
        #expect(on.poll(context(sounds: true))?.playsSound == true)
        var off = AchievementToastScheduler()
        off.enqueue([earn("a", "Alpha")])
        #expect(off.poll(context(sounds: false))?.playsSound == false)
    }

    @Test func droppingSeenEarnsEmptiesTheQueueAndTheDot() {
        var scheduler = AchievementToastScheduler()
        scheduler.enqueue([earn("a", "Alpha"), earn("b", "Beta")])
        scheduler.drop(ids: ["a", "b"])
        #expect(!scheduler.hasQueued)
        #expect(scheduler.poll(context()) == nil)
        #expect(scheduler.lastShown == nil)
    }

    @Test func backfillSummaryIsOneToastAndOnlyOnStats() {
        var scheduler = AchievementToastScheduler(backfillCount: 9)
        // No dot for the summary, and nothing off the Stats page.
        #expect(!scheduler.hasQueued)
        #expect(scheduler.poll(context(stats: false)) == nil)
        let toast = scheduler.poll(context(stats: true))
        #expect(toast?.kind == .backfill)
        #expect(toast?.title == "Found 9 trophies from your history.")
        #expect(toast?.spriteID == nil && toast?.tier == .gold)
        #expect(scheduler.backfillCount == 0)
        #expect(scheduler.poll(context(1, stats: true)) == nil)
    }

    @Test func backfillSummarySingular() {
        var scheduler = AchievementToastScheduler(backfillCount: 1)
        #expect(scheduler.poll(context(stats: true))?.title == "Found 1 trophy from your history.")
    }

    @Test func clearForgetsEverything() {
        var scheduler = AchievementToastScheduler(backfillCount: 3)
        scheduler.enqueue([earn("a", "Alpha")])
        scheduler.clear()
        #expect(scheduler.isEmpty)
        #expect(scheduler.poll(context(stats: true)) == nil)
    }

    @Test func storeKeepsToastBookkeepingInIsolatedDefaults() {
        let name = "mouthtype-toast-store-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AchievementStore(defaults: defaults)
        #expect(store.lastToast == nil && store.toasted.isEmpty && store.pendingBackfillSummary == 0)
        store.markToasted(["a"])
        store.markToasted(["b"])
        store.setLastToast(t0)
        #expect(store.toasted == ["a", "b"])
        #expect(store.lastToast == t0)
        let statuses = [AchievementStatus(id: "first_words", state: .earned(day: "2026-10-01"))]
        store.apply(statuses, today: "2026-11-02")
        #expect(store.pendingBackfillSummary == 1)
        store.clearBackfillSummary()
        #expect(store.pendingBackfillSummary == 0)
        // A later run is not a backfill and leaves no summary.
        store.apply(statuses + [AchievementStatus(id: "four_figures", state: .earned(day: "2026-11-02"))], today: "2026-11-02")
        #expect(store.pendingBackfillSummary == 0)
    }
}
