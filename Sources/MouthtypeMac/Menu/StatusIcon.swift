import AppKit

/// What the menu bar icon shows.
enum StatusIcon: CaseIterable {
    case idle, recording, processing, unavailable

    var symbolName: String {
        switch self {
        case .idle: "mic"
        case .recording: "mic.fill"
        case .processing: "waveform"
        case .unavailable: "mic.slash"
        }
    }

    /// Always a template, so it follows the menu bar appearance.
    var image: NSImage? {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Mouthtype")
        image?.isTemplate = true
        return image
    }

    /// An engine that failed, or missing microphone or Accessibility access, outranks the dictation phase.
    static func resolve(
        phase: DictationController.Phase, engineFailed: Bool, microphoneAllowed: Bool, accessibilityGranted: Bool
    ) -> StatusIcon {
        if engineFailed || !microphoneAllowed || !accessibilityGranted { return .unavailable }
        switch phase {
        case .idle: return .idle
        case .recording: return .recording
        case .processing: return .processing
        }
    }
}
