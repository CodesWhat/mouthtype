import SwiftUI

/// The Dictionary page: serif header, then suggestions, the saved words, and New word as a sheet. It scrolls as one page.
struct SavedSpellingsPage: View {
    var model: SettingsModel

    var body: some View {
        if let editor = model.spellings, let suggestions = model.spellingSuggestions {
            DesignPage(title: "Your names, spelled right.",
                summary: "Teach Mouthtype the words it keeps mishearing. Save a spelling once and it sticks.") {
                SpellingEditorView(editor: editor, suggestions: suggestions)
            }
        } else {
            DesignPage(title: "Your names, spelled right.") {
                DesignSection(eyebrow: "Saved spellings") {
                    Text("Saved spellings are unavailable.").font(DesignFont.sans(DesignFont.body)).foregroundStyle(DesignPalette.ink2)
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
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
