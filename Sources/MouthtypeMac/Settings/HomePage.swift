import SwiftUI
import MouthtypeCore

/// The Home page: the recent dictations log as one grouped card. Full text wraps, never truncates.
struct HomePage: View {
    var model: HomeLogModel

    var body: some View {
        content
            .onAppear { model.activate() }
            .onDisappear { model.deactivate() }
    }

    @ViewBuilder private var content: some View {
        if model.takes.isEmpty {
            SettingsGroup(eyebrow: "RECENT DICTATIONS") {
                SettingsNote(text: model.error ?? "No dictations yet. Hold your shortcut and talk, and they land here.")
            }
        } else {
            SettingsGroup(eyebrow: "RECENT DICTATIONS", footer: "Newest first. Recover re-runs a take from its saved audio.") {
                ForEach(model.takes) { take in HomeTakeRow(take: take, model: model) }
            }
        }
    }
}

struct HomeTakeRow: View {
    let take: HomeTake
    var model: HomeLogModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.caption(take)).font(SettingsFont.mono(SettingsFont.eyebrow)).tracking(1).foregroundStyle(.secondary)
            Text(take.text ?? "No transcript. The audio is saved.")
                .font(SettingsFont.sans(SettingsFont.body))
                .foregroundStyle(take.text == nil ? .secondary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if take.text != nil {
                    Button(model.lastCopiedID == take.id ? "Copied" : "Copy") { model.copy(take) }
                        .accessibilityIdentifier("home-copy-" + take.id)
                }
                if take.recoverable != nil {
                    Button("Recover") { model.recover(take) }
                        .disabled(!model.recoverEnabled)
                        .accessibilityIdentifier("home-recover-" + take.id)
                }
            }.controlSize(.small).fixedSize()
        }.padding(.vertical, 6)
    }

    static func caption(_ take: HomeTake) -> String {
        let when = take.startedAt.formatted(date: .abbreviated, time: .shortened).uppercased()
        guard let app = take.appName, !app.isEmpty else { return when }
        return "\(when) \u{00B7} \(app.uppercased())"
    }
}
