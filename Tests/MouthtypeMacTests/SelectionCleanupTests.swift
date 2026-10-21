import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor private final class SelectionFixture: SelectionEditing {
    var selected = SelectedText(pid: 123, element: nil, range: NSRange(location: 3, length: 9), text: "um hello  world")
    var current: SelectedText?
    var attempts = 0
    var unavailable = false
    func capture() throws -> SelectedText {
        if unavailable { throw SelectionCleanupError.unavailable }
        return current ?? selected
    }
    func replace(_ original: SelectedText, with replacement: String) -> Bool {
        guard original == (current ?? selected) else { return false }
        attempts += 1
        return true
    }
}

@MainActor @Suite struct SelectionCleanupTests {
    @Test func previewDoesNotReplaceAndAcceptIsExplicitAndOneShot() {
        let editor = SelectionFixture()
        let model = SelectionCleanupModel(editor: editor)
        model.prepare()
        #expect(model.original == "um hello  world")
        #expect(model.result == "Hello world")
        #expect(editor.attempts == 0)
        model.accept()
        model.accept()
        #expect(editor.attempts == 1)
        #expect(model.submitted)
        #expect(model.result == "Hello world")
    }

    @Test func changedSelectionRefusesReplacementAndRetainsResultForCopy() {
        let editor = SelectionFixture()
        let model = SelectionCleanupModel(editor: editor)
        model.prepare()
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

    @Test func cancelClearsPrivateTextAndUnavailableFieldsHaveNoResult() {
        let editor = SelectionFixture()
        let model = SelectionCleanupModel(editor: editor)
        model.prepare()
        model.cancel()
        #expect(model.original.isEmpty && model.result.isEmpty)
        model.accept()
        #expect(editor.attempts == 0)
        editor.unavailable = true
        model.prepare()
        #expect(model.result.isEmpty)
        #expect(!model.message.isEmpty)
    }

    @Test func boundsAndBusyStateDoNotAdmitWork() {
        let editor = SelectionFixture()
        editor.selected.text = String(repeating: "a", count: 16_001)
        let model = SelectionCleanupModel(editor: editor)
        model.prepare()
        #expect(model.result.isEmpty)
        let busy = SelectionCleanupModel(editor: editor, busy: { true })
        busy.prepare()
        #expect(busy.result.isEmpty)
    }

    @Test func identifiersNumbersAndLiteralNamesArePreserved() {
        let editor = SelectionFixture()
        editor.selected.text = "Send Sean Build_v2 and 123."
        let model = SelectionCleanupModel(editor: editor)
        model.prepare()
        #expect(model.result == "Send Sean Build_v2 and 123.")
    }

    @Test func previewDefersUpdaterAndCancelReleasesIt() {
        let model = SelectionCleanupModel(editor: SelectionFixture())
        model.prepare()
        #expect(UpdateActivity.resolve(phase: .idle, recovering: false, editingSelection: model.hasPreview) == .selectionCleanup)
        model.cancel()
        #expect(UpdateActivity.resolve(phase: .idle, recovering: false, editingSelection: model.hasPreview) == .idle)
    }

    @Test func busyAcceptDoesNotAttemptReplacement() {
        let editor = SelectionFixture()
        var isBusy = false
        let model = SelectionCleanupModel(editor: editor, busy: { isBusy })
        model.prepare()
        isBusy = true
        model.accept()
        #expect(editor.attempts == 0)
        #expect(!model.refused && model.canAccept && model.message.contains("dictation"))
    }

    @Test func refusalDisablesAcceptKeepsTheResultAndCancelClearsIt() {
        let editor = SelectionFixture()
        let model = SelectionCleanupModel(editor: editor, appName: { _ in "Slack" })
        model.prepare()
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

    @Test func refusalNamesTheAppGenericallyWhenItIsUnknown() {
        let editor = SelectionFixture()
        let model = SelectionCleanupModel(editor: editor, appName: { _ in nil })
        model.prepare()
        editor.current = SelectedText(pid: 1, element: nil, range: NSRange(location: 0, length: 1), text: "x")
        model.accept()
        #expect(model.refusalTitle == "The selection changed, or the app refused the replacement.")
    }

    @Test func panelCaptureUsesTheMenuBudget() {
        final class Spy: SelectionEditing {
            var budgets: [TimeInterval] = []
            func capture() throws -> SelectedText { throw SelectionCleanupError.unavailable }
            func capture(budget: TimeInterval) throws -> SelectedText { budgets.append(budget); throw SelectionCleanupError.timedOut }
            func replace(_ original: SelectedText, with replacement: String) -> Bool { false }
        }
        let spy = Spy()
        let model = SelectionCleanupModel(editor: spy)
        model.prepare()
        #expect(spy.budgets == [0.15] && !model.hasPreview && model.message.contains("in time"))
    }

    @Test func cleanUpUsesTheFocusedAppsTone() {
        let editor = SelectionFixture()
        editor.selected = SelectedText(pid: 77, element: nil, range: NSRange(location: 0, length: 0), text: "Okay that is fine.")
        editor.selected.range.length = editor.selected.text.utf16.count
        var seen: pid_t?
        let model = SelectionCleanupModel(editor: editor, styleFor: { seen = $0.pid; return StylePreset.veryCasual.options })
        model.prepare()
        #expect(seen == 77 && model.result == "okay that is fine")
    }

    @Test func menuCaptureReportsReadyAndUnavailableFields() {
        let editor = SelectionFixture()
        let model = SelectionCleanupModel(editor: editor)
        #expect(model.captureForMenu() == .ready)
        editor.unavailable = true
        #expect(model.captureForMenu() == .unavailable)
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

    @Test func identicalTextAndOversizedTextHaveNoMarks() {
        #expect(SelectionDiff.result("same", original: "same").allSatisfy { !$0.marked })
        #expect(SelectionDiff.original("same", result: "same").allSatisfy { !$0.marked })
        let long = String(repeating: "word ", count: 1_000)
        #expect(SelectionDiff.result(long + "x", original: long).allSatisfy { !$0.marked })
    }

    @Test func emptyResultMarksNothingWhileATransformRuns() {
        let segments = SelectionDiff.original("a b", result: "")
        #expect(segments.allSatisfy { !$0.marked })
        #expect(SelectionDiff.original("a b", result: "b").filter(\.marked).map(\.text) == ["a"])
    }
}
