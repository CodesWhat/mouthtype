import Foundation

/// Which cleanup path a dictation uses. `off` delivers the engine's text, `basic` is the deterministic pipeline,
/// `light` and `medium` add the local model on top of it.
public enum CleanupLevel: String, Sendable, Equatable, CaseIterable {
    case off, basic, light, medium

    public var needsModel: Bool { self == .light || self == .medium }

    public var title: String {
        switch self {
        case .off: "Off"
        case .basic: "Basic"
        case .light: "Fast"
        case .medium: "Thorough"
        }
    }
}
