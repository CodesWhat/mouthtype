import Foundation

public enum EnginePreparation: Sendable, Equatable {
    case downloading(fraction: Double)
    /// Download progress with bytes, for engines that know their model sizes.
    case progress(ModelDownloadProgress)
    /// The model files are already on disk, so nothing is fetched.
    case cached
    case compiling
    case loadingModel
}

public protocol PreparationReporting: Transcriber {
    func prepare(report: @escaping @Sendable (EnginePreparation) async -> Void) async throws
}
