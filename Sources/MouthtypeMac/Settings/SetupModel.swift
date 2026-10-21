import AVFoundation
import Foundation
import MouthtypeCore
import Observation

@MainActor @Observable final class SetupModel {
    let diagnostics: SettingsDiagnostics
    let engine: EngineHost
    let microphone: MicrophonePreparation
    private let cleanup: (any CleanupModelListing)?
    var captureReady: Bool { microphone.isPrepared }
    var capturePreparing: Bool { microphone.isPreparing }
    var captureError: String? { microphone.error }
    private let defaults: UserDefaults
    private(set) var instructions = ""

    init(diagnostics: SettingsDiagnostics, engine: EngineHost, microphone: MicrophonePreparation = MicrophonePreparation(),
         cleanup: (any CleanupModelListing)? = nil, defaults: UserDefaults = .standard) {
        self.cleanup = cleanup
        self.diagnostics = diagnostics
        self.engine = engine
        self.microphone = microphone
        self.defaults = defaults
        refreshInstructions()
    }

    /// Fast and Thorough, with their download state. Empty when the app gave setup no cleanup models.
    var cleanupModels: [CleanupModelStatus] { cleanup?.cleanupModels() ?? [] }

    func downloadCleanupModel(_ level: CleanupLevel) { cleanup?.downloadCleanupModel(level) }
    func cancelCleanupDownload(_ level: CleanupLevel) { cleanup?.cancelCleanupDownload(level) }

    var readiness: SetupReadiness {
        SetupReadiness(microphone: diagnostics.microphoneStatus, accessibility: diagnostics.accessibilityGranted,
            input: diagnostics.hotkeyHealth, speech: engine.state, captureReady: captureReady,
            globeConflict: diagnostics.canRemapFn && !diagnostics.remapChecked && diagnostics.globe?.hasConflict == true)
    }

    var inputDetail: String {
        if diagnostics.hotkeyHealth == .secureInputOn { return "Leave the password or other secure field to use dictation." }
        if readiness.globeConflict { return "Fn also opens a system action. Choose Fn remapping or another shortcut with Change shortcut." }
        return diagnostics.inputDescription
    }

    func refreshInstructions() {
        instructions = HelpMenuSection.instructions(for: ShortcutSettings.load(defaults), mode: RecordingModePreference.current(defaults))
            .components(separatedBy: "\n\n").dropFirst().first
            ?? "Click a text field in another app, then use your dictation shortcut."
    }
}
