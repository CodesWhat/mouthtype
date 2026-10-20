import SwiftUI

/// The Saved spellings page. The editor fills the content area and the whole page scrolls when the window is too short for it.
struct SavedSpellingsPage: View {
    var model: SettingsModel

    var body: some View {
        if let editor = model.spellings, let suggestions = model.spellingSuggestions {
            WordsPageScroll { SpellingEditorView(editor: editor, suggestions: suggestions) }
        } else {
            SettingsForm { SettingsGroup(eyebrow: "SAVED SPELLINGS") { SettingsNote(text: "Saved spellings are unavailable.") } }
        }
    }
}

/// The Phrases page.
struct PhrasesPage: View {
    var model: SettingsModel

    var body: some View {
        if let editor = model.phrases {
            WordsPageScroll { PhraseEditorView(editor: editor) }
        } else {
            SettingsForm { SettingsGroup(eyebrow: "PHRASES") { SettingsNote(text: "Phrases are unavailable.") } }
        }
    }
}

private struct WordsPageScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView { content().frame(minHeight: proxy.size.height, alignment: .top) }
        }
    }
}
