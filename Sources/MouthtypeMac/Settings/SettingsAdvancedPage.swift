import SwiftUI
import MouthtypeCore

extension SettingsView {
    /// Settings modal, Advanced: the set-once options that used to be spread over General, Writing and Diagnostics.
    @ViewBuilder var advancedPage: some View {
        DesignSection(eyebrow: "RECOGNITION") {
            ModalToggleRow(
                title: "Boost saved words", detail: boostDetail,
                isOn: Binding(get: { model.boostSavedWords }, set: model.setBoostSavedWords), identifier: "settings-boost-saved-words")
            ModalToggleRow(
                title: "Learn from my corrections", detail: "When you fix a take by hand, Mouthtype remembers the fix.",
                isOn: Binding(get: { model.learnCorrections }, set: model.setLearnCorrections), identifier: "settings-learn-corrections")
            ModalToggleRow(
                title: "Code names from your editor",
                detail: "While you dictate in VS Code, Cursor, Xcode or a terminal, favour file, folder and function names from the window you\u{2019}re in. Needs the boost above. Nothing is stored.",
                isOn: Binding(get: { model.editorHints }, set: model.setEditorHints), identifier: "settings-editor-hints")
            MicrophonePriorityRows(model: model.microphone)
        }
        DesignSection(
            eyebrow: "TONE DETAILS",
            footer: sharedControlsEnabled
                ? nil
                : "Cleanup is Off. Your dictation keeps its original wording and style; these options apply when cleanup is enabled."
        ) {
            ModalToggleRow(title: "Remove fillers", isOn: Binding(get: { model.cleanup.fillers }, set: model.setFillers), identifier: "settings-fillers")
            ModalToggleRow(
                title: "Spoken commands and lists", detail: "Say \u{201C}new paragraph\u{201D}, \u{201C}number one\u{201D}, \u{201C}scratch that\u{201D}.",
                isOn: Binding(get: { model.cleanup.spokenCommands }, set: model.setSpokenCommands), identifier: "settings-spoken-commands")
            ModalToggleRow(
                title: "Slash commands in coding apps", detail: "In terminals, editors and agent apps, \u{201C}slash research\u{201D} types /research.",
                isOn: Binding(get: { model.cleanup.slashCommands }, set: model.setSlashCommands), identifier: "settings-slash-commands")
            ModalToggleRow(title: "Format numbers", isOn: Binding(get: { model.cleanup.numbers }, set: model.setNumbers), identifier: "settings-numbers")
            ModalToggleRow(
                title: "Lowercase sentence starts", detail: "Shows as a Custom tone on the Style page.",
                isOn: Binding(get: { model.cleanup.style.capitalisation == .lowercase }, set: model.setLowercaseStarts), identifier: "settings-lowercase-starts")
            ModalToggleRow(
                title: "Drop the final full stop", detail: "Shows as a Custom tone on the Style page.",
                isOn: Binding(get: { model.cleanup.style.endingPunctuation == .dropFinalFullStop }, set: model.setDropFinalStop), identifier: "settings-drop-final-stop")
        }.disabled(!sharedControlsEnabled)
        DesignSection(
            eyebrow: "DELIVERY",
            footer: "Applies to that terminal app\u{2019}s windows. Mouthtype can\u{2019}t tell what\u{2019}s running inside it. Off by default."
        ) {
            DesignRow(title: "Split long pastes in these terminals", detail: "Long takes are pasted in pieces, only in the apps you turn on.") { EmptyView() }
            ForEach(PasteSettings.supportedTerminals, id: \.bundleID) { terminal in
                ModalToggleRow(
                    title: terminal.name,
                    isOn: Binding(get: { model.chunkedTerminals.contains(terminal.bundleID) }, set: { model.setChunks($0, bundleID: terminal.bundleID) }))
            }
        }
        AudioRetentionSection(model: model)
        DesignSection(eyebrow: "FILES & KEYS") {
            DesignRow(title: "Dictionary file", detail: actions.diagnostics?.dictionaryError ?? "The saved spellings file, as plain text.") {
                Button("Edit dictionary file…", action: actions.editDictionary).buttonStyle(.designSecondary).fixedSize()
                    .accessibilityIdentifier("settings-edit-dictionary")
            }
            if let state = actions.diagnostics {
                ModalToggleRow(
                    title: "Remap Fn to hide the emoji picker",
                    detail: state.canRemapFn ? nil : "Your custom shortcut is active. Fn keeps its system behavior.",
                    isOn: Binding(get: { state.remapChecked }, set: { _ in actions.toggleRemap() }), identifier: "settings-remap-fn"
                )
                .disabled(!state.canRemapFn)
            }
        }
    }

    /// Fillers, spoken commands, numbers and tone still apply to a take a rule turns cleanup on for, so they stay
    /// editable while the global level is Off.
    private var sharedControlsEnabled: Bool { model.cleanup.enabled || model.appStyles.enablesCleanup }

    private var boostDetail: String {
        var text = "Favours your saved spellings in the speech model, and English only. The first time, it downloads an extra speech model of about 100 MB. Dictation works without it until it is ready."
        let status = model.boostStatus.text
        if model.boostSavedWords, !status.isEmpty { text += " " + status + "." }
        return text
    }
}
