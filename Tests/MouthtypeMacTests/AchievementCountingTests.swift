import AppKit
import Foundation
import MouthtypeCore
import Testing
@testable import MouthtypeMac

/// The counters and the two eggs, with fakes and isolated defaults: a count lands only for a completed Accept, a trick only plays
/// while the icon is idle and any state change cancels it, and the credits come from the real notices file.

@MainActor private func isolated() -> (UserDefaults, () -> Void) {
    let name = "mouthtype-counting-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    return (defaults, { defaults.removePersistentDomain(forName: name) })
}

@MainActor private final class CountingEditor: SelectionEditing {
    var selected = SelectedText(pid: 7, element: nil, range: NSRange(location: 0, length: 15), text: "me and him goes")
    var current: SelectedText?
    var accepts = true
    var replaced: [String] = []
    func capture() throws -> SelectedText { current ?? selected }
    func replace(_ original: SelectedText, with replacement: String) -> Bool {
        guard accepts, original == (current ?? selected) else { return false }
        replaced.append(replacement)
        return true
    }
}

@MainActor private final class CountingTransformer: SelectionTransforming {
    var transformUnavailableReason: String? { nil }
    func transform(_ transform: TextTransform, text: String) async throws -> String { "He and I go." }
}

@MainActor @Suite struct AchievementCountingTests {
    @Test func recordCountsOncePostsAndStaysLocal() {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }
        var posts = 0
        let counting = AchievementCounting(
            defaults: defaults, now: { Date(timeIntervalSince1970: 1_793_000_000) }, timeZone: { TimeZone(identifier: "UTC")! },
            post: { posts += 1 })
        #expect(counting.record(.voiceEdits))
        #expect(counting.store.count(.voiceEdits) == 1 && posts == 1)
        #expect(counting.store.counterDays["voiceEdits:1"] == "2026-10-26")
        #expect(defaults.object(forKey: AchievementStore.Counter.voiceEdits.key) is Int)
    }

    @Test func offCountsNothingAndPostsNothing() {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }
        AchievementStore(defaults: defaults).setEnabled(false)
        var posts = 0
        let counting = AchievementCounting(defaults: defaults, post: { posts += 1 })
        #expect(!counting.record(.mouthTricks))
        #expect(counting.store.count(.mouthTricks) == 0 && posts == 0)
    }

    @Test func aTransformThePanelAcceptsCountsOnce() async {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }
        let counting = AchievementCounting(defaults: defaults, post: {})
        let editor = CountingEditor()
        let box = ModelBox()
        let model = SelectionCleanupModel(
            editor: counting.counting(editor, as: .transforms) { box.model?.transform != nil }, transformer: CountingTransformer())
        box.model = model
        await model.prepare(transform: .fixGrammar)
        for _ in 0..<200 where model.isTransforming { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(counting.store.count(.transforms) == 0)  // a preview alone is not a count
        model.accept()
        model.accept()
        #expect(editor.replaced.count == 1 && counting.store.count(.transforms) == 1)
        #expect(counting.store.count(.voiceEdits) == 0)
    }

    @Test func basicCleanupRefusalAndCancelNeverCount() async {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }
        let counting = AchievementCounting(defaults: defaults, post: {})
        let editor = CountingEditor()
        let box = ModelBox()
        let model = SelectionCleanupModel(
            editor: counting.counting(editor, as: .transforms) { box.model?.transform != nil }, transformer: CountingTransformer())
        box.model = model
        // Basic cleanup is not a rewrite.
        await model.prepare()
        model.accept()
        #expect(editor.replaced.count == 1 && counting.store.count(.transforms) == 0)

        // The app refuses the write.
        editor.accepts = false
        await model.prepare(transform: .shorter)
        for _ in 0..<200 where model.isTransforming { try? await Task.sleep(for: .milliseconds(5)) }
        model.accept()
        #expect(model.refused && counting.store.count(.transforms) == 0)

        // Cancel before Accept.
        editor.accepts = true
        model.cancel()
        await model.prepare(transform: .shorter)
        for _ in 0..<200 where model.isTransforming { try? await Task.sleep(for: .milliseconds(5)) }
        model.cancel()
        #expect(counting.store.count(.transforms) == 0)
    }

    @MainActor private final class ModelBox {
        var model: SelectionCleanupModel?
    }

    @Test func theReportingEditorPassesReadsThroughAndReportsOnlyTakenWrites() throws {
        let editor = CountingEditor()
        var reports = 0
        let wrapped = ReplacementReportingEditor(base: editor) { reports += 1 }
        #expect(try wrapped.capture() == editor.selected)
        #expect(wrapped.replace(editor.selected, with: "x") && reports == 1)
        editor.accepts = false
        #expect(!wrapped.replace(editor.selected, with: "y") && reports == 1)
    }
}

// MARK: Mouth trick

/// Steps a fake clock by hand: `schedule` records the pending closure, `fire()` runs it.
@MainActor private final class ManualClock {
    private(set) var pending: [(seconds: TimeInterval, run: @MainActor () -> Void)] = []
    private(set) var cancels = 0
    func schedule(_ seconds: TimeInterval, _ run: @escaping @MainActor () -> Void) -> () -> Void {
        pending.append((seconds, run))
        let index = pending.count - 1
        return { [self] in
            cancels += 1
            if pending.indices.contains(index) { pending[index].run = {} }
        }
    }
    func fire() {
        guard let last = pending.last else { return }
        last.run()
    }
}

@MainActor private final class TrickRig {
    let clock = ManualClock()
    var shown: [String] = []
    var restores = 0
    var reduceMotion = false
    var trick = MouthTrick.tongue
    lazy var player = MouthTrickPlayer(
        pick: { [unowned self] in trick }, schedule: { [unowned self] in clock.schedule($0, $1) },
        show: { [unowned self] in shown.append($0) }, restore: { [unowned self] in restores += 1 },
        reduceMotion: { [unowned self] in reduceMotion })
}

@MainActor @Suite struct MouthTrickTests {
    @Test func everyFrameExistsAndEachTrickRunsAboutAsLongAsThePlan() {
        for trick in MouthTrick.allCases {
            let total = trick.steps.map(\.seconds).reduce(0, +)
            #expect(total >= 1.2 && total <= 1.5, "\(trick) \(total)")
        }
        for file in MouthTrick.glyphFiles {
            #expect(StatusIcon.loadImage(named: file) != nil, "\(file)")
        }
        #expect(StatusIcon.loadImage(named: "trick-tongue0")?.isTemplate == true)
    }

    @Test func playsEveryStepThenRestoresTheTrueGlyph() {
        let rig = TrickRig()
        #expect(rig.player.start(icon: .idle))
        #expect(rig.player.isPlaying && rig.restores == 0)
        let expected = MouthTrick.tongue.steps
        for index in expected.indices {
            #expect(rig.shown.count == index + 1 && rig.shown.last == expected[index].file)
            #expect(rig.clock.pending.last?.seconds == expected[index].seconds)
            rig.clock.fire()
        }
        #expect(!rig.player.isPlaying && rig.restores == 1)
        #expect(rig.shown == expected.map(\.file))
    }

    @Test(arguments: [StatusIcon.recording, .processing, .unavailable])
    func neverStartsOutsideIdle(icon: StatusIcon) {
        let rig = TrickRig()
        #expect(!rig.player.start(icon: icon))
        #expect(rig.shown.isEmpty && rig.clock.pending.isEmpty && !rig.player.isPlaying && rig.restores == 0)
    }

    @Test func aStateChangeCancelsAtOnceAndAStaleTimerDoesNothing() {
        let rig = TrickRig()
        #expect(rig.player.start(icon: .idle))
        rig.clock.fire()  // second frame on screen
        let before = rig.shown.count
        let stale = rig.clock.pending.last!.run
        rig.player.cancel()
        #expect(!rig.player.isPlaying && rig.restores == 1 && rig.clock.cancels >= 1)
        stale()  // a timer that fires after the cancel
        #expect(rig.shown.count == before && rig.restores == 1)
        rig.player.cancel()  // cancelling again is harmless
        #expect(rig.restores == 1)
    }

    @Test func aSecondOpenDuringATrickDoesNotStackAnother() {
        let rig = TrickRig()
        #expect(rig.player.start(icon: .idle))
        #expect(!rig.player.start(icon: .idle))
        #expect(rig.shown.count == 1)
    }

    @Test func reduceMotionShowsOneStaticFrame() {
        let rig = TrickRig()
        rig.reduceMotion = true
        for trick in MouthTrick.allCases {
            rig.trick = trick
            #expect(rig.player.start(icon: .idle))
            #expect(rig.shown.last == trick.staticFrame.file && rig.clock.pending.last?.seconds == trick.staticFrame.seconds)
            let count = rig.shown.count
            rig.clock.fire()
            #expect(rig.shown.count == count && !rig.player.isPlaying)
        }
        #expect(rig.restores == MouthTrick.allCases.count)
    }

    @Test func aTrickCanPlayAgainAfterItEnds() {
        let rig = TrickRig()
        rig.player.start(icon: .idle)
        rig.player.cancel()
        #expect(rig.player.start(icon: .idle))
    }

    @Test func optionOnOpenStartsATrickAndPlainOpenDoesNot() {
        let daily = DailyMenu()
        var seen: [Bool] = []
        daily.onWillOpen = { seen.append($0) }
        daily.modifierFlags = { [] }
        daily.menuNeedsUpdate(daily.menu)
        daily.modifierFlags = { .option }
        daily.menuNeedsUpdate(daily.menu)
        daily.modifierFlags = { [.option, .shift] }
        daily.menuNeedsUpdate(daily.menu)
        #expect(seen == [false, true, true])
    }
}

// MARK: Credits

@MainActor @Suite struct AboutCreditsTests {
    private func notices() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("THIRD_PARTY_NOTICES.md"), encoding: .utf8)
    }

    @Test func everyCreditIsAttributedInThirdPartyNotices() throws {
        let text = try notices()
        #expect(AboutCredits.entries.map(\.name) == ["Instrument Serif", "Parakeet TDT 0.6B v3", "FluidAudio"])
        for entry in AboutCredits.entries {
            #expect(text.contains(entry.name), "\(entry.name)")
        }
        #expect(text.contains("Copyright 2022 The Instrument Serif Project Authors"))
        #expect(text.contains("SIL OFL 1.1"))
        #expect(text.contains("NVIDIA") && text.contains("FluidInference") && text.contains("CC BY 4.0"))
        #expect(text.contains("| FluidAudio | 0.17.7 | Apache License 2.0 |"))
    }

    @Test func theRollIsPlainReadableTextWithASignoff() {
        let rendered = AboutCredits.attributed()
        #expect(rendered.string.contains("Instrument Serif") && rendered.string.contains("Apache License 2.0"))
        #expect(rendered.string.hasSuffix(AboutCredits.signoff))
        #expect(!AboutCredits.plainText.contains("\u{2014}") && !AboutCredits.plainText.contains("…"))
    }
}
