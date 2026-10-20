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
            wordsPage(page) { SavedSpellingsPage(model: model) }
        case .transforms:
            wordsPage(page) { PhrasesPage(model: model) }
        case .style:
            DesignPage(title: page.headline, summary: page.summary) {
                generalCleanup
                writing
            }
        case .appearance:
            DesignPage(title: page.headline, summary: page.summary) { appearance }
        }
    }

    /// The editors scroll for themselves, so the header sits above them instead of inside a scroll view.
    private func wordsPage<Content: View>(_ page: SettingsPage, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            DesignPageHeader(title: page.headline, summary: page.summary)
                .padding(.horizontal, 32).padding(.top, 40).padding(.bottom, 8).frame(maxWidth: .infinity, alignment: .leading)
            content()
        }
    }
}
