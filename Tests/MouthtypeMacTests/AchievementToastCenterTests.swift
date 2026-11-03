import Foundation
import Observation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor private final class Box {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var busy = false
    var editing = false
    var calibrating = false
    var reduceMotion = false
    var cues = 0
    var announcements: [String] = []
}

/// The toast on top of the scheduler: one toast at a time for six seconds, hover or focus pauses it, one cue and one VoiceOver
/// announcement, and nothing at all while Achievements is off. Timers are off and the clock is injected.
@MainActor @Suite struct AchievementToastCenterTests {
    private func isolated() -> (UserDefaults, () -> Void) {
        let name = "mouthtype-toast-center-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    private func entry(_ id: String, isNew: Bool = true, day: String = "2026-11-02") -> AchievementShelfEntry {
        let definition = AchievementCatalog.definition(id: id)!
        return AchievementShelfEntry(
            id: id, group: definition.group, tier: definition.tier, name: definition.name, copy: definition.copy,
            state: .earned(day: day), isApproximate: false, isNew: isNew)
    }

    private func center(_ box: Box, _ defaults: UserDefaults) -> AchievementToastCenter {
        let center = AchievementToastCenter(store: AchievementStore(defaults: defaults), clock: { box.now }, autoSchedule: false)
        center.isDictationBusy = { box.busy }
        center.isEditingSelection = { box.editing }
        center.isCalibrating = { box.calibrating }
        center.reduceMotion = { box.reduceMotion }
        center.playCue = { box.cues += 1 }
        center.announce = { box.announcements.append($0) }
        return center
    }

    @Test func showsWhenKeyAndIdleWithOneCueAndOneAnnouncement() {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }
        let box = Box()
        let center = center(box, defaults)
        center.windowIsKey = true
        center.ingest([entry("four_figures")])
        #expect(center.current?.title == "Four Figures")
        #expect(box.cues == 1)
        #expect(box.announcements == ["Trophy unlocked, Four Figures, bronze. 1,000 words and your keyboard didn't feel a thing."])
        // Polling again changes nothing: still one toast, one cue, one announcement.
        center.poll()
        #expect(box.cues == 1 && box.announcements.count == 1)
    }

    @Test func windowNotKeyQueuesWithADotThenShowsOnKey() {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }
        let box = Box()
        let center = center(box, defaults)
        center.ingest([entry("four_figures")])
        #expect(center.current == nil && center.hasQueued)
        #expect(box.cues == 0 && box.announcements.isEmpty)
        center.windowIsKey = true
        #expect(center.current?.title == "Four Figures")
        #expect(!center.hasQueued)
    }

    @Test func recordingHoldsItBackWithNoCue() {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }
        let box = Box()
        let center = center(box, defaults)
        center.windowIsKey = true
        box.busy = true
        center.ingest([entry("four_figures")])
        #expect(center.current == nil && center.hasQueued && box.cues == 0)
        box.busy = false
        center.poll()
        #expect(center.current != nil && box.cues == 1)
    }

    @Test func voiceEditAndCalibrationHoldItBackWithNoCue() {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }
        let box = Box()
        let center = center(box, defaults)
        center.windowIsKey = true
        box.editing = true
        center.ingest([entry("four_figures")])
        #expect(center.current == nil && center.hasQueued && box.cues == 0)
        box.editing = false
        box.calibrating = true
        center.poll()
        #expect(center.current == nil && box.cues == 0)
        box.calibrating = false
        center.poll()
        #expect(center.current != nil && box.cues == 1)
    }

    @Test func tenMinuteGapAndCollapseAcrossToasts() {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }
        let box = Box()
        let center = center(box, defaults)
        center.windowIsKey = true
        center.ingest([entry("first_words")])
        #expect(center.current?.title == "First Words")
        center.dismiss()
        box.now.addTimeInterval(60)
        center.ingest([entry("first_words"), entry("hands_free"), entry("many_apps"), entry("four_figures")])
        // First Words was already announced; three others wait out the gap.
        #expect(center.current == nil && center.hasQueued)
        box.now.addTimeInterval(600)
        center.poll()
        #expect(center.current?.title.hasSuffix("and 2 more") == true)
    }

    @Test func hoverPausesAndResumeKeepsTheRemainingTime() {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }
        let box = Box()
        let center = center(box, defaults)
        center.windowIsKey = true
        center.ingest([entry("four_figures")])
        #expect(center.fractionLeft(at: box.now) == 1)
        box.now.addTimeInterval(2)
        center.setPaused(true)
        #expect(center.isPaused)
        box.now.addTimeInterval(60)
        // Held: the bar does not move however long the pointer stays.
        #expect(abs(center.fractionLeft(at: box.now) - 4.0 / 6.0) < 0.001)
        center.setPaused(false)
        #expect(center.deadline == box.now.addingTimeInterval(4))
        center.lifeEnded()
        #expect(center.current == nil)
    }

    @Test func keyboardDismissAndOpenBothClose() {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }
        let box = Box()
        let center = center(box, defaults)
        var opened = 0
        center.openShelf = { opened += 1 }
        center.windowIsKey = true
        center.ingest([entry("four_figures")])
        center.dismiss()
        #expect(center.current == nil && opened == 0)
        box.now.addTimeInterval(700)
        center.ingest([entry("hands_free")])
        center.open()
        #expect(center.current == nil && opened == 1)
    }

    @Test func reduceMotionAppearsInPlaceAndSoundsOffStaysSilent() {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }
        SoundPreference.set(false, in: defaults)
        let box = Box()
        box.reduceMotion = true
        let center = center(box, defaults)
        center.windowIsKey = true
        center.ingest([entry("four_figures")])
        #expect(center.current?.slides == false)
        #expect(box.cues == 0)
        #expect(box.announcements.count == 1)
    }

    @Test func aRelaunchDoesNotAnnounceTheSameTrophyTwice() {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }
        let box = Box()
        let first = center(box, defaults)
        first.windowIsKey = true
        first.ingest([entry("four_figures")])
        #expect(first.current != nil)
        let second = center(box, defaults)
        second.windowIsKey = true
        box.now.addTimeInterval(3_600)
        second.ingest([entry("four_figures")])
        #expect(second.current == nil && !second.hasQueued)
    }

    @Test func backfillSummaryShowsOnceOnStatsAndNeverDots() {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }
        AchievementStore(defaults: defaults).apply(
            [AchievementStatus(id: "first_words", state: .earned(day: "2026-10-01"))], today: "2026-11-02")
        let box = Box()
        let center = center(box, defaults)
        center.windowIsKey = true
        center.ingest([entry("first_words", isNew: false)])
        #expect(center.current == nil && !center.hasQueued)
        center.statsOpen = true
        #expect(center.current?.title == "Found 1 trophy from your history.")
        center.dismiss()
        let again = self.center(box, defaults)
        again.windowIsKey = true
        again.statsOpen = true
        box.now.addTimeInterval(3_600)
        again.ingest([entry("first_words", isNew: false)])
        #expect(again.current == nil)
    }

    @Test func shelfSeenAndResetClearTheQueue() {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }
        let box = Box()
        let center = center(box, defaults)
        center.ingest([entry("four_figures"), entry("hands_free")])
        #expect(center.hasQueued)
        center.shelfSeen(["four_figures", "hands_free"])
        #expect(!center.hasQueued)
        center.ingest([entry("many_apps")])
        center.reset()
        center.windowIsKey = true
        #expect(center.current == nil && !center.hasQueued)
    }

    @Test func calibrationHoldsTheGateWithoutPollingAndWakesWhenItEnds() async {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }
        let phase = CalibrationFlag()
        phase.active = true
        let box = Box()
        let center = center(box, defaults)
        center.isCalibrating = { phase.active }
        center.observeCalibration()
        center.windowIsKey = true
        center.ingest([entry("four_figures")])
        #expect(center.current == nil && center.hasQueued)
        // Held by calibration alone: no retry timer is asked for.
        #expect(center.lastWake == nil)
        phase.active = false
        for _ in 0..<20 where center.current == nil { await Task.yield() }
        #expect(center.current != nil && box.cues == 1)
    }

    @Test func dictationBusyStillRetriesOnATimer() {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }
        let box = Box()
        let center = center(box, defaults)
        center.windowIsKey = true
        box.busy = true
        center.ingest([entry("four_figures")])
        #expect(center.current == nil && center.lastWake == 2)
    }
}

@MainActor @Observable private final class CalibrationFlag {
    var active = false
}
