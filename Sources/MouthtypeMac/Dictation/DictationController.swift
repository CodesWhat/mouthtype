import Foundation
import MouthtypeCore
import Observation

/// Runs one dictation at a time from the hotkey events: press starts the capture, release hands the audio to the
/// pipeline and pastes, a short tap or Esc throws it away. Every attempt ends back at idle.
@MainActor
@Observable
final class DictationController {
    enum Phase: Equatable {
        case idle, recording, processing
    }

    private(set) var phase: Phase = .idle

    /// Fired after each attempt ends, whatever the outcome.
    @ObservationIgnored var onAttemptFinished: (@MainActor () -> Void)?

    @ObservationIgnored private let capture: any DictationCapturing
    @ObservationIgnored private let engine: any DictationEngine
    @ObservationIgnored private let pipeline: DictationPipeline
    @ObservationIgnored private let inserter: any DictationInserting
    @ObservationIgnored private let pill: any DictationPill
    @ObservationIgnored private let sounds: any SoundPlayer
    @ObservationIgnored private let clock: any DictationClock
    @ObservationIgnored private var session: DictationSession?
    @ObservationIgnored private var processing: Task<Void, Never>?

    init(
        capture: any DictationCapturing, engine: any DictationEngine, pipeline: DictationPipeline,
        inserter: any DictationInserting, pill: any DictationPill, sounds: any SoundPlayer, clock: any DictationClock
    ) {
        self.capture = capture
        self.engine = engine
        self.pipeline = pipeline
        self.inserter = inserter
        self.pill = pill
        self.sounds = sounds
        self.clock = clock
    }

    func consume(_ events: AsyncStream<HotkeyEvent>) async {
        for await event in events {
            Log.hotkey.info("event \(String(describing: event), privacy: .public)")
            await handle(event)
        }
    }

    func handle(_ event: HotkeyEvent) async {
        switch event {
        case let .pressed(nanos): await pressed(at: nanos)
        case let .released(nanos): released(at: nanos)
        case .discarded: await discarded()
        case .cancelled: await cancelled()
        }
    }

    /// Returns when the current release has been fully processed. For tests and the self-test.
    func waitForProcessing() async {
        await processing?.value
    }

    // MARK: Press

    private func pressed(at nanos: UInt64) async {
        switch phase {
        case .recording:
            return
        case .processing:
            pill.showMessage("Still working on the last one", duration: 2.5)
            return
        case .idle:
            break
        }
        switch engine.readiness {
        case .ready: break
        case .loading:
            pill.showMessage("Loading model\u{2026}", duration: 2.5)
            return
        case .failed:
            pill.showMessage("Speech engine unavailable", duration: 2.5)
            return
        }
        guard capture.isPrepared else {
            pill.showMessage("Microphone access needed", duration: 2.5)
            return
        }

        let startFocus = inserter.snapshotFocus()
        var current = DictationSession(
            id: UUID().uuidString, startedAt: clock.date(atNanos: nanos), keyDownAt: nanos, startFocus: startFocus
        )
        phase = .recording

        // The capture goes first: nothing else waits ahead of it.
        var startError: Error?
        do {
            try await capture.start(keyDownAtNanos: nanos)
        } catch {
            startError = error
        }
        if startError == nil {
            sounds.playStart()
            pill.showRecording()
        }
        current.rowOpen = await pipeline.begin(current, target: startFocus.target)
        if let startError {
            await fail(current, startError)
            return
        }
        session = current
    }

    // MARK: Release

    private func released(at nanos: UInt64) {
        guard phase == .recording, let current = session else { return }
        phase = .processing
        session = nil
        processing = Task { await process(current, releasedAt: nanos) }
    }

    private func process(_ session: DictationSession, releasedAt: UInt64) async {
        do {
            let audio = try await capture.stop()
            sounds.playStop()
            pill.showProcessing()

            let keyUpMs = clock.milliseconds(from: session.keyDownAt, to: releasedAt)
            _ = await pipeline.recordCapture(audio, session: session, keyUpMs: keyUpMs)
            guard let transcribed = try await pipeline.transcribe(audio, session: session) else {
                pill.hide()
                finished()
                return
            }

            let result = await inserter.deliver(transcribed.text, startFocus: session.startFocus)
            await pipeline.recordInsertion(result, session: session)
            if let message = result.userMessage {
                pill.showMessage(message, duration: 2.5)
            } else {
                pill.hide()
            }
            finished()
        } catch {
            await fail(session, error)
        }
    }

    // MARK: Discard and cancel

    private func discarded() async {
        guard phase == .recording, let current = session else { return }
        session = nil
        await capture.cancel()
        await pipeline.finish(current, .tooShort)
        pill.hide()
        finished()
    }

    private func cancelled() async {
        guard phase == .recording, let current = session else { return }
        session = nil
        await capture.cancel()
        await pipeline.finish(current, .cancelled)
        pill.showMessage("Cancelled", duration: 2.5)
        finished()
    }

    // MARK: Failure

    private func fail(_ session: DictationSession, _ error: Error) async {
        Log.app.error("dictation failed: \(String(describing: error), privacy: .public)")
        await capture.cancel()
        await pipeline.finish(session, .failed, errorMessage: String(describing: error))
        sounds.playError()
        pill.showMessage(Self.userMessage(for: error), duration: 2.5)
        finished()
    }

    static func userMessage(for error: Error) -> String {
        guard let error = error as? CaptureError else { return "Transcription failed" }
        switch error {
        case .microphoneDenied, .microphonePending: return "Microphone access needed"
        case .noInputDevice, .invalidInputFormat: return "No microphone found"
        case .routeChanged: return "Microphone changed, try again"
        case .engineStartFailed, .notRecording: return "Couldn't record"
        }
    }

    private func finished() {
        session = nil
        phase = .idle
        onAttemptFinished?()
    }
}
