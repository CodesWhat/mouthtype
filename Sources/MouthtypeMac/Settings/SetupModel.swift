import AVFoundation
import Foundation
import MouthtypeCore
import Observation

@MainActor @Observable final class SetupModel {
    let diagnostics: SettingsDiagnostics
    let engine: EngineHost
    var captureReady = false
    var capturePreparing = false
    var captureError: String?
    private let defaults: UserDefaults
    private(set) var instructions = ""

    init(diagnostics: SettingsDiagnostics, engine: EngineHost, defaults: UserDefaults = .standard) {
        self.diagnostics = diagnostics
        self.engine = engine
        self.defaults = defaults
        refreshInstructions()
    }

    var readiness: SetupReadiness {
        SetupReadiness(microphone: diagnostics.microphoneStatus, accessibility: diagnostics.accessibilityGranted,
            input: diagnostics.hotkeyHealth, speech: engine.state, captureReady: captureReady,
            globeConflict: diagnostics.canRemapFn && !diagnostics.remapChecked && diagnostics.globe?.hasConflict == true)
    }

    var inputDetail: String {
        if diagnostics.hotkeyHealth == .secureInputOn { return "Leave the password or other secure field to use dictation." }
        if readiness.globeConflict { return "Fn also opens a system action. Choose Fn remapping or another shortcut in Input settings." }
        return diagnostics.inputDescription
    }

    func refreshInstructions() {
        instructions = HelpMenuSection.instructions(for: ShortcutSettings.load(defaults), mode: RecordingModePreference.current(defaults))
            .components(separatedBy: "\n\n").dropFirst().first
            ?? "Click a text field in another app, then use your dictation shortcut."
    }
}
