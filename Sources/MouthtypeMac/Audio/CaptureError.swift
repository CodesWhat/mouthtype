// Adapted from Parrot (https://github.com/humanitas-labs/parrot, 0eb4708), MIT License, Copyright (c) 2026 Humanitas Labs.
import Foundation

/// Why a recording could not start or produced nothing usable. Each case has
/// a one-line `userMessage` for the overlay; `description` adds the details
/// for the log. Neither ever contains audio or transcript text.
enum CaptureError: Error, CustomStringConvertible {
    /// Microphone access is denied or restricted for this app.
    case microphoneDenied
    /// The system has not asked yet, or the prompt is still open.
    case microphonePending
    /// Core Audio reports no default input device.
    case noInputDevice
    /// The input reports a format that cannot be recorded (0 Hz or 0 channels).
    case invalidInputFormat(sampleRate: Double, channels: UInt32)
    /// The audio unit failed to build or start.
    case engineStartFailed(Error)
    /// The input route changed mid-recording (a device was connected or
    /// removed, or its format changed). The partial capture was discarded.
    case routeChanged
    /// `stop()` without a recording in progress.
    case notRecording

    var userMessage: String {
        switch self {
        case .microphoneDenied:
            return "microphone access denied: System Settings → Privacy & Security → Microphone"
        case .microphonePending:
            return "microphone access not granted yet: answer the macOS prompt, then try again"
        case .noInputDevice, .invalidInputFormat:
            return "no microphone available: choose an input in System Settings → Sound"
        case .engineStartFailed:
            return "microphone failed to start: try again, or check System Settings → Sound"
        case .routeChanged:
            return "microphone changed while recording: nothing captured, try again"
        case .notRecording:
            return "no recording in progress"
        }
    }

    var description: String {
        switch self {
        case .invalidInputFormat(let sampleRate, let channels):
            return "\(userMessage) (input reports \(sampleRate) Hz, \(channels) ch)"
        case .engineStartFailed(let error):
            let code = (error as NSError).code
            return "\(userMessage) (unit: \((error as NSError).domain) \(code))"
        default:
            return userMessage
        }
    }
}
