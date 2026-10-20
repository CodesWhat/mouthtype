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
            try store.recordTranscription(id, TranscriptionRecord(
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

        let suggestions = SpellingSuggestionsModel(vocabulary: vocabulary, store: store,
                                                   dismissedURL: dir.appendingPathComponent("dismissed-suggestions.json"))
        await suggestions.reload()
        #expect(suggestions.suggestions.count >= 3)
        FontRegistry.registerBundledFonts()
        let editor = SpellingEditor(store: vocabulary)
        try render(editor, suggestions, name: "mouthtype-suggestions-light", appearance: .aqua)
        try render(editor, suggestions, name: "mouthtype-suggestions-dark", appearance: .darkAqua)

        let empty = SpellingSuggestionsModel(vocabulary: vocabulary, store: nil, dismissedURL: dir.appendingPathComponent("none.json"))
        try render(editor, empty, name: "mouthtype-suggestions-empty", appearance: .aqua)
    }

    private func render(_ editor: SpellingEditor, _ suggestions: SpellingSuggestionsModel, name: String, appearance: NSAppearance.Name) throws {
        let size = NSSize(width: 900, height: 700)
        let view = NSHostingView(rootView: SpellingEditorView(editor: editor, suggestions: suggestions, expandFirstSuggestion: true))
        view.appearance = NSAppearance(named: appearance)
        view.setFrameSize(size)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= Int(size.width))
        if let directory = ProcessInfo.processInfo.environment["MOUTHTYPE_SETTINGS_PREVIEWS"] {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
        }
    }
}
