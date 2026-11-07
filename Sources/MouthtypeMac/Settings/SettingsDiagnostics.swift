import AVFoundation
import Observation
import MouthtypeCore

@MainActor @Observable final class SettingsDiagnostics {
    var engineStatus = "Loading model…"
    var engineFailed = false
    var microphoneStatus = AVAuthorizationStatus.notDetermined
    var accessibilityGranted = false
    var hotkeyHealth = HotkeyHealth.off
    var globe: GlobeKeyCheck?
    var remapChecked = false
    var remapConflict = false
    var shortcut: DictationShortcut?
    var cleanupNeedsAttention = false
    var dictionaryError: String?
    var phrasesError: String?
    var historyError: String?
    /// Set when history couldn't be opened at launch. History stays off for the session.
    var historyOpenFailure: String?
    /// Set when a damaged history file was set aside at launch and a new one started.
    var historyNotice: String?

    func refreshModels(speech: String, failed: Bool, cleaner: any CleanupModelManaging, level: CleanupLevel) {
        engineStatus = speech
        engineFailed = failed
        switch cleaner.state {
        case .absent, .failed: cleanupNeedsAttention = level.needsModel
        default: cleanupNeedsAttention = false
        }
    }

    var canRemapFn: Bool { shortcut == nil }
    var attentionText: String? {
        if microphoneStatus != .authorized { return "Microphone access needed…" }
        if !accessibilityGranted { return "Accessibility access needed…" }
        if engineFailed { return "Speech model needs attention…" }
        switch hotkeyHealth {
        case .off: return "Dictation input is off…"
        case .recovering: return "Dictation input is recovering…"
        case .secureInputOn: return "Dictation is paused by Secure Input…"
        case .listening: break
        }
        if canRemapFn, remapConflict { return "Another app keeps changing the Fn key mapping…" }
        if canRemapFn, !remapChecked, globe?.hasConflict == true { return "Globe key conflicts with dictation…" }
        if cleanupNeedsAttention { return "Cleanup model needs attention…" }
        if dictionaryError != nil { return "Saved spellings need attention…" }
        if phrasesError != nil { return "Phrase replacements need attention…" }
        if historyOpenFailure != nil { return "History couldn't be opened…" }
        if historyError != nil { return "Recent takes unavailable…" }
        if historyNotice != nil { return "History was reset after damage…" }
        return nil
    }

    var inputDescription: String {
        hotkeyHealth.statusText.replacingOccurrences(of: "Hotkey:", with: "Dictation input:")
            .replacingOccurrences(of: "listening", with: "active") + " · " + (shortcut?.displayName ?? "Fn / Globe")
    }
}
