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
    /// The Models page shows once every requirement passes and stays until Continue. In memory only: Setup shows it next time.
    private(set) var modelsReviewed = false
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

    /// The step the window shows: the readiness step, with the optional Models page before the final card.
    var step: SetupStep {
        let required = readiness.step
        return required == .ready && !modelsReviewed ? .models : required
    }

    func finishModels() { modelsReviewed = true }

    /// Does what turning on Boost saved words and Names on screen in Settings > Advanced does: the same two settings, and the
    /// same change callback, which hands the engine the bias and so starts the model download.
    func turnOnNames() {
        VocabularyBoostSetting.set(true, in: defaults)
        ContextNamesSetting.set(true, in: defaults)
        boostStatus = VocabularyBoostStatusCenter.current
        onBoostSavedWordsChanged(true)
    }

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

    /// Every model Setup knows about, in page order: the required speech model, then the optional cleanup and names models.
    var modelEntries: [SetupModelEntry] {
        var entries = [speechEntry]
        entries += cleanupModels.map { SetupModelEntry(cleanup: $0) }
        entries.append(namesEntry)
        return entries
    }

    private var speechEntry: SetupModelEntry {
        let state: SetupModelState
        if case .ready = engine.state {
            state = .ready
        } else {
            switch engine.downloadStatus {
            case .failed: state = .failed(engine.statusText)
            case let .downloading(progress): state = .downloading(fraction: progress.fraction, caption: ModelDownloadFormat.caption(progress))
            case .done: state = .ready
            case .preparing, .available: state = .preparing
            }
        }
        return SetupModelEntry(
            id: .speech, title: "Speech model", size: "About 480 MB", detail: "Required. Turns your voice into text on this Mac.", state: state)
    }

    private var namesEntry: SetupModelEntry {
        let state: SetupModelState
        if !VocabularyBoostSetting.isEnabled(defaults) {
            state = .available
        } else {
            switch boostStatus {
            case .ready: state = .ready
            case let .downloading(fraction): state = .downloading(fraction: fraction ?? 0, caption: boostStatus.text)
            case .off, .preparing: state = .preparing
            case let .failed(message): state = .failed(message)
            }
        }
        return SetupModelEntry(
            id: .names, title: "Names model", size: "About 100 MB", detail: "Optional. Spells saved and on-screen names.", state: state)
    }
}

/// One row on the Models page: what it is, its size, why you'd want it, and where it stands.
struct SetupModelEntry: Identifiable, Equatable {
    enum Kind: Hashable { case speech, cleanup(CleanupLevel), names }
    var id: Kind
    var title: String
    var size: String
    var detail: String
    var state: SetupModelState
    var selected = false

    init(id: Kind, title: String, size: String, detail: String, state: SetupModelState, selected: Bool = false) {
        self.id = id
        self.title = title
        self.size = size
        self.detail = detail
        self.state = state
        self.selected = selected
    }

    init(cleanup model: CleanupModelStatus) {
        let state: SetupModelState
        switch model.status {
        case .available: state = .available
        case let .downloading(progress): state = .downloading(fraction: progress.fraction, caption: ModelDownloadFormat.caption(progress))
        case .preparing: state = .preparing
        case .done: state = .ready
        case let .failed(message): state = .failed(message)
        }
        self.init(
            id: .cleanup(model.level), title: "\(model.level.title) cleanup",
            size: ModelDownloadFormat.size(Int64(model.sizeMB) * 1_000_000),
            detail: model.level == .light ? "Optional. Faster cleanup with light edits." : "Optional. Fuller edits that follow your style.",
            state: state, selected: model.selected)
    }
}

enum SetupModelState: Equatable {
    case ready, available, preparing
    case downloading(fraction: Double, caption: String)
    case failed(String)
}
