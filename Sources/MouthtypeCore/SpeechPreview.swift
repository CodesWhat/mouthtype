import Foundation

/// Provisional words for display. This result must never be inserted or saved as the final transcript.
public protocol SpeechPreview: Sendable {
    func preview(samples: [Float]) async throws -> String?
}
