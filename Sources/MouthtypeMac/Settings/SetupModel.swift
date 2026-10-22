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
    /// The optional test take on the ready step. Nil where setup has no capture to record with.
    let testTake: SetupTestTake?
    /// Where the optional "Get names right" offer stands on the ready card. In memory only: Setup asks again next time.
    enum NamesChoice { case offered, turnedOn, skipped }
    private(set) var namesChoice = NamesChoice.offered
    private(set) var boostStatus = VocabularyBoostStatusCenter.current
    private let onBoostSavedWordsChanged: @MainActor (Bool) -> Void

    init(
        diagnostics: SettingsDiagnostics, engine: EngineHost, microphone: MicrophonePreparation = MicrophonePreparation(),
        cleanup: (any CleanupModelListing)? = nil, testTake: SetupTestTake? = nil, defaults: UserDefaults = .standard,
        onBoostSavedWordsChanged: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        self.onBoostSavedWordsChanged = onBoostSavedWordsChanged
        self.testTake = testTake
        self.cleanup = cleanup
        self.diagnostics = diagnostics
        self.engine = engine
        self.microphone = microphone
        self.defaults = defaults
        refreshInstructions()
        NotificationCenter.default.addObserver(forName: .vocabularyBoostStatusChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.boostStatus = VocabularyBoostStatusCenter.current }
        }
    }

    /// The offer shows until declined, and never when Boost saved words is already on (an existing user's choice stands).
    var offersNames: Bool {
        switch namesChoice {
        case .offered: !VocabularyBoostSetting.isEnabled(defaults)
        case .turnedOn: true
        case .skipped: false
        }
    }

    /// Does what turning on Boost saved words and Names on screen in Settings > Advanced does: the same two settings, and the
    /// same change callback, which hands the engine the bias and so starts the model download.
    func turnOnNames() {
        VocabularyBoostSetting.set(true, in: defaults)
        ContextNamesSetting.set(true, in: defaults)
        namesChoice = .turnedOn
        boostStatus = VocabularyBoostStatusCenter.current
        onBoostSavedWordsChanged(true)
    }

    func skipNames() { namesChoice = .skipped }

    /// Fast and Thorough, with their download state. Empty when the app gave setup no cleanup models.
    var cleanupModels: [CleanupModelStatus] { cleanup?.cleanupModels() ?? [] }

    func downloadCleanupModel(_ level: CleanupLevel) { cleanup?.downloadCleanupModel(level) }
    func cancelCleanupDownload(_ level: CleanupLevel) { cleanup?.cancelCleanupDownload(level) }

    var readiness: SetupReadiness {
        SetupReadiness(
            microphone: diagnostics.microphoneStatus, accessibility: diagnostics.accessibilityGranted,
            input: diagnostics.hotkeyHealth, speech: engine.state, captureReady: captureReady,
            globeConflict: diagnostics.canRemapFn && !diagnostics.remapChecked && diagnostics.globe?.hasConflict == true)
    }

    var inputDetail: String {
        if diagnostics.hotkeyHealth == .secureInputOn { return "Leave the password or other secure field to use dictation." }
        if readiness.globeConflict { return "Fn also opens a system action. Choose Fn remapping or another shortcut with Change shortcut." }
        return diagnostics.inputDescription
    }

    func refreshInstructions() {
        instructions =
            HelpMenuSection.instructions(for: ShortcutSettings.load(defaults), mode: RecordingModePreference.current(defaults))
            .components(separatedBy: "\n\n").dropFirst().first
            ?? "Click a text field in another app, then use your dictation shortcut."
    }
}
