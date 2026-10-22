import AVFoundation
import Foundation

enum SetupStep: Int {
    case microphone = 1, accessibility, speech, shortcut, ready

    static let footerNames = ["MICROPHONE", "ACCESSIBILITY", "SPEECH", "SHORTCUT"]

    /// One dot per setup step. The ready step has nothing left to do, so every dot is done.
    var dots: [SetupDot] {
        (1...4).map { index in
            if self == .ready || index < rawValue { .done } else if index == rawValue { .active } else { .pending }
        }
    }
}

enum SetupDot: Equatable {
    case done, active, pending
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
