import SwiftUI
import MouthtypeCore

/// What each sidebar page shows. Until a page agent replaces its entry, the page hosts the pre-redesign view so the app stays
/// complete: Stats shows the redesigned page (Records is its High scores card), Dictionary the Saved spellings editor, Transforms the Phrases editor, Style the cleanup
/// level and the Writing groups, Appearance the Appearance groups. Each hosted page gets the redesign header from `DesignPage`.
extension SettingsView {
    @ViewBuilder var pageContent: some View {
        let page = model.page
        switch page {
        case .home:
            DesignPage(title: page.headline, summary: page.summary, trailing: {
                Button("Transcribe a file…") { model.transcribeOpen = true }
                    .buttonStyle(.designSecondary).fixedSize().accessibilityIdentifier("home-transcribe")
            }, content: { HomePage(model: model.home) })
        case .stats:
            DesignPage(title: page.headline, summary: page.summary) {
                StatsHostPage(model: model.stats)
            }
        case .dictionary:
            SavedSpellingsPage(model: model)
        case .transforms:
            DesignPage(title: page.headline, summary: page.summary) { PhrasesPage(model: model) }
        case .style:
            DesignPage(title: page.headline, summary: "A tone for each kind of writing, and the apps that count as each kind.") {
                styleContent
            }
        case .appearance:
            DesignPage(title: page.headline, summary: page.summary) { appearance }
        }
    }
}
