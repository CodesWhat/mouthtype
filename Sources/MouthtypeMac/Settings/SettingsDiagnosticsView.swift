import SwiftUI
import MouthtypeCore

struct SettingsDiagnosticsView: View {
    @Bindable var state: SettingsDiagnostics
    @Bindable var model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 9) {
                Text("DIAGNOSTICS").font(.custom("JetBrainsMono-Medium", size: 9)).foregroundStyle(.secondary)
                Text("Keep things moving.").font(.custom("InstrumentSerif-Regular", size: 38))
                Text("Model progress, permissions and input. Repairs in one place.").foregroundStyle(.secondary)
            }
            section("Local models") {
                row("Speech recognition", state.engineStatus) {
                    if state.engineFailed { Button("Retry model", action: actions.retrySpeech) }
                }
                if let cleaner = actions.cleaner {
                    row("Cleanup", cleanupStatus(cleaner)) {
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
                    if model.cleanup.level.needsModel, !ready(cleaner) {
                        Text("Dictations use Basic until the selected cleanup model is ready.").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            section("Permissions") {
                row("Microphone", MicrophoneAccess.statusText(for: state.microphoneStatus)) {
                    Button("Microphone Settings…", action: actions.openMicSettings)
                }
                row("Accessibility", AccessibilityAccess.statusText(granted: state.accessibilityGranted)) {
                    Button("Accessibility Settings…", action: actions.openAccessibilitySettings)
                }
            }
            section("Dictation input") {
                row("Shortcut listener", state.inputDescription) { Button("Change shortcut…", action: actions.changeShortcut) }
                if state.hotkeyHealth == .secureInputOn {
                    Text("Leave the password or other secure field to use dictation. Mouthtype won’t bypass Secure Input.").font(.callout).foregroundStyle(.secondary)
                }
                Toggle("Remap Fn to hide the emoji picker", isOn: Binding(get: { state.remapChecked }, set: { _ in actions.toggleRemap() }))
                    .disabled(!state.canRemapFn)
                if !state.canRemapFn { Text("Your custom shortcut is active. Fn keeps its system behavior.").font(.callout).foregroundStyle(.secondary) }
                if state.canRemapFn, !state.remapChecked, let globe = state.globe, globe.hasConflict {
                    row("Globe key", globe.menuText ?? "Keyboard action conflicts with Fn.") {
                        Button("Keyboard Settings…", action: actions.openKeyboardSettings)
                    }
                }
            }
            if state.dictionaryError != nil || state.phrasesError != nil || state.historyError != nil {
                section("Local libraries") {
                    if let error = state.dictionaryError { row("Saved spellings", error) { Button("Edit dictionary…", action: actions.editDictionary) } }
                    if let error = state.phrasesError { row("Phrase replacements", error) { Button("Edit phrases file…", action: actions.editPhrasesFile) } }
                    if let error = state.historyError { Text("Recent dictations: " + error).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
            }
            Button("Refresh status", action: actions.refreshDiagnostics)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) { Divider(); Text(title).font(.headline); content() }
    }
    private func row<Controls: View>(_ title: String, _ detail: String, @ViewBuilder controls: () -> Controls) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) { Text(title).fontWeight(.medium); Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 6)
            controls()
        }.padding(.vertical, 5)
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
