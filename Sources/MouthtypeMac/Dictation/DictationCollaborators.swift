import Foundation
import MouthtypeCore

// The seams the controller and pipeline run against, so the sequencing is tested with fakes.

@MainActor
protocol DictationCapturing: AnyObject {
    /// False until the audio unit is built, which needs microphone access.
    var isPrepared: Bool { get }
    func start(keyDownAt: UInt64) async throws
    func stop() async throws -> CapturedAudio
    func cancel() async
}

enum EngineReadiness: Equatable {
    case ready, loading, failed
}

@MainActor
protocol DictationEngine: AnyObject, Sendable {
    var readiness: EngineReadiness { get }
    func transcribe(samples: [Float]) async throws -> Transcription
}

/// Every write is async so a real store keeps its blocking database calls off the main actor.
protocol DictationStoring: Sendable {
    func begin(_ start: DictationStart) async throws
    func recordCapture(_ id: String, _ record: CaptureRecord) async throws
    func recordTranscription(_ id: String, _ record: TranscriptionRecord) async throws
    func recordInsertion(_ id: String, _ record: InsertionRecord) async throws
    func finish(_ id: String, status: DictationStatus, errorMessage: String?) async throws
}

protocol DictationArchiving: Sendable {
    /// Writes the WAV and returns where it landed.
    func archive(samples: [Float], id: String) throws -> URL
}

@MainActor
protocol DictationInserting: AnyObject {
    func snapshotFocus() -> FocusSnapshot
    func deliver(_ text: String, startFocus: FocusSnapshot?) async -> DeliveryResult
}

@MainActor
protocol DictationPill: AnyObject {
    func showRecording()
    func showProcessing()
    func showMessage(_ text: String, duration: TimeInterval)
    func hide()
}

protocol DictationClock: Sendable {
    /// Raw host time, the unit `HotkeyEvent` carries.
    func hostTimeNow() -> UInt64
    /// Whole ms between two host times, never negative.
    func milliseconds(from start: UInt64, to end: UInt64) -> Int
    func now() -> Date
    /// The wall-clock moment a host time happened.
    func date(atHostTime hostTime: UInt64) -> Date
}

// MARK: - Real collaborators

@MainActor
final class MicCapture: DictationCapturing {
    let capture: AudioCapture
    private(set) var isPrepared = false

    init(capture: AudioCapture = AudioCapture()) {
        self.capture = capture
    }

    func prepare() async throws {
        try await capture.prepare()
        isPrepared = true
    }

    func start(keyDownAt: UInt64) async throws { try await capture.start(keyDownAt: keyDownAt) }
    func stop() async throws -> CapturedAudio { try await capture.stop() }
    func cancel() async { await capture.cancel() }
}

/// The engine `EngineHost` loads. Transcription itself runs on the engine's own executor, not the main actor.
@MainActor
final class HostEngine: DictationEngine {
    private let host: EngineHost

    init(host: EngineHost) {
        self.host = host
    }

    var readiness: EngineReadiness {
        switch host.state {
        case .ready: .ready
        case .loading: .loading
        case .failed: .failed
        }
    }

    func transcribe(samples: [Float]) async throws -> Transcription {
        guard let engine = host.engine else { throw EngineError.notPrepared(id: EngineHost.defaultEngineID) }
        return try await engine.transcribe(samples: samples)
    }
}

struct TranscriptStoreWriter: DictationStoring {
    let store: TranscriptStore

    func begin(_ start: DictationStart) async throws { try store.begin(start) }
    func recordCapture(_ id: String, _ record: CaptureRecord) async throws { try store.recordCapture(id, record) }
    func recordTranscription(_ id: String, _ record: TranscriptionRecord) async throws {
        try store.recordTranscription(id, record)
    }
    func recordInsertion(_ id: String, _ record: InsertionRecord) async throws { try store.recordInsertion(id, record) }
    func finish(_ id: String, status: DictationStatus, errorMessage: String?) async throws {
        try store.finish(id, status: status, errorMessage: errorMessage)
    }
}

extension AudioArchive: DictationArchiving {
    func archive(samples: [Float], id: String) throws -> URL {
        try write(samples: samples, id: id).url
    }
}
extension TextInserter: DictationInserting {}
extension PillController: DictationPill {}

struct SystemDictationClock: DictationClock {
    func hostTimeNow() -> UInt64 { HostClock.hostTimeNow() }

    func milliseconds(from start: UInt64, to end: UInt64) -> Int {
        let seconds = HostClock.seconds(
            from: HostClock.nanoseconds(fromHostTime: start), to: HostClock.nanoseconds(fromHostTime: end)
        )
        return max(0, Int((seconds * 1000).rounded()))
    }

    func now() -> Date { Date() }

    func date(atHostTime hostTime: UInt64) -> Date {
        let ago = HostClock.seconds(from: HostClock.nanoseconds(fromHostTime: hostTime), to: HostClock.now())
        return Date().addingTimeInterval(-max(0, ago))
    }
}
