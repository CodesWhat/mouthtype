import Foundation
import MouthtypeCore

/// Runs an explicit selected-text transform on the local cleanup model.
@MainActor protocol SelectionTransforming: AnyObject {
    /// Why transforms can't run right now, or nil when they can.
    var transformUnavailableReason: String? { get }
    func transform(_ transform: TextTransform, text: String) async throws -> String
}

enum TransformAvailability {
    /// A transform needs the downloaded Thorough model. Nothing is downloaded or loaded just to preview a transform.
    static func reason(for state: CleanerState, modelName: String) -> String? {
        switch state {
        case .absent:
            return "AI transforms need the \(modelName) cleanup model. Download it in Settings, then try again."
        case .downloading:
            return "\(modelName) is still downloading."
        case let .failed(message):
            return "\(modelName) couldn’t load: \(message)"
        case .loading, .unloaded, .ready:
            return nil
        }
    }
}

/// The Thorough model's state and name, which is what Transform Selection runs on regardless of the selected cleanup level.
struct TransformModelStatus: Equatable {
    var state: CleanerState
    var modelName: String

    var unavailableReason: String? { TransformAvailability.reason(for: state, modelName: modelName) }
    var isReady: Bool { unavailableReason == nil }

    var stateWord: String {
        switch state {
        case .absent: "NOT DOWNLOADED"
        case let .downloading(fraction): "DOWNLOADING \(Int(min(max(fraction, 0), 1) * 100))%"
        case .failed: "UNAVAILABLE"
        case .loading, .unloaded, .ready: "READY"
        }
    }
}

enum TransformError: Error, Equatable { case emptyResult }
