import Foundation

/// The consumers that record from the one shared microphone.
public enum CaptureOwner: Sendable, Equatable {
    case dictation, setupTest, voiceEdit, selfTest
}

/// One start's claim on the capture. `AudioCapture` records for a single lease at a time: a start under another
/// lease throws `CaptureError.busy`, and stop, cancel and the partial reads act only for the lease that started.
public struct CaptureLease: Sendable, Equatable {
    public let owner: CaptureOwner
    private let id = UUID()

    public init(owner: CaptureOwner) {
        self.owner = owner
    }
}
