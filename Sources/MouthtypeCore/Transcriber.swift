import Foundation

public protocol Transcriber: Sendable {
    var id: String { get }                 // stable slug, e.g. "parakeet-tdt-v3"
    var displayName: String { get }
    func prepare() async throws            // download if needed + load; idempotent
    func transcribe(samples: [Float]) async throws -> Transcription   // 16 kHz mono Float32, -1...1
}

public struct PrepareTimings: Sendable, Codable, Equatable {
    public var downloadSeconds: Double
    public var loadSeconds: Double
    /// False when the model files were already on disk before this call.
    public var downloaded: Bool

    public init(downloadSeconds: Double, loadSeconds: Double, downloaded: Bool) {
        self.downloadSeconds = downloadSeconds
        self.loadSeconds = loadSeconds
        self.downloaded = downloaded
    }
}

/// Implemented by engines that can report where `prepare()` spent its time and where the model lives.
public protocol MeasuredTranscriber: Transcriber {
    var modelDirectory: URL { get }
    func prepareMeasured() async throws -> PrepareTimings
}

public enum EngineError: Error, LocalizedError {
    case notPrepared(id: String)

    public var errorDescription: String? {
        switch self {
        case let .notPrepared(id): return "Engine '\(id)' used before prepare()"
        }
    }
}
