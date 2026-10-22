import SwiftUI
import MouthtypeCore

extension SettingsView {
    /// Settings modal, General: Dictation (shortcut, recording behavior, microphone).
    @ViewBuilder var generalInput: some View {
        DesignSection(eyebrow: "DICTATION") {
            DesignRow(title: "Shortcut", detail: model.recordingMode == .hold ? "Hold it, speak, let go." : "Press it once to start, again to stop.") {
                DesignKbd(model.shortcut)
                Button("Change…", action: actions.changeShortcut).buttonStyle(.designSecondary).fixedSize()
                    .accessibilityLabel("Change dictation shortcut").accessibilityIdentifier("settings-shortcut")
            }
            DesignRow(title: "Recording behavior", detail: "Hold to talk, or press once to start and again to stop. Changing this cancels an active recording.") {
                DesignPopup(
                    title: "Recording behavior",
                    selection: Binding(get: { model.recordingMode.rawValue }, set: { if let mode = RecordingMode(rawValue: $0) { model.setRecordingMode(mode) } }),
                    choices: [DesignChoice("Hold to talk", RecordingMode.hold.rawValue), DesignChoice("Press to toggle", RecordingMode.toggle.rawValue)]
                )
                .accessibilityIdentifier("settings-recording-mode")
            }
            if let error = model.recordingModeError { ModalCardNote(text: error, tone: .red) }
            DesignRow(title: "Mouse button", detail: "An extra button that dictates like the shortcut. Only that button is used; other clicks are untouched.") {
                DesignPopup(
                    title: "Mouse button",
                    selection: Binding(get: { model.mouseTrigger.rawValue }, set: { if let trigger = MouseTrigger(rawValue: $0) { model.setMouseTrigger(trigger) } }),
                    choices: MouseTrigger.allCases.map { DesignChoice($0.displayName, $0.rawValue) }
                )
                .accessibilityIdentifier("settings-mouse-trigger")
            }
            if let error = model.mouseTriggerError { ModalCardNote(text: error, tone: .red) }
            MicrophoneSettingsSection(model: model.microphone)
        }
    }

    /// Settings modal, General: While recording (sounds, live words, quiet other audio).
    @ViewBuilder var generalRecording: some View {
        DesignSection(eyebrow: "WHILE RECORDING") {
            ModalToggleRow(
                title: "Recording sounds", detail: "A small cue when you start and finish.",
                isOn: Binding(get: { model.sounds }, set: model.setSounds), identifier: "settings-sounds")
            LivePreviewSettingsRow(model: model)
            ModalToggleRow(
                title: "Quiet other audio", detail: "Mute the current output while recording, on supported devices.",
                isOn: Binding(get: { model.quietOtherAudio }, set: model.setQuietOtherAudio), identifier: "settings-quiet-audio")
        }
    }

    /// Settings modal, Mac: launch at login and updates.
    @ViewBuilder var generalMac: some View {
        DesignSection(eyebrow: "STARTUP") {
            DesignRow(
                title: "Launch at login",
                detail: model.loginState == .mixed ? "Waiting for approval in System Settings." : "Keep Mouthtype ready in your menu bar."
            ) {
                if model.loginState == .mixed {
                    Button("Open Login Items…") { model.toggleLogin() }.buttonStyle(.designSecondary).fixedSize()
                }
                Toggle("Launch at login", isOn: Binding(get: { model.loginState != .off }, set: { _ in model.toggleLogin() }))
                    .labelsHidden().toggleStyle(.designSwitch).accessibilityIdentifier("settings-launch-at-login")
            }
            DesignRow(title: "Show in Dock", detail: "The menu bar icon stays in every mode.") {
                DesignPopup(
                    title: "Show in Dock",
                    selection: Binding(get: { model.dockIconMode.rawValue }, set: { if let mode = DockIconMode(rawValue: $0) { model.setDockIconMode(mode) } }),
                    choices: DockIconMode.allCases.map { DesignChoice($0.label, $0.rawValue) }
                )
                .accessibilityIdentifier("settings-show-in-dock")
            }
        }
        if let updater = actions.updater {
            DesignSection(eyebrow: "UPDATES") {
                DesignRow(title: "Check for updates automatically", detail: "Mouthtype looks in the background and tells you when one is ready.") {
                    Toggle("Check for updates automatically", isOn: Binding(get: { updater.automaticallyChecksForUpdates }, set: updater.setAutomaticChecks))
                        .labelsHidden().toggleStyle(.designSwitch).disabled(!updater.isAvailable).accessibilityIdentifier("settings-auto-updates")
                }
                DesignRow(title: "Updates", detail: updater.statusText) {
                    Button(updater.hasUpdate ? "Review Update…" : "Check for Updates…") { updater.checkForUpdates() }
                        .buttonStyle(.designSecondary).fixedSize()
                        .disabled(!updater.canCheckForUpdates).accessibilityIdentifier("settings-check-updates")
                }
            }
        }
    }
}
