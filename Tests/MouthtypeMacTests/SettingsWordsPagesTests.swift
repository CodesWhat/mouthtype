import AppKit
import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor @Suite struct SettingsWordsPagesTests {
    private struct Fixture {
        let dir: URL
        let defaults: UserDefaults
        let suite: String
        let model: SettingsModel
        let spellings: SpellingEditor
        let suggestions: SpellingSuggestionsModel
        let phrases: PhraseEditor
        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func fixture() throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-words-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vocabulary = FileVocabulary(url: dir.appendingPathComponent("dictionary.json"))
        let suite = "SettingsWords-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let spellings = SpellingEditor(store: vocabulary)
        let suggestions = SpellingSuggestionsModel(vocabulary: vocabulary, dismissedURL: dir.appendingPathComponent("dismissed.json"))
        let phrases = PhraseEditor(store: FilePhrases(url: dir.appendingPathComponent("phrases.json")))
        let model = SettingsModel(defaults: defaults, spellings: spellings, spellingSuggestions: suggestions, phrases: phrases)
        return Fixture(dir: dir, defaults: defaults, suite: suite, model: model, spellings: spellings, suggestions: suggestions, phrases: phrases)
    }

    @Test func switchingAwayFromADirtySpellingKeepsTheDraftWhenTheUserKeepsEditing() throws {
        let f = try fixture()
        defer { f.cleanup() }
        var asked: [(SettingsModel.DraftExit, SettingsModel.DraftKind)] = []
        f.model.confirmDiscard = { exit, kind in asked.append((exit, kind)); return false }
        f.model.page = .dictionary
        f.spellings.newSpelling()
        f.spellings.heardInput = "mouth type"
        #expect(!f.model.select(.style))
        #expect(f.model.page == .dictionary && f.spellings.heardInput == "mouth type" && f.spellings.isDirty)
        #expect(asked.count == 1 && asked[0].0 == .leaving && asked[0].1 == .spelling)
    }

    @Test func discardingDropsTheDraftAndMovesOn() throws {
        let f = try fixture()
        defer { f.cleanup() }
        f.model.confirmDiscard = { _, _ in true }
        f.model.page = .transforms
        f.phrases.newPhrase()
        f.phrases.trigger = "my email"
        #expect(f.model.select(.dictionary))
        #expect(f.model.page == .dictionary && f.phrases.trigger.isEmpty && !f.phrases.isDirty)
    }

    @Test func aCleanEditorSwitchesWithoutAsking() throws {
        let f = try fixture()
        defer { f.cleanup() }
        f.model.confirmDiscard = { _, _ in Issue.record("asked about a clean draft"); return false }
        f.model.page = .transforms
        #expect(f.model.select(.style) && f.model.page == .style)
    }

    @Test func closingTheWindowAsksOnlyWhileADraftIsUnsaved() throws {
        let f = try fixture()
        defer { f.cleanup() }
        var exits: [SettingsModel.DraftExit] = []
        f.model.confirmDiscard = { exit, _ in exits.append(exit); return false }
        f.model.page = .dictionary
        #expect(f.model.resolveDraft(.closing))
        f.spellings.newSpelling()
        f.spellings.written = "Mouthtype"
        #expect(!f.model.resolveDraft(.closing))
        #expect(exits == [.closing])
    }

    @Test func quitAsksAboutADirtyDraftAndKeepEditingCancelsIt() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let window = SettingsWindow(model: f.model, reduceTransparency: { true })
        defer { window.close() }
        var exits: [SettingsModel.DraftExit] = []
        var answer = false
        f.model.confirmDiscard = { exit, _ in exits.append(exit); return answer }
        f.model.page = .dictionary
        #expect(window.resolveDraftForQuit())
        #expect(exits.isEmpty)
        f.spellings.newSpelling()
        f.spellings.heardInput = "mouth type"
        #expect(!window.resolveDraftForQuit())
        #expect(exits == [.quitting] && f.spellings.isDirty && f.model.page == .dictionary)
        answer = true
        #expect(window.resolveDraftForQuit())
        #expect(f.spellings.isDirty, "the draft survives until the quit is certain")
        window.discardDraftForQuit()
        #expect(!f.spellings.isDirty)
    }

    @Test func settingsSheetsTargetTheMouthtypeWindowDirectly() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let window = SettingsWindow(model: f.model, reduceTransparency: { true })
        defer { window.close() }
        window.window?.orderFront(nil)
        let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        other.makeKeyAndOrderFront(nil)
        defer { other.close() }
        #expect(SettingsNSWindow.existing === window.window)
    }

    @Test func refusedQuitNeverAsksAboutTheDraft() throws {
        let f = try fixture()
        defer { f.cleanup() }
        f.model.confirmDiscard = { _, _ in Issue.record("asked before quit was certain"); return true }
        f.model.page = .dictionary
        f.spellings.newSpelling()
        f.spellings.heardInput = "mouth type"
        let window = SettingsWindow(model: f.model, reduceTransparency: { true })
        defer { window.close() }
        #expect(!AppDelegate.mayQuit(allowsTermination: false, resolveDraft: { window.resolveDraftForQuit() }))
        #expect(f.spellings.isDirty)
        f.model.confirmDiscard = { _, _ in true }
        #expect(AppDelegate.mayQuit(allowsTermination: true, resolveDraft: { window.resolveDraftForQuit() }))
    }

    @Test func aDraftOnAnotherPageDoesNotBlockLeavingThisOne() throws {
        let f = try fixture()
        defer { f.cleanup() }
        f.model.confirmDiscard = { _, _ in Issue.record("asked"); return false }
        f.model.page = .transforms
        f.spellings.newSpelling()
        f.spellings.heardInput = "left behind"
        #expect(f.model.select(.style))
    }

    @Test func suggestionsAreActiveOnlyWhileTheSavedSpellingsPageShows() throws {
        let f = try fixture()
        defer { f.cleanup() }
        #expect(!f.suggestions.isActive)
        f.model.page = .style
        f.model.syncWords()
        #expect(!f.suggestions.isActive)
        f.model.page = .dictionary
        f.model.syncWords()
        #expect(f.suggestions.isActive)
        f.model.page = .transforms
        f.model.syncWords()
        #expect(!f.suggestions.isActive)
        f.model.page = .dictionary
        f.model.syncWords()
        f.model.deactivateWords()
        #expect(!f.suggestions.isActive)
    }

    @Test func savingASpellingTellsTheSuggestionsTheLibraryChanged() throws {
        let f = try fixture()
        defer { f.cleanup() }
        f.model.page = .dictionary
        f.model.syncWords()
        f.spellings.newSpelling()
        f.spellings.heardInput = "mouth type"
        f.spellings.written = "Mouthtype"
        f.spellings.save()
        #expect(f.spellings.items.map(\.heard) == ["mouth type"])
        #expect(f.suggestions.isActive)
    }

    @Test func phraseKindsFollowThePlaceholdersAndLineCount() {
        #expect(TransformKind.of(Snippet(trigger: "my email", expansion: "me@example.com")) == .text)
        #expect(TransformKind.of(Snippet(trigger: "paste quote", expansion: "> {clipboard}")) == .clipboard)
        #expect(TransformKind.of(Snippet(trigger: "today", expansion: "{date}")) == .date)
        #expect(TransformKind.of(Snippet(trigger: "both", expansion: "{date}\n{clipboard}")) == .clipboard)
        #expect(TransformKind.of(Snippet(trigger: "sign off", expansion: "Thanks,\nScott")) == .lines(2))
        #expect(TransformKind.of(Snippet(trigger: "three", expansion: "a\nb\nc")).title == "3 LINES")
        #expect([TransformKind.text, .clipboard, .date].map(\.title) == ["TEXT", "CLIPBOARD", "DATE"])
    }

    @Test func rowTextShowsPlaceholdersAsDescriptionsAndLineBreaksAsReturnSigns() {
        #expect(PhraseEditorView.display("{clipboard}").placeholder)
        #expect(PhraseEditorView.display("{date}").text.hasPrefix("Today\u{2019}s date"))
        let signOff = PhraseEditorView.display("Thanks,\nScott")
        #expect(signOff.text == "Thanks, \u{23CE} Scott" && !signOff.placeholder)
        #expect(PhraseEditorView.display("me@example.com").text == "me@example.com")
    }

    @Test func phraseSearchMatchesTriggerTextAndKind() throws {
        let f = try fixture()
        defer { f.cleanup() }
        for (trigger, expansion) in [("my email", "me@example.com"), ("paste quote", "> {clipboard}"), ("sign off", "Best,\nScott")] {
            f.phrases.newPhrase()
            f.phrases.trigger = trigger
            f.phrases.expansion = expansion
            f.phrases.save()
        }
        #expect(f.phrases.matching("").count == 3)
        #expect(f.phrases.matching("EMAIL").map(\.trigger) == ["my email"])
        #expect(f.phrases.matching("scott").map(\.trigger) == ["sign off"])
        #expect(f.phrases.matching("clipboard").map(\.trigger) == ["paste quote"])
        #expect(f.phrases.matching("my  example").map(\.trigger) == ["my email"])
        #expect(f.phrases.matching("nothing here").isEmpty)
    }

    @Test func cancelDropsAPhraseDraftAndSaveKeepsIt() throws {
        let f = try fixture()
        defer { f.cleanup() }
        f.phrases.newPhrase()
        f.phrases.trigger = "my email"
        f.phrases.expansion = "me@example.com"
        f.phrases.cancel()
        #expect(!f.phrases.isDirty && f.phrases.items.isEmpty)
        f.phrases.newPhrase()
        f.phrases.trigger = "my email"
        f.phrases.expansion = "me@example.com"
        f.phrases.save()
        #expect(!f.phrases.isDirty && f.phrases.items.map(\.trigger) == ["my email"])
    }
}
