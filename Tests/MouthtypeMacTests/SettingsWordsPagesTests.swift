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
        f.model.page = .savedSpellings
        f.spellings.newSpelling()
        f.spellings.heard = "mouth type"
        #expect(!f.model.select(.general))
        #expect(f.model.page == .savedSpellings && f.spellings.heard == "mouth type" && f.spellings.isDirty)
        #expect(asked.count == 1 && asked[0].0 == .leaving && asked[0].1 == .spelling)
    }

    @Test func discardingDropsTheDraftAndMovesOn() throws {
        let f = try fixture()
        defer { f.cleanup() }
        f.model.confirmDiscard = { _, _ in true }
        f.model.page = .phrases
        f.phrases.newPhrase()
        f.phrases.trigger = "my email"
        #expect(f.model.select(.savedSpellings))
        #expect(f.model.page == .savedSpellings && f.phrases.trigger.isEmpty && !f.phrases.isDirty)
    }

    @Test func aCleanEditorSwitchesWithoutAsking() throws {
        let f = try fixture()
        defer { f.cleanup() }
        f.model.confirmDiscard = { _, _ in Issue.record("asked about a clean draft"); return false }
        f.model.page = .phrases
        #expect(f.model.select(.general) && f.model.page == .general)
    }

    @Test func closingTheWindowAsksOnlyWhileADraftIsUnsaved() throws {
        let f = try fixture()
        defer { f.cleanup() }
        var exits: [SettingsModel.DraftExit] = []
        f.model.confirmDiscard = { exit, _ in exits.append(exit); return false }
        f.model.page = .savedSpellings
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
        f.model.page = .savedSpellings
        #expect(window.resolveDraftForQuit())
        #expect(exits.isEmpty)
        f.spellings.newSpelling()
        f.spellings.heard = "mouth type"
        #expect(!window.resolveDraftForQuit())
        #expect(exits == [.quitting] && f.spellings.isDirty && f.model.page == .savedSpellings)
        answer = true
        #expect(window.resolveDraftForQuit())
        #expect(!f.spellings.isDirty)
    }

    @Test func aDraftOnAnotherPageDoesNotBlockLeavingThisOne() throws {
        let f = try fixture()
        defer { f.cleanup() }
        f.model.confirmDiscard = { _, _ in Issue.record("asked"); return false }
        f.model.page = .phrases
        f.spellings.newSpelling()
        f.spellings.heard = "left behind"
        #expect(f.model.select(.general))
    }

    @Test func suggestionsAreActiveOnlyWhileTheSavedSpellingsPageShows() throws {
        let f = try fixture()
        defer { f.cleanup() }
        #expect(!f.suggestions.isActive)
        f.model.page = .general
        f.model.syncWords()
        #expect(!f.suggestions.isActive)
        f.model.page = .savedSpellings
        f.model.syncWords()
        #expect(f.suggestions.isActive)
        f.model.page = .phrases
        f.model.syncWords()
        #expect(!f.suggestions.isActive)
        f.model.page = .savedSpellings
        f.model.syncWords()
        f.model.deactivateWords()
        #expect(!f.suggestions.isActive)
    }

    @Test func savingASpellingTellsTheSuggestionsTheLibraryChanged() throws {
        let f = try fixture()
        defer { f.cleanup() }
        f.model.page = .savedSpellings
        f.model.syncWords()
        f.spellings.newSpelling()
        f.spellings.heard = "mouth type"
        f.spellings.written = "Mouthtype"
        f.spellings.save()
        #expect(f.spellings.items.map(\.heard) == ["mouth type"])
        #expect(f.suggestions.isActive)
    }
}
