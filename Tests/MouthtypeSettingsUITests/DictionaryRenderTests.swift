import AppKit
import SwiftUI
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor @Suite(.serialized) struct DictionaryRenderTests {
    private struct Fixture {
        let dir: URL
        let store: FileVocabulary
        let editor: SpellingEditor
        let suggestions: SpellingSuggestionsModel
        let model: SettingsModel
    }

    private func fixture(words: [(String, String)]) throws -> Fixture {
        FontRegistry.registerBundledFonts()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-dictionary-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = FileVocabulary(url: dir.appendingPathComponent("dictionary.json"))
        for (heard, written) in words { try store.save(heard: heard, written: written) }
        let editor = SpellingEditor(store: store)
        let suggestions = SpellingSuggestionsModel(vocabulary: store, dismissedURL: dir.appendingPathComponent("dismissed.json"))
        let defaults = UserDefaults(suiteName: "DictionaryRender-\(UUID().uuidString)")!
        let model = SettingsModel(defaults: defaults, spellings: editor, spellingSuggestions: suggestions)
        model.page = .dictionary
        return Fixture(dir: dir, store: store, editor: editor, suggestions: suggestions, model: model)
    }

    private let sample = [("priya", "Priya"), ("pre ya", "Priya"), ("mouth type", "Mouthtype"), ("mouse type", "Mouthtype"),
                          ("tahoe", "Tahoe"), ("win", "Nguyen"),
                          ("a very long phrase that people say out loud before it becomes one name", "Hyprland")]

    @Test func dictionaryPageRendersWordsInLightAndDark() throws {
        let f = try fixture(words: sample)
        defer { try? FileManager.default.removeItem(at: f.dir) }
        #expect(f.editor.words.count == 5)
        try f.store.save(heard: "omar key", written: "Omarchy")
        f.editor.reload()
        f.editor.toggleStar(try #require(f.editor.words.first))
        for dark in [false, true] {
            let bitmap = try SettingsRender.render(model: f.model, actions: SettingsActions(), dark: dark)
            #expect(bitmap.pixelsWide >= 900 && bitmap.pixelsHigh >= 620)
            try SettingsRender.save(bitmap, name: "dictionary-\(dark ? "dark" : "light")")
        }
    }

    @Test func emptyLibraryRendersItsNote() throws {
        let f = try fixture(words: [])
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let bitmap = try SettingsRender.render(model: f.model, actions: SettingsActions(), dark: false)
        try SettingsRender.save(bitmap, name: "dictionary-empty")
    }

    @Test func newWordSheetRendersInLightAndDark() throws {
        let f = try fixture(words: sample)
        defer { try? FileManager.default.removeItem(at: f.dir) }
        f.editor.newSpelling()
        f.editor.written = "Sean"
        f.editor.heardInput = "shawn"
        f.editor.commitHeardInput()
        f.editor.heardInput = "shaun"
        f.editor.commitHeardInput()
        f.editor.starred = true
        #expect(f.editor.canSave && f.editor.isEditing)
        for dark in [false, true] {
            let bitmap = try SettingsRender.render(SpellingWordSheet(editor: f.editor), dark: dark, size: NSSize(width: 500, height: 470))
            #expect(bitmap.pixelsWide >= 500)
            try SettingsRender.save(bitmap, name: "dictionary-new-word-\(dark ? "dark" : "light")")
        }
    }

    @Test func editSheetShowsTheEverydayWarningAndDelete() throws {
        let f = try fixture(words: sample)
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let word = try #require(f.editor.words.first { $0.written == "Nguyen" })
        #expect(word.warning != nil)
        f.editor.select(word)
        #expect(f.editor.everydayWarning?.contains("everyday word") == true)
        let bitmap = try SettingsRender.render(SpellingWordSheet(editor: f.editor), dark: false, size: NSSize(width: 500, height: 520))
        try SettingsRender.save(bitmap, name: "dictionary-edit-word-warning")
    }
}
