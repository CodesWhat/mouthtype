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

/// The Transforms page body. The page header and scrolling come from `DesignPage` in `SettingsPageHosts`.
struct PhrasesPage: View {
    var model: SettingsModel

    var body: some View {
        if let editor = model.phrases {
            PhraseEditorView(editor: editor)
        } else {
            Text("Phrases are unavailable.").font(DesignFont.sans(DesignFont.body)).foregroundStyle(DesignPalette.ink2)
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
