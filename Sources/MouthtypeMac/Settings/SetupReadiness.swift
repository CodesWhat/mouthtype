import AVFoundation
import Foundation

enum SetupStep: Int {
    case microphone = 1, accessibility, speech, shortcut, ready
}

struct SetupReadiness {
    var microphone: AVAuthorizationStatus
    var accessibility: Bool
    var input: HotkeyHealth
    var speech: EngineState
    var captureReady: Bool
    var globeConflict: Bool = false

    var step: SetupStep {
        guard microphone == .authorized, captureReady else { return .microphone }
        guard accessibility else { return .accessibility }
        guard case .ready = speech else { return .speech }
        guard input == .listening, !globeConflict else { return .shortcut }
        return .ready
    }

    var isReady: Bool {
        guard microphone == .authorized, accessibility, input == .listening, captureReady, !globeConflict else { return false }
        if case .ready = speech { return true }
        return false
    }
}

@MainActor enum SetupLaunchPolicy {
    static let presentedKey = "SetupPresented"
    static func claimPresentation(defaults: UserDefaults, microphone: AVAuthorizationStatus, accessibility: Bool) -> Bool {
        guard !defaults.bool(forKey: presentedKey) else { return false }
        defaults.set(true, forKey: presentedKey)
        return microphone != .authorized || !accessibility
    }
}
