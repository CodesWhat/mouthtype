import AppKit
import SwiftUI
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor @Suite(.serialized) struct SpellingSuggestionsRenderTests {
    @Test func suggestionsRenderInLightAndDarkWithSyntheticData() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-suggest-render-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vocabulary = FileVocabulary(url: dir.appendingPathComponent("dictionary.json"))
        for (heard, written) in [("shivon", "Siobhan"), ("praya", "Priya"), ("dry dock", "Drydock"), ("win", "Nguyen")] {
            try vocabulary.save(heard: heard, written: written)
        }
        let store = try TranscriptStore(url: dir.appendingPathComponent("mouthtype.sqlite"))
        let base = Date(timeIntervalSince1970: 1_791_806_400)
        func dictate(_ n: Int, _ raw: String, final: String? = nil) throws {
            let id = try store.begin(DictationStart(startedAt: base.addingTimeInterval(Double(n) * 60), target: DictationTarget(appName: "Notes")))
            try store.recordTranscription(
                id,
                TranscriptionRecord(
                    transcription: Transcription(text: raw, words: [], confidence: 0.9, processingSeconds: 0.1, engineID: "test", modelRevision: "1"),
                    rawText: raw, boostTerms: ["Siobhan"]))
            try store.recordInsertion(id, InsertionRecord(finalText: final ?? raw))
        }
        try dictate(1, "Shaban took a minute to reply")
        try dictate(2, "then Shabon called back about the invoice")
        try dictate(3, "Shaban agreed to the new date")
        try dictate(4, "email priya about the invoice", final: "Email priya about the invoice")
        try dictate(5, "Dry Doc and the release notes")
        try dictate(6, "ask Chavon about it")
        try dictate(7, "i hope we win the contract")
        for n in 10..<14 { try dictate(n, "we shipped build \(n) after lunch") }

        let suggestions = SpellingSuggestionsModel(
            vocabulary: vocabulary, store: store,
            dismissedURL: dir.appendingPathComponent("dismissed-suggestions.json"))
        await suggestions.reload()
        #expect(suggestions.suggestions.count >= 3)
        FontRegistry.registerBundledFonts()
        let editor = SpellingEditor(store: vocabulary)
        try renderPage(editor, suggestions, name: "dictionary-suggestions-light", dark: false)
        try renderPage(editor, suggestions, name: "dictionary-suggestions-dark", dark: true)

        let empty = SpellingSuggestionsModel(vocabulary: vocabulary, store: nil, dismissedURL: dir.appendingPathComponent("none.json"))
        try renderPage(editor, empty, name: "dictionary-suggestions-empty", dark: false)
    }

    private func renderPage(_ editor: SpellingEditor, _ suggestions: SpellingSuggestionsModel, name: String, dark: Bool) throws {
        let model = SettingsModel(defaults: UserDefaults(suiteName: "SuggestRender-\(UUID().uuidString)")!, spellings: editor, spellingSuggestions: suggestions)
        model.page = .dictionary
        let bitmap = try SettingsRender.render(model: model, actions: SettingsActions(), dark: dark)
        #expect(bitmap.pixelsWide >= 900)
        try SettingsRender.save(bitmap, name: name)
    }
}
