import Foundation
import Testing
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
        #expect(model.message.contains("selection"))
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
    }
}
