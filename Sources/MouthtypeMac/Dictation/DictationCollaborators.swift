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
    /// The same with the take's language. Engines that take a hint override this; the default ignores it.
    func transcribe(samples: [Float], language: DictationLanguageRequest) async throws -> Transcription
    func preview(samples: [Float]) async throws -> String?
    func preview(samples: [Float], language: DictationLanguageRequest) async throws -> String?
    func setVocabularyBias(_ bias: VocabularyBias?) async
    /// `settleWithin` is how long a changed vocabulary may hold the call for the engine's model. Nil never waits.
    func setVocabularyBias(_ bias: VocabularyBias?, settleWithin: Duration?) async
}

extension DictationEngine {
    func preview(samples: [Float]) async throws -> String? { nil }
    func transcribe(samples: [Float], language: DictationLanguageRequest) async throws -> Transcription {
        try await transcribe(samples: samples)
    }
    func preview(samples: [Float], language: DictationLanguageRequest) async throws -> String? {
        try await preview(samples: samples)
    }
    /// Engines without a recognition-time hook ignore the bias.
    func setVocabularyBias(_ bias: VocabularyBias?) async {}
    func setVocabularyBias(_ bias: VocabularyBias?, settleWithin: Duration?) async {
        await setVocabularyBias(bias)
    }
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
    func snapshotApplication() -> FocusSnapshot
    func snapshotFocus() -> FocusSnapshot
    /// See `FocusReading.websiteHostReader`. The returned closure blocks, so it is run off the main actor.
    func websiteHostReader(for snapshot: FocusSnapshot) -> (@Sendable () -> String?)?
    func deliver(_ text: String, startFocus: FocusSnapshot?) async -> DeliveryResult
    /// A little text either side of the cursor for the cleanup pass, or nil when it can't be read.
    func insertionContext() -> InsertionContext?
    /// The clipboard's text, for snippets that use `{clipboard}`.
    func clipboardText() -> String?
    /// Hears how the read-back of each paste ended, on the main actor.
    func observeVerification(_ handler: @escaping @MainActor (PasteVerification) -> Void)
    /// Drops any read-back still waiting.
    func cancelVerification()
    /// Queues a Return for the app `result` was pasted into, sent only if the read-back confirms the paste landed and the user
    /// opted the app in. Only a normal take asks.
    func pressReturnAfterInsert(for result: DeliveryResult) async
    /// Drops any Return still waiting on a verdict.
    func cancelPendingReturn()
}

extension DictationInserting {
    func snapshotApplication() -> FocusSnapshot { snapshotFocus() }
    func websiteHostReader(for snapshot: FocusSnapshot) -> (@Sendable () -> String?)? { nil }
    func observeVerification(_ handler: @escaping @MainActor (PasteVerification) -> Void) {}
    func cancelVerification() {}
    func pressReturnAfterInsert(for result: DeliveryResult) async {}
    func cancelPendingReturn() {}
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
    /// The line shown under a delivery card, held until `hideCardMessage`.
    func showCardMessage(_ message: PillMessage)
    /// Takes the pill down only if it is still showing the card's line.
    func hideCardMessage()
    /// True while the pill is showing a card's line.
    var cardHeld: Bool { get }
    func hide()
}

extension DictationPill {
    func showPreview(_ text: String) {}
    func showCardMessage(_ message: PillMessage) {}
    func hideCardMessage() {}
    var cardHeld: Bool { false }
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
    let preparation = MicrophonePreparation()
    var isPrepared: Bool { preparation.isPrepared }

    init(capture: AudioCapture = AudioCapture()) {
        self.capture = capture
    }

    @discardableResult func prepare() async throws -> Bool {
        try await preparation.prepare { try await self.capture.prepare() }
    }

    func invalidatePreparation() { preparation.invalidate() }

    func start(keyDownAtNanos: UInt64) async throws {
        try await preparation.start {
            await capture.setInterruptionHandler(
                CaptureInterruption.hop { [weak self] in
                    self?.preparation.invalidate()
                    self?.onInterrupted?()
                })
            try await capture.start(keyDownAtNanos: keyDownAtNanos)
        }
    }
    func stop() async throws -> CapturedAudio { try await capture.stop() }
    func stopSalvaging() async throws -> CapturedAudio { try await capture.stop(salvaging: true) }
    func partialSamples(from offset: Int) async -> [Float] { await capture.partialSamples(from: offset) }
    func previewSnapshot(maxSamples: Int) async -> PreviewAudio { await capture.previewSnapshot(maxSamples: maxSamples) }
    func cancel() async { await capture.cancel() }

    var onInterrupted: (@MainActor () -> Void)?
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
        try await transcribe(samples: samples, language: .english)
    }

    func transcribe(samples: [Float], language: DictationLanguageRequest) async throws -> Transcription {
        guard let engine = host.preparedEngine(for: language) else { throw EngineError.notPrepared(id: language.speechEngineID) }
        return try await engine.transcribe(samples: samples, language: language)
    }

    func setVocabularyBias(_ bias: VocabularyBias?) async {
        for case let biasing as any VocabularyBiasing in host.preparedEngines {
            await biasing.setVocabularyBias(bias)
        }
    }

    func setVocabularyBias(_ bias: VocabularyBias?, settleWithin: Duration?) async {
        for case let biasing as any VocabularyBiasing in host.preparedEngines {
            await biasing.setVocabularyBias(bias, settleWithin: settleWithin)
        }
    }

    func preview(samples: [Float]) async throws -> String? {
        try await preview(samples: samples, language: .english)
    }

    func preview(samples: [Float], language: DictationLanguageRequest) async throws -> String? {
        guard let preview = host.preparedEngine(for: language) as? any SpeechPreview else { return nil }
        return try await preview.preview(samples: samples, language: language)
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
extension TextInserter: DictationInserting {
    func pressReturnAfterInsert(for result: DeliveryResult) async { armReturn(after: result) }
}
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
