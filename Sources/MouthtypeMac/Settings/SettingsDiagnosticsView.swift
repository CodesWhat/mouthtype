import SwiftUI
import MouthtypeCore

struct SettingsDiagnosticsView: View {
    @Bindable var state: SettingsDiagnostics
    @Bindable var model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        Group {
            SettingsGroup(eyebrow: "LOCAL MODELS") {
                row("Speech recognition", state.engineStatus) {
                    if state.engineFailed { Button("Retry model", action: actions.retrySpeech) }
                }
                if let cleaner = actions.cleaner {
                    row("Cleanup", cleanupStatus(cleaner)
                        + (model.cleanup.level.needsModel && !ready(cleaner) ? " Dictations use Basic until the selected cleanup model is ready." : "")) {
                        switch cleaner.state {
                        case .absent, .failed:
                            Button("Download…") {
                                let target = cleaner.downloadTarget
                                if CleanupMenuSection.askToDownload(name: target.modelName, sizeMB: target.downloadSizeMB) { target.startDownload() }
                            }
                        case .downloading: Button("Cancel download") { cleaner.cancelDownload() }
                        default: EmptyView()
                        }
                    }
                }
            }
            SettingsGroup(eyebrow: "PERMISSIONS") {
                row("Microphone", MicrophoneAccess.statusText(for: state.microphoneStatus)) {
                    Button("Microphone Settings…", action: actions.openMicSettings)
                }
                row("Accessibility", AccessibilityAccess.statusText(granted: state.accessibilityGranted)) {
                    Button("Accessibility Settings…", action: actions.openAccessibilitySettings)
                }
            }
            SettingsGroup(eyebrow: "DICTATION INPUT") {
                row("Shortcut listener", state.inputDescription) { Button("Change shortcut…", action: actions.changeShortcut) }
                row("How dictation works", model.recordingInstructions) { EmptyView() }
                if state.hotkeyHealth == .secureInputOn {
                    SettingsNote(text: "Leave the password or other secure field to use dictation. Mouthtype won’t bypass Secure Input.")
                }
                SettingsRow(title: "Remap Fn to hide the emoji picker",
                    detail: state.canRemapFn ? nil : "Your custom shortcut is active. Fn keeps its system behavior.") {
                    Toggle("Remap Fn to hide the emoji picker", isOn: Binding(get: { state.remapChecked }, set: { _ in actions.toggleRemap() }))
                        .labelsHidden().toggleStyle(.switch).disabled(!state.canRemapFn)
                }
                if state.canRemapFn, !state.remapChecked, let globe = state.globe, globe.hasConflict {
                    row("Globe key", globe.menuText ?? "Keyboard action conflicts with Fn.") {
                        Button("Keyboard Settings…", action: actions.openKeyboardSettings)
                    }
                }
            }
            if state.dictionaryError != nil || state.phrasesError != nil || state.historyError != nil {
                SettingsGroup(eyebrow: "LOCAL LIBRARIES") {
                    if let error = state.dictionaryError { row("Saved spellings", error) { Button("Edit dictionary…", action: actions.editDictionary) } }
                    if let error = state.phrasesError { row("Phrase replacements", error) { Button("Edit phrases file…", action: actions.editPhrasesFile) } }
                    if let error = state.historyError { SettingsNote(text: "Recent dictations: " + error) }
                }
            }
            AudioRetentionSection(model: model)
            SettingsGroup(eyebrow: "STATUS") {
                SettingsRow(title: "Refresh status") { Button("Refresh status", action: actions.refreshDiagnostics) }
            }
        }
    }

    private func row<Controls: View>(_ title: String, _ detail: String, @ViewBuilder controls: @escaping () -> Controls) -> some View {
        SettingsRow(title: title, detail: detail, controls: controls)
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
