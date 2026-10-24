import ApplicationServices
import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor private final class SelectionFixture: SelectionEditing {
    var selected = SelectedText(pid: 123, element: nil, range: NSRange(location: 3, length: 9), text: "um hello  world")
    var current: SelectedText?
    var attempts = 0
    var replacements: [String] = []
    var unavailable = false
    func capture() throws -> SelectedText {
        if unavailable { throw SelectionCleanupError.unavailable }
        return current ?? selected
    }
    func replace(_ original: SelectedText, with replacement: String) -> Bool {
        guard original == (current ?? selected) else { return false }
        attempts += 1
        replacements.append(replacement)
        return true
    }
}

@MainActor private final class SelectionWebsiteFocus: FocusReading {
    var current = FocusSnapshot(pid: 77, bundleID: "com.apple.Safari")
    var isSecureInputEnabled = false
    var reads = 0
    var seen: FocusSnapshot?
    var read: (@Sendable () -> String?)? = { "app.slack.com" }
    func snapshot() -> FocusSnapshot { current }
    func textBeforeCursor(of element: FocusedElement) -> TextBeforeCursor { .unknown }
    func websiteHostReader(for snapshot: FocusSnapshot) -> (@Sendable () -> String?)? {
        reads += 1
        seen = snapshot
        return read
    }
}

@MainActor private final class SelectionStyleGate {
    var continuation: CheckedContinuation<StyleOptions, Never>?
    func wait() async -> StyleOptions {
        await withCheckedContinuation { continuation = $0 }
    }
    func entered() async {
        while continuation == nil { await Task.yield() }
    }
    func release(_ style: StyleOptions = .formal) {
        continuation?.resume(returning: style)
        continuation = nil
    }
}

@MainActor @Suite struct SelectionCleanupTests {
    @Test func websiteToneOverridesTheBrowserToneForSelectedText() async throws {
        let editor = SelectionFixture()
        editor.selected = SelectedText(
            pid: 77, element: FocusedElement(AXUIElementCreateApplication(77)),
            range: NSRange(location: 0, length: 18), text: "Okay that is fine.")
        let focus = SelectionWebsiteFocus()
        var styles = AppCleanupStyles()
        try styles.set(bundleID: "com.apple.Safari", appName: "Safari", style: .formal)
        try styles.setWebsite(domain: "slack.com", style: StylePreset.veryCasual.options)
        let model = SelectionCleanupModel(
            editor: editor,
            styleFor: {
                await SelectionCleanupStyle.resolve(
                    $0, bundleID: "com.apple.Safari", styles: styles, fallback: .formal, focus: focus)
            })
        await model.prepare()
        #expect(model.result == "okay that is fine")
        #expect(focus.reads == 1)
        #expect(focus.seen?.element == editor.selected.element)
        model.accept()
        #expect(editor.replacements == ["okay that is fine"])
    }

    @Test(arguments: ["no host", "missing reader", "timeout", "different app", "different bundle", "secure", "secure input", "not a browser", "no element"])
    func unavailableWebsiteKeepsTheOriginalAppsTone(reason: String) async throws {
        let focus = SelectionWebsiteFocus()
        var selection = SelectedText(
            pid: 77, element: FocusedElement(AXUIElementCreateApplication(77)),
            range: NSRange(location: 0, length: 2), text: "Hi")
        var bundleID = "com.apple.Safari"
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        switch reason {
        case "no host": focus.read = { nil }
        case "missing reader": focus.read = nil
        case "timeout":
            focus.read = {
                release.wait(); return "app.slack.com"
            }
        case "different app": focus.current.pid = 88
        case "different bundle": focus.current.bundleID = "org.example.other"
        case "secure": focus.current.isSecure = true
        case "secure input": focus.isSecureInputEnabled = true
        case "not a browser": bundleID = "org.example.editor"; focus.current.bundleID = bundleID
        default: selection.element = nil
        }
        var styles = AppCleanupStyles()
        try styles.set(bundleID: bundleID, appName: "Source", style: StylePreset.casual.options)
        try styles.setWebsite(domain: "slack.com", style: StylePreset.veryCasual.options)
        let result = await SelectionCleanupStyle.resolve(
            selection, bundleID: bundleID, styles: styles, fallback: .formal, focus: focus, budget: 0.01)
        #expect(result == StylePreset.casual.options)
        #expect(focus.reads == (["no host", "missing reader", "timeout"].contains(reason) ? 1 : 0))
    }

    @Test func missingAppAndWebsiteKeepTheGlobalTone() async {
        let style = await SelectionCleanupStyle.resolve(
            SelectedText(pid: 77, element: nil, range: NSRange(location: 0, length: 2), text: "Hi"),
            bundleID: nil, styles: AppCleanupStyles(), fallback: StylePreset.veryCasual.options, focus: SelectionWebsiteFocus())
        #expect(style == StylePreset.veryCasual.options)
    }

    @Test(arguments: [false, true])
    func cancelledPreparationCannotRestorePrivateText(cancelTask: Bool) async {
        let gate = SelectionStyleGate()
        let model = SelectionCleanupModel(editor: SelectionFixture(), styleFor: { _ in await gate.wait() })
        let pending = Task { await model.prepare() }
        await gate.entered()
        if cancelTask { pending.cancel() } else { model.cancel() }
        gate.release()
        await pending.value
        #expect(!model.hasPreview && model.original.isEmpty && model.result.isEmpty)
    }

    @Test func earlierPreparationCannotOverwriteANewerPreview() async {
        let gate = SelectionStyleGate()
        let editor = SelectionFixture()
        var calls = 0
        let model = SelectionCleanupModel(
            editor: editor,
            styleFor: { _ in
                calls += 1
                return calls == 1 ? await gate.wait() : StylePreset.veryCasual.options
            })
        let earlier = Task { await model.prepare() }
        await gate.entered()
        editor.current = SelectedText(pid: 123, element: nil, range: NSRange(location: 0, length: 13), text: "Later preview")
        await model.prepare()
        gate.release()
        await earlier.value
        #expect(model.original == "Later preview" && model.result == "later preview")
        model.accept()
        #expect(editor.replacements == ["later preview"])
    }

    @Test func becomingBusyDuringTheReadDoesNotAdmitWork() async {
        let gate = SelectionStyleGate()
        var busy = false
        let model = SelectionCleanupModel(editor: SelectionFixture(), busy: { busy }, styleFor: { _ in await gate.wait() })
        let pending = Task { await model.prepare() }
        await gate.entered()
        busy = true
        gate.release()
        await pending.value
        #expect(!model.hasPreview && model.message.contains("Finish"))
    }

    @Test func panelCaptureDoesNotUseBlockingAccessibilityReads() async {
        final class Editor: SelectionEditing {
            func capture() throws -> SelectedText { throw SelectionCleanupError.unavailable }
            func captureOffMain(budget: TimeInterval) async throws -> SelectedText {
                SelectedText(pid: 123, element: nil, range: NSRange(location: 0, length: 14), text: "um hello world")
            }
            func replace(_ original: SelectedText, with replacement: String) -> Bool { false }
        }
        let model = SelectionCleanupModel(editor: Editor())
        await model.prepare()
        #expect(model.original == "um hello world")
        #expect(model.result == "Hello world")
    }

    @Test func previewDoesNotReplaceAndAcceptIsExplicitAndOneShot() async {
        let editor = SelectionFixture()
        let model = SelectionCleanupModel(editor: editor)
        await model.prepare()
        #expect(model.original == "um hello  world")
        #expect(model.result == "Hello world")
        #expect(editor.attempts == 0)
        model.accept()
        model.accept()
        #expect(editor.attempts == 1)
        #expect(model.submitted)
        #expect(model.result == "Hello world")
    }

    @Test func changedSelectionRefusesReplacementAndRetainsResultForCopy() async {
        let editor = SelectionFixture()
        let model = SelectionCleanupModel(editor: editor)
        await model.prepare()
        var changed = editor.selected
        changed.range.location += 1
        editor.current = changed
        model.accept()
        #expect(editor.attempts == 0)
        #expect(!model.submitted)
        #expect(model.result == "Hello world")
        #expect(model.refused && !model.canAccept)
        #expect(model.refusalTitle.contains("selection changed"))
    }

    @Test func cancelClearsPrivateTextAndUnavailableFieldsHaveNoResult() async {
        let editor = SelectionFixture()
        let model = SelectionCleanupModel(editor: editor)
        await model.prepare()
        model.cancel()
        #expect(model.original.isEmpty && model.result.isEmpty)
        model.accept()
        #expect(editor.attempts == 0)
        editor.unavailable = true
        await model.prepare()
        #expect(model.result.isEmpty)
        #expect(!model.message.isEmpty)
    }

    @Test func boundsAndBusyStateDoNotAdmitWork() async {
        let editor = SelectionFixture()
        editor.selected.text = String(repeating: "a", count: 16_001)
        let model = SelectionCleanupModel(editor: editor)
        await model.prepare()
        #expect(model.result.isEmpty)
        let busy = SelectionCleanupModel(editor: editor, busy: { true })
        await busy.prepare()
        #expect(busy.result.isEmpty)
    }

    @Test func identifiersNumbersAndLiteralNamesArePreserved() async {
        let editor = SelectionFixture()
        editor.selected.text = "Send Sean Build_v2 and 123."
        let model = SelectionCleanupModel(editor: editor)
        await model.prepare()
        #expect(model.result == "Send Sean Build_v2 and 123.")
    }

    @Test func previewDefersUpdaterAndCancelReleasesIt() async {
        let model = SelectionCleanupModel(editor: SelectionFixture())
        await model.prepare()
        #expect(UpdateActivity.resolve(phase: .idle, recovering: false, editingSelection: model.hasPreview) == .selectionCleanup)
        model.cancel()
        #expect(UpdateActivity.resolve(phase: .idle, recovering: false, editingSelection: model.hasPreview) == .idle)
    }

    @Test func busyAcceptDoesNotAttemptReplacement() async {
        let editor = SelectionFixture()
        var isBusy = false
        let model = SelectionCleanupModel(editor: editor, busy: { isBusy })
        await model.prepare()
        isBusy = true
        model.accept()
        #expect(editor.attempts == 0)
        #expect(!model.refused && model.canAccept && model.message.contains("dictation"))
    }

    @Test func refusalDisablesAcceptKeepsTheResultAndCancelClearsIt() async {
        let editor = SelectionFixture()
        let model = SelectionCleanupModel(editor: editor, appName: { _ in "Slack" })
        await model.prepare()
        #expect(model.sourceApp == "Slack" && !model.refused)
        var changed = editor.selected
        changed.range.location += 1
        editor.current = changed
        model.accept()
        #expect(model.refused && !model.canAccept && !model.submitted)
        #expect(model.refusalTitle == "The selection changed, or Slack refused the replacement.")
        #expect(model.result == "Hello world")
        editor.current = nil
        model.accept()
        #expect(editor.attempts == 0 && model.refused)
        model.cancel()
        #expect(!model.refused && !model.hasPreview && model.sourceApp == nil)
    }

    @Test func refusalNamesTheAppGenericallyWhenItIsUnknown() async {
        let editor = SelectionFixture()
        let model = SelectionCleanupModel(editor: editor, appName: { _ in nil })
        await model.prepare()
        editor.current = SelectedText(pid: 1, element: nil, range: NSRange(location: 0, length: 1), text: "x")
        model.accept()
        #expect(model.refusalTitle == "The selection changed, or the app refused the replacement.")
    }

    @Test func panelCaptureUsesTheMenuBudget() async {
        final class Spy: SelectionEditing {
            var budgets: [TimeInterval] = []
            func capture() throws -> SelectedText { throw SelectionCleanupError.unavailable }
            func capture(budget: TimeInterval) throws -> SelectedText { budgets.append(budget); throw SelectionCleanupError.timedOut }
            func replace(_ original: SelectedText, with replacement: String) -> Bool { false }
        }
        let spy = Spy()
        let model = SelectionCleanupModel(editor: spy)
        await model.prepare()
        #expect(spy.budgets == [0.15] && !model.hasPreview && model.message.contains("in time"))
    }

    @Test func cleanUpUsesTheFocusedAppsTone() async {
        let editor = SelectionFixture()
        editor.selected = SelectedText(pid: 77, element: nil, range: NSRange(location: 0, length: 0), text: "Okay that is fine.")
        editor.selected.range.length = editor.selected.text.utf16.count
        var seen: pid_t?
        let model = SelectionCleanupModel(
            editor: editor,
            styleFor: {
                seen = $0.pid; return StylePreset.veryCasual.options
            })
        await model.prepare()
        #expect(seen == 77 && model.result == "okay that is fine")
    }

    @Test func menuCaptureReportsReadyAndUnavailableFields() {
        let editor = SelectionFixture()
        let model = SelectionCleanupModel(editor: editor)
        #expect(model.captureForMenu() == .ready)
        editor.unavailable = true
        #expect(model.captureForMenu() == .unavailable)
    }

    @Test func panelAdoptsTheSelectionWhenItMatchesTheMenuSnapshot() async {
        let editor = SelectionFixture()
        let model = SelectionCleanupModel(editor: editor)
        #expect(model.captureForMenu() == .ready)
        await model.prepare()
        #expect(model.hasPreview && !model.refused && model.original == "um hello  world")
    }

    @Test func panelRefusesWhenTheSelectionChangedSinceTheMenu() async {
        for change in [
            { (s: inout SelectedText) in s.text = "other text here" },
            { (s: inout SelectedText) in s.range.location += 1 },
            { (s: inout SelectedText) in s.pid = 9 },
        ] {
            let editor = SelectionFixture()
            let model = SelectionCleanupModel(editor: editor, appName: { _ in "Notes" })
            #expect(model.captureForMenu() == .ready)
            var changed = editor.selected
            change(&changed)
            editor.current = changed
            await model.prepare()
            #expect(model.refused && !model.hasPreview && !model.canAccept)
            #expect(model.original.isEmpty && model.result.isEmpty)
            #expect(model.refusalTitle == "The selection changed in Notes.")
            model.accept()
            #expect(editor.attempts == 0)
        }
    }

    @Test func panelWithoutAMenuSnapshotCapturesOnce() async {
        let editor = SelectionFixture()
        let model = SelectionCleanupModel(editor: editor)
        await model.prepare()
        #expect(model.hasPreview && !model.refused)
        // The snapshot is consumed by one prepare, so a later open compares against nothing.
        #expect(model.captureForMenu() == .ready)
        await model.prepare()
        editor.current = SelectedText(pid: 123, element: nil, range: NSRange(location: 0, length: 5), text: "later")
        await model.prepare()
        #expect(model.hasPreview && !model.refused && model.original == "later")
    }

    @Test func acceptAndCopyUseTheEditedResultWithTheOriginalsBoundaryWhitespaceAppliedOnce() async {
        let editor = SelectionFixture()
        editor.selected = SelectedText(pid: 123, element: nil, range: NSRange(location: 0, length: 12), text: "um hello \nx\n")
        editor.selected.range.length = editor.selected.text.utf16.count
        let model = SelectionCleanupModel(editor: editor)
        await model.prepare()
        #expect(model.result.hasSuffix("\n") && !model.result.hasPrefix(" "))
        model.result = "Hello there.\n\n"
        model.accept()
        #expect(editor.replacements == ["Hello there.\n\n"])
    }
}

@Suite struct SelectionDiffTests {
    @Test func removedWordsAreMarkedAndCaseOrPunctuationChangesAreNot() {
        let original = "um so the meeting is uh at three pm tomorrow. i think so"
        let result = "So the meeting is at three pm tomorrow I think so"
        let marked = SelectionDiff.original(original, result: result).filter(\.marked).map(\.text)
        #expect(marked == ["um", "uh"])
    }

    @Test func addedAndChangedCharactersAreMarked() {
        let segments = SelectionDiff.result("So the meeting is at three. I think so", original: "so the meeting is at three. i think so")
        #expect(segments.filter(\.marked).map(\.text) == ["S", "I"])
        #expect(segments.map(\.text).joined() == "So the meeting is at three. I think so")
    }

    @Test func cacheKeepsCanonicallyEquivalentInputsApart() {
        let composed = "caf\u{E9} au lait"
        let decomposed = "cafe\u{301} au lait"
        #expect(composed == decomposed)
        let bytes = { (segments: [SelectionDiff.Segment]) in Array(segments.map(\.text).joined().utf8) }
        for (first, second) in [(composed, decomposed), (decomposed, composed)] {
            _ = SelectionDiff.result(first, original: "cafe au lait")
            #expect(bytes(SelectionDiff.result(second, original: "cafe au lait")) == Array(second.utf8))
            _ = SelectionDiff.original(first, result: "cafe")
            #expect(bytes(SelectionDiff.original(second, result: "cafe")) == Array(second.utf8))
        }
    }

    @Test func identicalTextAndOversizedTextHaveNoMarks() {
        #expect(SelectionDiff.result("same", original: "same").allSatisfy { !$0.marked })
        #expect(SelectionDiff.original("same", result: "same").allSatisfy { !$0.marked })
        let long = String(repeating: "word ", count: 1_000)
        #expect(SelectionDiff.result(long + "x", original: long).allSatisfy { !$0.marked })
    }

    @Test func oneCutoffAppliesToBothInputs() {
        let big = String(repeating: "word ", count: 500)  // 2,500 characters
        let small = "word one two"
        // A big original used to diff up to 4,000 characters, and a big result was never checked by original().
        #expect(SelectionDiff.original(big + "gone", result: "word").allSatisfy { !$0.marked })
        #expect(SelectionDiff.original(small, result: big).allSatisfy { !$0.marked })
        #expect(SelectionDiff.result(big, original: small).allSatisfy { !$0.marked })
        #expect(SelectionDiff.original("a b", result: "b").filter(\.marked).map(\.text) == ["a"])
    }

    @Test func emptyResultMarksNothingWhileATransformRuns() {
        let segments = SelectionDiff.original("a b", result: "")
        #expect(segments.allSatisfy { !$0.marked })
        #expect(SelectionDiff.original("a b", result: "b").filter(\.marked).map(\.text) == ["a"])
    }
}
