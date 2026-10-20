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
        #expect(model.message.contains("selection"))
        #expect(model.acceptanceErrorPresented)
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
        #expect(model.acceptanceErrorPresented)
    }

    @Test func failureAlertCanBeDismissedAndAValidRetryClearsIt() {
        let editor = SelectionFixture()
        let model = SelectionCleanupModel(editor: editor)
        model.prepare()
        var changed = editor.selected
        changed.range.location += 1
        editor.current = changed
        model.accept()
        #expect(model.acceptanceErrorPresented)
        #expect(model.result == "Hello world" && model.canAccept)
        model.acceptanceErrorPresented = false
        model.accept()
        #expect(model.acceptanceErrorPresented)
        editor.current = nil
        model.accept()
        #expect(!model.acceptanceErrorPresented && model.submitted)
        #expect(editor.attempts == 1)
        model.prepare()
        editor.current = changed
        model.accept()
        model.cancel()
        #expect(!model.acceptanceErrorPresented && !model.hasPreview)
    }

    @Test func tonePreviewsUseTheRealStyleStageAndFormalSoftensSwearing() {
        let editor = SelectionFixture()
        editor.selected = SelectedText(pid: 1, element: nil, range: NSRange(location: 0, length: 22), text: "Okay that is fine.")
        editor.selected.range.length = editor.selected.text.utf16.count
        let model = SelectionCleanupModel(editor: editor)
        model.prepare(tone: .veryCasual)
        #expect(model.result == "okay that is fine")
        #expect(model.tone == .veryCasual && model.message.contains("Very casual"))
        model.prepare(tone: .casual)
        #expect(model.result == "Okay that is fine")
        editor.selected = SelectedText(pid: 1, element: nil, range: NSRange(location: 0, length: 0), text: "Shit, I forgot the keys.")
        editor.selected.range.length = editor.selected.text.utf16.count
        model.prepare(tone: .formal)
        #expect(!model.result.lowercased().contains("shit"))
        model.prepare(tone: .casual)
        #expect(model.result.lowercased().contains("shit"))
        model.accept()
        #expect(editor.attempts == 1)
    }

    @Test func cleanUpUsesTheFocusedAppsTone() {
        let editor = SelectionFixture()
        editor.selected = SelectedText(pid: 77, element: nil, range: NSRange(location: 0, length: 0), text: "Okay that is fine.")
        editor.selected.range.length = editor.selected.text.utf16.count
        var seen: pid_t?
        let model = SelectionCleanupModel(editor: editor, styleFor: { seen = $0.pid; return StylePreset.veryCasual.options })
        model.prepare()
        #expect(seen == 77 && model.result == "okay that is fine" && model.tone == nil)
    }

    @Test func phraseReplacesSelectionWithSafetyChecks() {
        let editor = SelectionFixture()
        var busy = false
        let model = SelectionCleanupModel(editor: editor, busy: { busy })
        let phrase = Snippet(trigger: "Sign-off", expansion: "Best,\nScott")
        #expect(model.insert(phrase: phrase) == .unavailable)
        #expect(model.captureForMenu())
        #expect(model.insert(phrase: phrase) == .replaced)
        #expect(editor.attempts == 1)
        #expect(model.captureForMenu())
        busy = true
        #expect(model.insert(phrase: phrase) == .busy)
        busy = false
        editor.unavailable = true
        #expect(!model.captureForMenu())
        #expect(model.insert(phrase: phrase) == .unavailable)
        #expect(editor.attempts == 1)
    }

    @Test func phraseRefusesWhenSelectionChangedAfterMenuOpened() {
        let editor = SelectionFixture()
        let model = SelectionCleanupModel(editor: editor)
        let phrase = Snippet(trigger: "Sign-off", expansion: "Best,\nScott")
        #expect(model.captureForMenu())
        editor.selected = SelectedText(pid: 123, element: nil, range: NSRange(location: 40, length: 5), text: "other")
        #expect(model.insert(phrase: phrase) == .refused("Best,\nScott"))
        #expect(editor.attempts == 0)
    }

    @Test func refusedPhraseCarriesExpandedText() {
        let editor = SelectionFixture()
        let model = SelectionCleanupModel(editor: editor)
        let phrase = Snippet(trigger: "Sig", expansion: "On {date}: {clipboard}")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(model.captureForMenu())
        editor.current = SelectedText(pid: 9, element: nil, range: NSRange(location: 0, length: 1), text: "x")
        guard case let .refused(text) = model.insert(phrase: phrase, now: now, clipboard: "pasted") else {
            Issue.record("expected refused")
            return
        }
        #expect(text.contains("pasted") && !text.contains("{date}") && !text.contains("{clipboard}"))
    }
}
