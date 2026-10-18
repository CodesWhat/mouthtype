import SwiftUI
import MouthtypeCore

extension SettingsView {
    @ViewBuilder var general: some View {
        SettingsGroup(eyebrow: "INPUT") {
            MicrophoneSettingsSection(model: model.microphone)
            SettingsRow(title: "Dictation shortcut", detail: "A key or combination that feels natural.") {
                Text(model.shortcut).font(.system(size: 12, design: .monospaced)).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
                Button("Change…", action: actions.changeShortcut).accessibilityIdentifier("settings-shortcut")
            }
            SettingsRow(title: "Recording behavior", detail: "Changing this cancels an active recording.") {
                Picker("Recording behavior", selection: Binding(get: { model.recordingMode.rawValue }, set: { if let mode = RecordingMode(rawValue: $0) { model.setRecordingMode(mode) } })) {
                    Text("Hold to talk").tag(RecordingMode.hold.rawValue)
                    Text("Press to toggle").tag(RecordingMode.toggle.rawValue)
                }.labelsHidden().fixedSize().accessibilityIdentifier("settings-recording-mode")
            }
            if let error = model.recordingModeError { SettingsNote(text: error, tone: .red) }
        }
        SettingsGroup(eyebrow: "CLEANUP") {
            SettingsRow(title: "Cleanup", detail: cleanupDetail) {
                if let cleaner = actions.cleaner {
                    switch cleaner.state {
                    case .absent, .failed:
                        Button("Download…") {
                            let target = cleaner.downloadTarget
                            if CleanupMenuSection.askToDownload(name: target.modelName, sizeMB: target.downloadSizeMB) { target.startDownload() }
                        }
                    case .downloading: Button("Cancel") { cleaner.cancelDownload() }
                    default: EmptyView()
                    }
                }
                Picker("Cleanup", selection: Binding(get: { model.cleanup.level.rawValue }, set: { if let level = CleanupLevel(rawValue: $0) { model.setLevel(level) } })) {
                    ForEach(CleanupLevel.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }.labelsHidden().fixedSize().accessibilityIdentifier("settings-cleanup-level")
            }
        }
        SettingsGroup(eyebrow: "WHILE RECORDING") {
            SettingsRow(title: "Quiet other audio", detail: "Mute the current output while recording, on supported devices.") {
                Toggle("Quiet other audio", isOn: Binding(get: { model.quietOtherAudio }, set: model.setQuietOtherAudio))
                    .labelsHidden().toggleStyle(.switch).accessibilityIdentifier("settings-quiet-audio")
            }
            LivePreviewSettingsRow(model: model)
            SettingsRow(title: "Recording sounds", detail: "A small cue when you start and finish.") {
                Toggle("Recording sounds", isOn: Binding(get: { model.sounds }, set: model.setSounds))
                    .labelsHidden().toggleStyle(.switch).accessibilityIdentifier("settings-sounds")
            }
        }
        SettingsGroup(eyebrow: "MAC") {
            SettingsRow(title: "Launch at login",
                detail: model.loginState == .mixed ? "Waiting for approval in System Settings." : "Keep Mouthtype ready in your menu bar.") {
                if model.loginState == .mixed { Button("Open Login Items…") { model.toggleLogin() } }
                Toggle("Launch at login", isOn: Binding(get: { model.loginState != .off }, set: { _ in model.toggleLogin() }))
                    .labelsHidden().toggleStyle(.switch).accessibilityIdentifier("settings-launch-at-login")
            }
            if let updater = actions.updater {
                SettingsRow(title: "Updates", detail: updater.statusText) {
                    Toggle("Check automatically", isOn: Binding(get: { updater.automaticallyChecksForUpdates }, set: updater.setAutomaticChecks))
                        .toggleStyle(.checkbox).disabled(!updater.isAvailable).accessibilityIdentifier("settings-auto-updates")
                    Button(updater.hasUpdate ? "Review Update…" : "Check for Updates…") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates).accessibilityIdentifier("settings-check-updates")
                }
            }
        }
    }

    private var cleanupDetail: String {
        var text = "Fast and Thorough run locally on your Mac."
        if let cleaner = actions.cleaner {
            text += " " + modelStatus(cleaner)
            if model.cleanup.level.needsModel, !isReady(cleaner) { text += " Basic is used until it is ready." }
        }
        return text
    }

    private func isReady(_ cleaner: any CleanupModelManaging) -> Bool { if case .ready = cleaner.state { true } else { false } }
    private func modelStatus(_ cleaner: any CleanupModelManaging) -> String {
        let name = cleaner.modelName
        switch cleaner.state {
        case .absent: return "\(name) is not downloaded."
        case .downloading(let fraction): return "\(name) downloading: \(Int(fraction * 100))%."
        case .loading: return "\(name) is loading…"
        case .unloaded: return "\(name) is downloaded and loads when needed."
        case .ready: return "\(name) is ready."
        case .failed(let message): return "\(name): \(message)"
        }
    }
}
