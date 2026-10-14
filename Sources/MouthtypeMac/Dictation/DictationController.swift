import Foundation
import MouthtypeCore
import Observation

/// Runs one dictation at a time from the hotkey events: press starts the capture, release hands the audio to the
/// pipeline and pastes, a short tap throws it away, and Esc cancels it but keeps the audio for a few seconds so Undo
/// can still run it. Every attempt ends back at idle. A lock (double-tap or
/// Fn+Space) turns the recording hands-free: it stays in the recording phase until the next tap, Esc, the menu, or
/// the safety cap. Events are handled one at a time, so a discarded tap's cancel has finished before the next press starts.
@MainActor
@Observable
final class DictationController {
    enum Phase: Equatable {
        case idle, recording, processing
    }

    /// A locked recording stops by itself this long after the lock, with a warning a minute before.
    static let handsFreeLimit: TimeInterval = 20 * 60
    static let handsFreeWarningAfter: TimeInterval = 19 * 60

    private(set) var phase: Phase = .idle
    private(set) var isHandsFree = false

    /// Fired after each attempt ends, whatever the outcome.
    @ObservationIgnored var onAttemptFinished: (@MainActor () -> Void)?
    /// Fired when a recording becomes hands-free and when it stops being, so the menu can offer Stop and Cancel.
    @ObservationIgnored var onHandsFreeChanged: (@MainActor (Bool) -> Void)?
    /// Fired when a lock ends or is refused, so the hotkey side can drop its own lock state.
    @ObservationIgnored var onLockEnded: (@MainActor () -> Void)?

    @ObservationIgnored private let capture: any DictationCapturing
    @ObservationIgnored private let engine: any DictationEngine
    @ObservationIgnored private let pipeline: DictationPipeline
    @ObservationIgnored private let inserter: any DictationInserting
    @ObservationIgnored private let pill: any DictationPill
    @ObservationIgnored private let sounds: any SoundPlayer
    @ObservationIgnored private let clock: any DictationClock
    @ObservationIgnored private let cards: any DictationCards
    /// Told when a paste lands and when the next dictation starts, so edits to the pasted text can be learned from.
    @ObservationIgnored weak var corrections: (any CorrectionObserving)?
    @ObservationIgnored private var session: DictationSession?
    @ObservationIgnored private var undo: PendingUndo?
    @ObservationIgnored private var processing: Task<Void, Never>?
    @ObservationIgnored private var capTimer: Task<Void, Never>?
    @ObservationIgnored private var verifying: PendingVerification?

    /// A cancelled dictation whose audio is kept for `DeliveryCard.undoWindow`.
    private struct PendingUndo {
        var session: DictationSession
        var audio: CapturedAudio
        var cancelledAt: UInt64
        var timer: Task<Void, Never>
    }

    /// A paste whose read-back hasn't ended. `arrived` holds a verdict that came before the attempt was wrapped up.
    private struct PendingVerification {
        var id: Int
        var session: DictationSession
        var text: String
        var wrappedUp = false
        var arrived: PasteVerification?
    }

    init(
        capture: any DictationCapturing, engine: any DictationEngine, pipeline: DictationPipeline,
        inserter: any DictationInserting, pill: any DictationPill, sounds: any SoundPlayer, clock: any DictationClock,
        cards: any DictationCards
    ) {
        self.capture = capture
        self.engine = engine
        self.pipeline = pipeline
        self.inserter = inserter
        self.pill = pill
        self.sounds = sounds
        self.clock = clock
        self.cards = cards
        cards.onUndo = { [weak self] in
            guard let self else { return }
            Task { await self.undoCancel() }
        }
        cards.onDismissed = { [weak self] card in
            if card.kind == .cancelled { self?.discardPendingUndo() }
        }
        inserter.observeVerification { [weak self] verification in
            self?.verificationEnded(verification)
        }
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
        case let .locked(_, trigger): await locked(trigger)
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
            pill.showMessage(PillMessage("Still working", detail: "Finishing the last dictation"), duration: 2.5)
            return
        case .idle:
            break
        }
        switch engine.readiness {
        case .ready: break
        case .loading:
            pill.showMessage(PillMessage("Loading model", detail: "Try again in a moment"), duration: 2.5)
            return
        case .failed:
            pill.showMessage(
                PillMessage("Speech engine unavailable", detail: "Restart Mouthtype to try again", isError: true), duration: 3
            )
            return
        }
        guard capture.isPrepared else {
            pill.showMessage(Self.microphoneAccessMessage, duration: 3)
            return
        }

        // A new dictation ends the last one's card and the Undo it offered, and the last paste's read-back.
        discardPendingUndo()
        inserter.cancelVerification()
        verifying = nil
        corrections?.dictationStarted()

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
            pipeline.smart?.recordingStarted()
        }
        current.rowOpen = await pipeline.begin(current, target: startFocus.target)
        if let startError {
            await fail(current, startError)
            return
        }
        session = current
    }

    // MARK: Hands-free

    private func locked(_ trigger: LockTrigger) async {
        guard phase == .recording, let current = session else {
            // The press never became a recording (engine loading, no mic), so the lock has nothing to hold.
            onLockEnded?()
            return
        }
        guard !isHandsFree else { return }
        isHandsFree = true
        sounds.playLock()
        pill.showHandsFree()
        startCapTimer()
        onHandsFreeChanged?(true)
        await pipeline.recordLock(current, trigger: trigger.dictationTrigger)
    }

    /// The menu's Stop Dictation: the same as tapping the key to end a locked recording.
    func stopHandsFree() {
        guard isHandsFree else { return }
        released(at: clock.nowNanos())
    }

    /// The menu's Cancel Dictation: the same as Esc.
    func cancelHandsFree() async {
        guard isHandsFree else { return }
        await cancelled()
    }

    private func startCapTimer() {
        capTimer?.cancel()
        let warning = Self.handsFreeWarningAfter
        let remaining = Self.handsFreeLimit - warning
        let clock = clock
        capTimer = Task { [weak self] in
            do {
                try await clock.sleep(forSeconds: warning)
                self?.pill.showHandsFreeNotice("1 minute left", duration: 4)
                try await clock.sleep(forSeconds: remaining)
            } catch {
                return
            }
            self?.stopHandsFree()
        }
    }

    private func endHandsFree() {
        capTimer?.cancel()
        capTimer = nil
        guard isHandsFree else { return }
        isHandsFree = false
        onHandsFreeChanged?(false)
        onLockEnded?()
    }

    // MARK: Release

    private func released(at nanos: UInt64) {
        guard phase == .recording, let current = session else { return }
        phase = .processing
        session = nil
        endHandsFree()
        pill.showProcessing()
        processing = Task { await process(current, releasedAt: nanos) }
    }

    private func process(_ session: DictationSession, releasedAt: UInt64) async {
        do {
            let audio = try await capture.stop()
            sounds.playStop()
            try await transcribeAndDeliver(audio, session: session, keyUpAt: releasedAt)
        } catch {
            await fail(session, error)
        }
    }

    /// Everything after the audio is in hand, shared by a normal release and an Undo.
    private func transcribeAndDeliver(_ audio: CapturedAudio, session: DictationSession, keyUpAt: UInt64) async throws {
        let keyUpMs = clock.milliseconds(from: session.keyDownAt, to: keyUpAt)
        let features = await pipeline.recordCapture(audio, session: session, keyUpMs: keyUpMs)
        guard let transcribed = try await pipeline.transcribe(audio, session: session, voicedMs: features.voicedMs) else {
            pill.hide()
            finished()
            return
        }

        let inputs = pipeline.cleanupInputs()
        let context = inputs.settings.enabled ? inserter.insertionContext() : nil
        let clipboard = inputs.needsClipboard ? inserter.clipboardText() : nil
        let destination = S1MiniControls.destination(forBundleID: session.startFocus?.bundleID)
        let cleaned = await pipeline.clean(transcribed, inputs: inputs, context: context, clipboard: clipboard, destination: destination,
                                           appName: session.startFocus?.appName)
        guard !cleaned.text.isEmpty else {
            await pipeline.finishEmpty(cleaned, session: session)
            pill.hide()
            finished()
            return
        }

        let result = await inserter.deliver(cleaned.text, startFocus: session.startFocus)
        // Before anything suspends: the read-back can end while the row is still being written.
        verifying = result.verificationID.map { PendingVerification(id: $0, session: session, text: result.finalText) }
        await pipeline.recordInsertion(result, session: session, cleaned: cleaned)
        if result.method == .paste, result.outcome == .unknown {
            corrections?.pasted(result.finalText, dictationID: session.id, target: result.target)
        }
        pill.hide()
        if let card = DeliveryCard.forDelivery(result, transcript: cleaned.text) { cards.present(card) }
        finished()
        if verifying?.id == result.verificationID {
            verifying?.wrappedUp = true
            if let arrived = verifying?.arrived { verificationEnded(arrived) }
        }
    }

    // MARK: Read-back

    /// The inserter's read-back of a paste ended. Held until the attempt is wrapped up, so the row it updates exists
    /// and the card it may raise isn't taken down by the attempt's own wrap-up.
    private func verificationEnded(_ verification: PasteVerification) {
        guard var pending = verifying, pending.id == verification.id else { return }
        guard pending.wrappedUp else {
            pending.arrived = verification
            verifying = pending
            return
        }
        verifying = nil
        let session = pending.session
        Task { await pipeline.recordVerdict(session, verification) }
        guard verification.verdict == .notLanded else { return }
        corrections?.pasteDidNotLand(dictationID: session.id)
        guard phase == .idle, let card = DeliveryCard.forVerdict(verification.verdict, transcript: pending.text) else { return }
        cards.present(card)
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

    /// Esc: stops the capture but keeps the audio in memory and offers Undo. The row is written as cancelled at
    /// once, so nothing is lost if the app quits during the window.
    private func cancelled() async {
        guard phase == .recording, let current = session else { return }
        session = nil
        var kept: CapturedAudio?
        do {
            kept = try await capture.stop()
        } catch {
            await capture.cancel()
        }
        let cancelledAt = clock.nowNanos()
        await pipeline.finish(current, .cancelled)
        pill.hide()
        if let kept {
            offerUndo(current, audio: kept, cancelledAt: cancelledAt)
        } else {
            pill.showMessage("Cancelled", duration: 2.5)
        }
        finished()
    }

    private func offerUndo(_ session: DictationSession, audio: CapturedAudio, cancelledAt: UInt64) {
        undo?.timer.cancel()
        let clock = clock
        let timer = Task { [weak self] in
            do {
                try await clock.sleep(forSeconds: DeliveryCard.undoWindow)
            } catch {
                return
            }
            self?.undoExpired()
        }
        undo = PendingUndo(session: session, audio: audio, cancelledAt: cancelledAt, timer: timer)
        cards.present(.cancelled())
    }

    private func undoExpired() {
        guard undo != nil else { return }
        undo?.timer.cancel()
        undo = nil
        cards.dismiss()
    }

    /// Throws the kept audio away and takes any card down.
    private func discardPendingUndo() {
        undo?.timer.cancel()
        undo = nil
        cards.dismiss()
    }

    /// The card's Undo: runs the normal pipeline on the kept audio and delivers wherever focus is now.
    func undoCancel() async {
        guard phase == .idle, let pending = undo else { return }
        pending.timer.cancel()
        undo = nil
        phase = .processing
        processing = Task {
            await pipeline.reopen(pending.session)
            pill.showProcessing()
            do {
                try await transcribeAndDeliver(pending.audio, session: pending.session, keyUpAt: pending.cancelledAt)
            } catch {
                await fail(pending.session, error)
            }
        }
        await processing?.value
    }

    // MARK: Failure

    private func fail(_ session: DictationSession, _ error: Error) async {
        Log.app.error("dictation failed: \(String(describing: error), privacy: .public)")
        await capture.cancel()
        await pipeline.finish(session, .failed, errorMessage: String(describing: error))
        sounds.playError()
        pill.showMessage(Self.pillMessage(for: error), duration: 3)
        finished()
    }

    static let microphoneAccessMessage = PillMessage(
        "Microphone access needed", detail: "Allow it in System Settings", isError: true
    )

    static func pillMessage(for error: Error) -> PillMessage {
        guard let error = error as? CaptureError else {
            return PillMessage("Transcription failed", detail: "Try again", isError: true)
        }
        switch error {
        case .microphoneDenied, .microphonePending: return microphoneAccessMessage
        case .noInputDevice, .invalidInputFormat:
            return PillMessage("No microphone found", detail: "Connect one and try again", isError: true)
        case .routeChanged: return PillMessage("Microphone changed", detail: "Try again", isError: true)
        case .engineStartFailed, .notRecording: return PillMessage("Couldn't record", detail: "Try again", isError: true)
        }
    }

    private func finished() {
        endHandsFree()
        session = nil
        phase = .idle
        onAttemptFinished?()
    }
}
