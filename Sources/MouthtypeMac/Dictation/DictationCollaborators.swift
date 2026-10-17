import Foundation
import MouthtypeCore

// The seams the controller and pipeline run against, so the sequencing is tested with fakes.

@MainActor
protocol DictationCapturing: AnyObject {
    /// False until the audio unit is built, which needs microphone access.
    var isPrepared: Bool { get }
    func start(keyDownAtNanos: UInt64) async throws
    func stop() async throws -> CapturedAudio
    /// Like `stop`, but a capture cut short by the input going away is returned instead of thrown.
    func stopSalvaging() async throws -> CapturedAudio
    /// What the recording in progress has captured from sample `offset` on.
    func partialSamples(from offset: Int) async -> [Float]
    func previewSnapshot(maxSamples: Int) async -> PreviewAudio
    func cancel() async
    /// Fired on the main actor when the input is lost mid-recording.
    var onInterrupted: (@MainActor () -> Void)? { get set }
}

extension DictationCapturing {
    func previewSnapshot(maxSamples: Int) async -> PreviewAudio { PreviewAudio(samples: [], capturedSampleCount: 0) }
    func stopSalvaging() async throws -> CapturedAudio { try await stop() }
    func partialSamples(from offset: Int) async -> [Float] { [] }
    var onInterrupted: (@MainActor () -> Void)? {
        get { nil }
        set {}
    }
}

enum EngineReadiness: Equatable {
    case ready, loading, failed
}

@MainActor
protocol DictationEngine: AnyObject, Sendable {
    var readiness: EngineReadiness { get }
    func transcribe(samples: [Float]) async throws -> Transcription
    func preview(samples: [Float]) async throws -> String?
}

extension DictationEngine {
    func preview(samples: [Float]) async throws -> String? { nil }
}

/// Every write is async so a real store keeps its blocking database calls off the main actor.
protocol DictationStoring: Sendable {
    func begin(_ start: DictationStart) async throws
    func recordCapture(_ id: String, _ record: CaptureRecord) async throws
    func recordTranscription(_ id: String, _ record: TranscriptionRecord) async throws
    func recordInsertion(_ id: String, _ record: InsertionRecord) async throws
    /// The read-back verdict for an insertion already written, with the paste receipt time if the target gave one.
    func recordInsertVerdict(_ id: String, outcome: String, pasteReceiptMs: Int?) async throws
    func recordLock(_ id: String, mode: DictationMode, trigger: DictationTrigger) async throws
    /// A cancelled row goes back to started, for an Undo that runs it after all.
    func reopen(_ id: String) async throws
    func finish(_ id: String, status: DictationStatus, errorMessage: String?) async throws
    func appendEdits(_ id: String, _ edits: [EditOp]) async throws
}

protocol DictationArchiving: Sendable {
    /// Writes the WAV and returns where it landed.
    func archive(samples: [Float], id: String) throws -> URL
    /// Whether a recording in progress is saved as it goes.
    var writesPartials: Bool { get }
    func appendPartial(samples: [Float], id: String) throws
    func readPartial(id: String) throws -> [Float]
    func discardPartial(id: String)
}

extension DictationArchiving {
    var writesPartials: Bool { false }
    func appendPartial(samples: [Float], id: String) throws {}
    func readPartial(id: String) throws -> [Float] { [] }
    func discardPartial(id: String) {}
}

@MainActor
protocol DictationInserting: AnyObject {
    func snapshotFocus() -> FocusSnapshot
    func deliver(_ text: String, startFocus: FocusSnapshot?) async -> DeliveryResult
    /// A little text either side of the cursor for the cleanup pass, or nil when it can't be read.
    func insertionContext() -> InsertionContext?
    /// The clipboard's text, for snippets that use `{clipboard}`.
    func clipboardText() -> String?
    /// Hears how the read-back of each paste ended, on the main actor.
    func observeVerification(_ handler: @escaping @MainActor (PasteVerification) -> Void)
    /// Drops any read-back still waiting.
    func cancelVerification()
}

extension DictationInserting {
    func observeVerification(_ handler: @escaping @MainActor (PasteVerification) -> Void) {}
    func cancelVerification() {}
    func insertionContext() -> InsertionContext? { nil }
    func clipboardText() -> String? { nil }
}

@MainActor
protocol DictationPill: AnyObject {
    func showRecording()
    /// The locked flavour of the recording pill.
    func showHandsFree()
    /// A line over a locked recording that gives way to the hands-free pill again.
    func showHandsFreeNotice(_ text: String, duration: TimeInterval)
    func showPreview(_ text: String)
    func showProcessing()
    func showMessage(_ message: PillMessage, duration: TimeInterval)
    func hide()
}

extension DictationPill {
    func showPreview(_ text: String) {}
    func showMessage(_ text: String, duration: TimeInterval) {
        showMessage(PillMessage(text), duration: duration)
    }
}

protocol DictationClock: Sendable {
    /// Now in host nanoseconds, the unit `HotkeyEvent` carries.
    func nowNanos() -> UInt64
    /// Whole ms between two host-nanosecond times, never negative.
    func milliseconds(from start: UInt64, to end: UInt64) -> Int
    func now() -> Date
    /// The wall-clock moment a host-nanosecond time happened.
    func date(atNanos nanos: UInt64) -> Date
    /// Suspends for `seconds`, ending early with an error if the task is cancelled.
    func sleep(forSeconds seconds: TimeInterval) async throws
}

// MARK: - Real collaborators

@MainActor
final class MicCapture: DictationCapturing {
    let capture: AudioCapture
    private let preparation = MicrophonePreparation()
    var isPrepared: Bool { preparation.isPrepared }

    init(capture: AudioCapture = AudioCapture()) {
        self.capture = capture
    }

    @discardableResult func prepare() async throws -> Bool {
        try await preparation.prepare { try await self.capture.prepare() }
    }

    func invalidatePreparation() { preparation.invalidate() }

    func start(keyDownAtNanos: UInt64) async throws { try await capture.start(keyDownAtNanos: keyDownAtNanos) }
    func stop() async throws -> CapturedAudio { try await capture.stop() }
    func stopSalvaging() async throws -> CapturedAudio { try await capture.stop(salvaging: true) }
    func partialSamples(from offset: Int) async -> [Float] { await capture.partialSamples(from: offset) }
    func previewSnapshot(maxSamples: Int) async -> PreviewAudio { await capture.previewSnapshot(maxSamples: maxSamples) }
    func cancel() async { await capture.cancel() }

    var onInterrupted: (@MainActor () -> Void)? {
        didSet {
            let handler = onInterrupted.map(CaptureInterruption.hop)
            let capture = capture
            Task { await capture.setInterruptionHandler(handler) }
        }
    }
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

    func preview(samples: [Float]) async throws -> String? {
        guard let preview = host.engine as? any SpeechPreview else { return nil }
        return try await preview.preview(samples: samples)
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
    func recordInsertVerdict(_ id: String, outcome: String, pasteReceiptMs: Int?) async throws {
        try store.recordInsertVerdict(id, outcome: outcome, pasteReceiptMs: pasteReceiptMs)
    }
    func recordLock(_ id: String, mode: DictationMode, trigger: DictationTrigger) async throws {
        try store.recordLock(id, mode: mode, trigger: trigger)
    }
    func reopen(_ id: String) async throws { try store.reopen(id) }
    func finish(_ id: String, status: DictationStatus, errorMessage: String?) async throws {
        try store.finish(id, status: status, errorMessage: errorMessage)
    }
    func appendEdits(_ id: String, _ edits: [EditOp]) async throws { try store.appendEdits(id, edits) }
}

extension AudioArchive: DictationArchiving {
    func archive(samples: [Float], id: String) throws -> URL {
        try write(samples: samples, id: id).url
    }

    var writesPartials: Bool { true }

    func readPartial(id: String) throws -> [Float] {
        let url = partialURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try Self.read(contentsOf: url)
    }
}
extension TextInserter: DictationInserting {}
extension PillController: DictationPill {}

struct SystemDictationClock: DictationClock {
    func nowNanos() -> UInt64 { HostClock.now() }

    func milliseconds(from start: UInt64, to end: UInt64) -> Int {
        let seconds = HostClock.seconds(from: start, to: end)
        return max(0, Int((seconds * 1000).rounded()))
    }

    func now() -> Date { Date() }

    func date(atNanos nanos: UInt64) -> Date {
        let ago = HostClock.seconds(from: nanos, to: HostClock.now())
        return Date().addingTimeInterval(-max(0, ago))
    }

    func sleep(forSeconds seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}
