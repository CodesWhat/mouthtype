import AppKit
import SwiftUI

/// Advanced > Press Return after inserting: the apps that get a Return once a take is pasted. Terminals, which can't confirm a paste, get it unchecked. Empty means off.
struct SendAfterInsertSection: View {
    @Bindable var model: SettingsModel

    var body: some View {
        DesignSection(
            eyebrow: "PRESS RETURN AFTER INSERTING",
            footer:
                "After a dictation lands in one of these apps, Mouthtype presses Return to send it. It checks the text landed first, except in terminals, which can't report it. Never in password fields."
        ) {
            if model.sendAfterInsertBundleIDs.isEmpty {
                DesignRow(title: "Off", detail: "No apps yet. Mouthtype never presses Return.") { addButton }
            } else {
                ForEach(model.sendAfterInsertBundleIDs, id: \.self) { bundleID in
                    appRow(bundleID)
                }
                DesignRow(title: "Add app") { addButton }
            }
            if let error = model.sendAfterInsertError { ModalCardNote(text: error, tone: .red) }
        }
    }

    private var addButton: some View {
        Button("Add App…", action: model.chooseSendAfterInsertApplication).buttonStyle(.designSecondary).fixedSize()
            .accessibilityLabel("Add an app that gets Return after inserting").accessibilityIdentifier("settings-send-after-insert-add")
    }

    static let unconfirmedNote = "Can't confirm the paste here, so Return goes out without checking."

    /// The secondary line under an app that can't confirm a paste, nil for the rest.
    static func note(for bundleID: String) -> String? {
        PasteTargetPolicy.confirmsPaste(bundleID: bundleID) ? nil : unconfirmedNote
    }

    private func appRow(_ bundleID: String) -> some View {
        let name = SendAfterInsertApps.name(bundleID: bundleID)
        return HStack(spacing: 12) {
            StyleMemberIcon(member: StyleMember(kind: .app, name: name, keys: [bundleID], isBuiltIn: false))
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(DesignFont.sans(DesignFont.body, .medium)).foregroundStyle(DesignPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = Self.note(for: bundleID) {
                    Text(note).font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink3)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("settings-send-after-insert-note")
                }
            }
            Spacer(minLength: 8)
            Button {
                model.removeSendAfterInsert(bundleID: bundleID)
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(DesignPalette.ink3)
                    .frame(width: 28, height: 28).contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain).accessibilityLabel("Remove \(name) from Press Return after inserting")
            .accessibilityIdentifier("settings-send-after-insert-remove")
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 6).frame(minHeight: 40)
    }
}

/// Display names for stored bundle IDs. An app that is no longer installed falls back to its identifier.
enum SendAfterInsertApps {
    static func name(bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID), let bundle = Bundle(url: url) else { return bundleID }
        return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
    }
}
