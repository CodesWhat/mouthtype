import SwiftUI
import MouthtypeCore

/// The Settings modal's Health page, the old Diagnostics: set up, local models, permissions, dictation input and any library problems.
/// Remap Fn and saved-audio retention moved to Advanced.
struct SettingsDiagnosticsView: View {
    @Bindable var state: SettingsDiagnostics
    @Bindable var model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        Group {
            DesignSection(eyebrow: "SET UP") {
                DesignRow(title: "Set Up Mouthtype", detail: "Walk through the microphone, Accessibility and shortcut steps again.") {
                    Button("Set Up Mouthtype…") {
                        model.closeSettings(); actions.openSetup()
                    }
                    .buttonStyle(.designSecondary).fixedSize().accessibilityIdentifier("settings-setup")
                }
            }
            DesignSection(eyebrow: "LOCAL MODELS") {
                row("Speech recognition", state.engineStatus) {
                    if state.engineFailed { Button("Retry model", action: actions.retrySpeech).buttonStyle(.designSecondary).fixedSize() }
                }
                if let cleaner = actions.cleaner {
                    row(
                        "Cleanup",
                        cleanupStatus(cleaner)
                            + (model.cleanup.level.needsModel && !ready(cleaner) ? " Dictations use Basic until the selected cleanup model is ready." : "")
                    ) {
                        switch cleaner.state {
                        case .absent, .failed:
                            Button("Download…") {
                                let target = cleaner.downloadTarget
                                if CleanupModelDownloadConfirmation.askToDownload(name: target.modelName, sizeMB: target.downloadSizeMB) { target.startDownload() }
                            }.buttonStyle(.designSecondary).fixedSize()
                        case .downloading: Button("Cancel download") { cleaner.cancelDownload() }.buttonStyle(.designSecondary).fixedSize()
                        default: EmptyView()
                        }
                    }
                }
            }
            DesignSection(eyebrow: "PERMISSIONS") {
                row("Microphone", MicrophoneAccess.statusText(for: state.microphoneStatus)) {
                    Button("Microphone Settings…", action: actions.openMicSettings).buttonStyle(.designSecondary).fixedSize()
                }
                row("Accessibility", AccessibilityAccess.statusText(granted: state.accessibilityGranted)) {
                    Button("Accessibility Settings…", action: actions.openAccessibilitySettings).buttonStyle(.designSecondary).fixedSize()
                }
            }
            DesignSection(eyebrow: "DICTATION INPUT") {
                row("Shortcut listener", state.inputDescription) {
                    Button("Change shortcut…", action: actions.changeShortcut).buttonStyle(.designSecondary).fixedSize()
                }
                row("How dictation works", model.recordingInstructions) { EmptyView() }
                if state.hotkeyHealth == .secureInputOn {
                    ModalCardNote(text: "Leave the password or other secure field to use dictation. Mouthtype won\u{2019}t bypass Secure Input.")
                }
                if state.canRemapFn, state.remapConflict {
                    ModalCardNote(text: "Another app keeps changing the Fn key mapping, so Remap Fn was turned off for this session. Dictation is using the plain Fn key.")
                }
                if state.canRemapFn, !state.remapChecked, let globe = state.globe, globe.hasConflict {
                    row("Globe key", (globe.menuText ?? "Keyboard action conflicts with Fn.") + " Remap Fn, under Advanced options, hides the emoji picker instead.") {
                        Button("Keyboard Settings…", action: actions.openKeyboardSettings).buttonStyle(.designSecondary).fixedSize()
                    }
                }
            }
            if state.dictionaryError != nil || state.phrasesError != nil || state.historyError != nil {
                DesignSection(eyebrow: "LOCAL LIBRARIES") {
                    if let error = state.dictionaryError {
                        row("Saved spellings", error) { Button("Edit dictionary…", action: actions.editDictionary).buttonStyle(.designSecondary).fixedSize() }
                    }
                    if let error = state.phrasesError {
                        row("Phrase replacements", error) { Button("Edit phrases file…", action: actions.editPhrasesFile).buttonStyle(.designSecondary).fixedSize() }
                    }
                    if let error = state.historyError { ModalCardNote(text: "Recent takes: " + error) }
                }
            }
            DesignSection(eyebrow: "STATUS") {
                DesignRow(title: "Refresh status") {
                    Button("Refresh status", action: actions.refreshDiagnostics).buttonStyle(.designSecondary).fixedSize()
                }
            }
        }
    }

    private func row<Controls: View>(_ title: String, _ detail: String, @ViewBuilder controls: @escaping () -> Controls) -> some View {
        DesignRow(title: title, detail: detail, controls: controls)
    }
    private func ready(_ cleaner: any CleanupModelManaging) -> Bool { if case .ready = cleaner.state { true } else { false } }
    private func cleanupStatus(_ cleaner: any CleanupModelManaging) -> String {
        switch cleaner.state {
        case .absent: "\(cleaner.modelName) is not downloaded."
        case .downloading(let fraction): "\(cleaner.modelName) downloading: \(Int(min(max(fraction, 0), 1) * 100))%."
        case .loading: "\(cleaner.modelName) is loading…"
        case .unloaded: "\(cleaner.modelName) is downloaded and loads when needed."
        case .ready: "\(cleaner.modelName) is ready."
        case .failed(let message): "\(cleaner.modelName): \(message)"
        }
    }
}
