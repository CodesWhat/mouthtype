import Foundation

public enum EnginePreparation: Sendable, Equatable {
    case downloading(fraction: Double)
    case compiling
    case loadingModel
}

public protocol PreparationReporting: Transcriber {
    func prepare(report: @escaping @Sendable (EnginePreparation) async -> Void) async throws
}
