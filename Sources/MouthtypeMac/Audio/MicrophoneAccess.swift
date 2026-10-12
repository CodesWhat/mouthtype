// Adapted from Parrot (https://github.com/humanitas-labs/parrot, 0eb4708), MIT License, Copyright (c) 2026 Humanitas Labs.
import AVFoundation
import Foundation

/// Microphone authorization: asking once when the system has never asked, and
/// refusing to start capture when access is missing.
public enum MicrophoneAccess {
    public static var status: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Shows the system prompt if the user has never answered it, and returns
    /// the status once they have. Does not block the main thread.
    @discardableResult
    public static func requestIfUndetermined() async -> AVAuthorizationStatus {
        guard status == .notDetermined else { return status }
        Log.capture.info("requesting microphone access")
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        Log.capture.info("microphone access \(granted ? "granted" : "denied", privacy: .public)")
        return status
    }

    /// The menu's status line.
    public static func statusText(for status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Microphone: allowed"
        case .denied, .restricted: return "Microphone: not allowed"
        case .notDetermined: return "Microphone: not asked"
        @unknown default: return "Microphone: not asked"
        }
    }

    /// The error a press should fail with for `status`, or nil if capture may
    /// start.
    static func captureError(for status: AVAuthorizationStatus) -> CaptureError? {
        switch status {
        case .authorized:
            return nil
        case .denied, .restricted:
            return .microphoneDenied
        case .notDetermined:
            return .microphonePending
        @unknown default:
            return nil
        }
    }
}
