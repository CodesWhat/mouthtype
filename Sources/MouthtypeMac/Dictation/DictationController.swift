import Foundation
import MouthtypeCore
import Observation

/// Runs dictations from the hotkey events: press starts the capture, release hands the audio to the pipeline and
/// pastes, a short tap throws it away, and Esc cancels it but keeps the audio for a few seconds so Undo can still run
/// it. A press while the last dictation is still being transcribed starts recording at once; its processing waits for
/// the earlier ones, so pastes land in the order they were spoken. Every attempt ends back at idle. A lock (double-tap
/// or Fn+Space) turns the recording hands-free: it stays in the recording phase until the next tap, Esc, the menu, or
/// the length limit. Events are handled one at a time, so a discarded tap's cancel has finished before the next press starts.
@MainActor
@Observable
final class DictationController {
    enum Phase: Equatable {
        case idle, recording, processing
    }

    /// How long one recording may run, with a warning a minute before the end, and how often a recording in progress
    /// is saved to disk.
    struct Limits: Sendable {
        var warningAfter: TimeInterval = 19 * 60
        var stopAfter: TimeInterval = 20 * 60
        var partialFlushEvery: TimeInterval = 5

        static let standard = Limits()
    }

    private(set) var phase: Phase = .idle
    private(set) var isHandsFree = false

    /// Fired after each attempt ends, whatever the outcome.
    @ObservationIgnored var onAttemptFinished: (@MainActor () -> Void)?
    @ObservationIgnored var canStartRecording: @MainActor () -> Bool = { true }
    /// Fired when a recording becomes hands-free and when it stops being, so the menu can offer Stop and Cancel.
    @ObservationIgnored var onHandsFreeChanged: (@MainActor (Bool) -> Void)?
    /// Fired when a lock ends or is refused, so the hotkey side can drop its own lock state.
    @ObservationIgnored var onLockEnded: (@MainActor () -> Void)?

    @ObservationIgnored private let preview: LivePreviewSession
    @ObservationIgnored private let previewEnabled: @MainActor () -> Bool
    @ObservationIgnored private let capture: any DictationCapturing
    @ObservationIgnored private let engine: any DictationEngine
    @ObservationIgnored private let pipeline: DictationPipeline
    @ObservationIgnored private let inserter: any DictationInserting
    @ObservationIgnored private let pill: any DictationPill
    @ObservationIgnored private let sounds: any SoundPlayer
    @ObservationIgnored private let audioQuiet: (any RecordingAudioQuieting)?
    @ObservationIgnored private let clock: any DictationClock
    @ObservationIgnored private let cards: any DictationCards
    /// Told when a paste lands and when the next dictation starts, so edits to the pasted text can be learned from.
    @ObservationIgnored weak var corrections: (any CorrectionObserving)?
    @ObservationIgnored private var session: DictationSession?
    @ObservationIgnored private var captureStarting = false
    @ObservationIgnored private var interruptedDuringStart = false
    @ObservationIgnored private var undo: PendingUndo?
    /// The last job queued. A job waits for the one before it, so the chain keeps deliveries in order.
    @ObservationIgnored private var processing: Task<Void, Never>?
    @ObservationIgnored private var pendingJobs = 0
    /// The capture's stop for the last release. The next press waits for it before the capture starts again.
    @ObservationIgnored private var stopping: Task<CapturedAudio, Error>?
    @ObservationIgnored private var capTimer: Task<Void, Never>?
    @ObservationIgnored private var pendingQuietStart: Task<Void, Never>?
    @ObservationIgnored private var flusher: Task<Void, Never>?
    @ObservationIgnored private var limitCardUp = false
    @ObservationIgnored private var interrupted: PendingInterruption?
    @ObservationIgnored private let limits: Limits
    @ObservationIgnored private var verifying: PendingVerification?

    /// A cancelled dictation whose audio is kept for `DeliveryCard.undoWindow`.
    private struct PendingUndo {
        var session: DictationSession
        var audio: CapturedAudio
        var cancelledAt: UInt64
        var timer: Task<Void, Never>
    }

    /// What a lost microphone left: the audio is already on disk, and the card offers to run it.
    private struct PendingInterruption {
        var session: DictationSession
        var audio: CapturedAudio
        var features: AudioFeatures
        var keyUpAt: UInt64
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
        cards: any DictationCards, limits: Limits = .standard, audioQuiet: (any RecordingAudioQuieting)? = nil,
        preview: LivePreviewSession = LivePreviewSession(), previewEnabled: @escaping @MainActor () -> Bool = { false }
    ) {
        self.preview = preview
        self.previewEnabled = previewEnabled
        self.limits = limits
        self.capture = capture
        self.engine = engine
        self.pipeline = pipeline
        self.inserter = inserter
        self.pill = pill
        self.sounds = sounds
        self.audioQuiet = audioQuiet
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
        capture.onInterrupted = { [weak self] in
            guard let self else { return }
            Task { await self.captureInterrupted() }
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
        guard canStartRecording() else {
            pill.showMessage(PillMessage("Mouthtype is busy", detail: "Try again in a moment"), duration: 2.5)
            return
        }
        switch phase {
        case .recording:
            return
        case .processing, .idle:
            break
        }
        switch engine.readiness {
        case .ready: break
        case .loading:
            pill.showMessage(PillMessage("Loading model", detail: "Try again in a moment"), duration: 2.5)
            return
        case .failed:
            pill.showMessage(
                PillMessage("Speech engine unavailable", detail: "Choose Retry Speech Model in the menu", isError: true), duration: 3
            )
            return
        }

        // A new dictation ends the last one's card and the Undo it offered, and the last paste's read-back. With
        // earlier dictations still queued their deliveries haven't happened yet, so there is no read-back to end. A
        // card holding a saved recording stays up: its Insert is the only way back to that audio this session.
        undo?.timer.cancel()
        undo = nil
        if interrupted == nil { cards.dismiss() }
        limitCardUp = false
        if pendingJobs == 0 {
            inserter.cancelVerification()
            verifying = nil
        }
        corrections?.dictationStarted()

        let startFocus = inserter.snapshotFocus()
        let appStyles = pipeline.appStyles()
        let cleanupStyle = appStyles.resolve(bundleID: startFocus.bundleID, fallback: pipeline.settings().style)
        // The last release's capture stop finishes first; the audio unit takes one recording at a time.
        _ = try? await stopping?.value
        var current = DictationSession(
            id: UUID().uuidString, startedAt: clock.date(atNanos: nanos), keyDownAt: nanos, startFocus: startFocus,
            cleanupStyle: cleanupStyle
        )
        phase = .recording
        captureStarting = true
        interruptedDuringStart = false

        // The capture goes first: nothing else waits ahead of it.
        var startError: Error?
        do {
            try await capture.start(keyDownAtNanos: nanos)
        } catch {
            startError = error
        }
        if startError == nil {
            sounds.playStart()
            beginQuietAfterStartCue()
            pill.showRecording()
            pipeline.smart?.recordingStarted()
            if !appStyles.websites.isEmpty {
                current.cleanupStyle = appStyles.resolve(bundleID: startFocus.bundleID,
                    websiteHost: inserter.websiteHost(for: startFocus), fallback: cleanupStyle)
            }
        }
        current.rowOpen = await pipeline.begin(current, target: startFocus.target)
        captureStarting = false
        if let startError {
            interruptedDuringStart = false
            await fail(current, startError)
            return
        }
        session = current
        if interruptedDuringStart {
            interruptedDuringStart = false
            await captureInterrupted()
        } else {
            startTimers(for: current)
        }
    }

    private func beginQuietAfterStartCue() {
        pendingQuietStart?.cancel()
        pendingQuietStart = nil
        guard let audioQuiet else { return }
        let duration = sounds.startCueDuration
        guard duration > 0 else { audioQuiet.begin(); return }
        let clock = clock
        let sounds = sounds
        pendingQuietStart = Task { [weak self] in
            do {
                try await clock.sleep(forSeconds: duration)
                // Allow a bounded playback lag beyond the decoded duration. A stuck cue skips quieting this take.
                for _ in 0..<20 {
                    guard !Task.isCancelled, self?.phase == .recording, self?.interruptedDuringStart == false else { return }
                    if !sounds.isStartCuePlaying {
                        audioQuiet.begin()
                        return
                    }
                    try await clock.sleep(forSeconds: 0.05)
                }
            } catch { return }
        }
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

    /// The length limit and the in-progress save, both running from the moment the recording starts.
    private func startTimers(for session: DictationSession) {
        if previewEnabled() {
            let capture = capture
            let engine = engine
            preview.start(source: { await capture.previewSnapshot(maxSamples: $0) }, recognize: { try await engine.preview(samples: $0) }, update: { [weak self] text in
                guard let self, self.phase == .recording, self.session?.id == session.id else { return }
                self.pill.showPreview(text)
            })
        }
        capTimer?.cancel()
        let warning = limits.warningAfter
        let remaining = max(0, limits.stopAfter - warning)
        let stopsAfter = limits.stopAfter
        let clock = clock
        capTimer = Task { [weak self] in
            do {
                try await clock.sleep(forSeconds: warning)
                self?.warnOfLimit(stopsAfter: stopsAfter)
                try await clock.sleep(forSeconds: remaining)
            } catch {
                return
            }
            self?.stopAtLimit()
        }
        guard pipeline.archive?.writesPartials == true else { return }
        let interval = limits.partialFlushEvery
        let capture = capture
        let pipeline = pipeline
        flusher = Task {
            var written = 0
            while !Task.isCancelled {
                do { try await clock.sleep(forSeconds: interval) } catch { return }
                let tail = await capture.partialSamples(from: written)
                if !tail.isEmpty, await pipeline.appendPartial(tail, session: session) { written += tail.count }
            }
        }
    }

    private func warnOfLimit(stopsAfter: TimeInterval) {
        guard phase == .recording else { return }
        limitCardUp = true
        cards.present(.limitWarning(stopsAfter: stopsAfter))
    }

    private func stopAtLimit() {
        guard phase == .recording else { return }
        released(at: clock.nowNanos())
    }

    /// Stops the timers and returns the save in progress, which finishes before anything else writes the audio.
    private func endTimers() -> Task<Void, Never>? {
        pendingQuietStart?.cancel()
        pendingQuietStart = nil
        preview.stop()
        pill.showPreview("")
        capTimer?.cancel()
        capTimer = nil
        if limitCardUp {
            limitCardUp = false
            cards.dismiss()
        }
        let saving = flusher
        saving?.cancel()
        flusher = nil
        return saving
    }

    private func endHandsFree() {
        guard isHandsFree else { return }
        isHandsFree = false
        onHandsFreeChanged?(false)
        onLockEnded?()
    }

    // MARK: Release

    private func released(at nanos: UInt64) {
        guard phase == .recording, let current = session else { return }
        session = nil
        let saving = endTimers()
        endHandsFree()
        // The stop starts now so the next press can follow it; the rest waits its turn behind earlier dictations.
        let stopped = Task {
            defer { audioQuiet?.end() }
            return try await capture.stopSalvaging()
        }
        stopping = stopped
        phase = .processing
        showProcessing()
        enqueue { [self] previous in
            await process(current, releasedAt: nanos, stopped: stopped, saving: saving, after: previous)
        }
    }

    /// Adds a job to the chain. It runs once every job before it has finished.
    private func enqueue(_ job: @escaping @MainActor (_ previous: Task<Void, Never>?) async -> Void) {
        let previous = processing
        pendingJobs += 1
        if phase != .recording { phase = .processing }
        processing = Task { [self] in
            await job(previous)
            jobFinished()
        }
    }

    private func process(
        _ session: DictationSession, releasedAt: UInt64, stopped: Task<CapturedAudio, Error>,
        saving: Task<Void, Never>?, after previous: Task<Void, Never>?
    ) async {
        do {
            // A capture cut short by the input going away still holds what was said; it goes through like any other.
            let audio = try await stopped.value
            if stopping == stopped { stopping = nil }
            sounds.playStop()
            await saving?.value
            let keyUpMs = clock.milliseconds(from: session.keyDownAt, to: releasedAt)
            let features = await pipeline.recordCapture(audio, session: session, keyUpMs: keyUpMs)
            let waits = pendingJobs > 1
            await previous?.value
            if waits { showProcessing() }
            try await transcribeAndDeliver(audio, features: features, session: session)
        } catch {
            await failJob(session, error)
        }
    }

    /// The processing pill, unless a newer recording has the pill.
    private func showProcessing() {
        if phase != .recording { pill.showProcessing() }
    }

    private func hidePill() {
        if phase != .recording { pill.hide() }
    }

    /// Everything after the audio is on disk, shared by a normal release, an Undo and a saved recording.
    private func transcribeAndDeliver(_ audio: CapturedAudio, features: AudioFeatures, session: DictationSession) async throws {
        guard let transcribed = try await pipeline.transcribe(audio, session: session, voicedMs: features.voicedMs) else {
            hidePill()
            return
        }

        let inputs = pipeline.cleanupInputs(style: session.cleanupStyle)
        let context = inputs.settings.enabled ? inserter.insertionContext() : nil
        let clipboard = inputs.needsClipboard ? inserter.clipboardText() : nil
        let destination = S1MiniControls.destination(forBundleID: session.startFocus?.bundleID)
        let cleaned = await pipeline.clean(transcribed, inputs: inputs, context: context, clipboard: clipboard, destination: destination,
                                           appName: session.startFocus?.appName)
        guard !cleaned.text.isEmpty else {
            await pipeline.finishEmpty(cleaned, session: session)
            hidePill()
            return
        }

        let result = await inserter.deliver(cleaned.text, startFocus: session.startFocus)
        // Before anything suspends: the read-back can end while the row is still being written.
        verifying = result.verificationID.map { PendingVerification(id: $0, session: session, text: result.finalText) }
        await pipeline.recordInsertion(result, session: session, cleaned: cleaned)
        if result.method == .paste, result.outcome == .unknown {
            corrections?.pasted(result.finalText, dictationID: session.id, target: result.target)
        }
        hidePill()
        if let card = DeliveryCard.forDelivery(result, transcript: cleaned.text) { cards.present(card) }
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
        guard phase != .recording, let card = DeliveryCard.forVerdict(verification.verdict, transcript: pending.text) else { return }
        cards.present(card)
    }

    // MARK: Discard and cancel

    private func discarded() async {
        guard phase == .recording, let current = session else { return }
        session = nil
        let saving = endTimers()
        await capture.cancel()
        audioQuiet?.end()
        await saving?.value
        pipeline.discardPartial(current)
        await pipeline.finish(current, .tooShort)
        pill.hide()
        finished()
    }

    /// Esc: stops the capture but keeps the audio in memory and offers Undo. The row is written as cancelled at
    /// once, so nothing is lost if the app quits during the window.
    private func cancelled() async {
        guard phase == .recording, let current = session else { return }
        session = nil
        let saving = endTimers()
        var kept: CapturedAudio?
        do {
            kept = try await capture.stop()
        } catch {
            await capture.cancel()
        }
        audioQuiet?.end()
        await saving?.value
        pipeline.discardPartial(current)
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
        guard phase == .idle, canStartRecording(), let pending = undo else { return }
        pending.timer.cancel()
        undo = nil
        enqueue { [self] _ in
            await pipeline.reopen(pending.session)
            showProcessing()
            do {
                let keyUpMs = clock.milliseconds(from: pending.session.keyDownAt, to: pending.cancelledAt)
                let features = await pipeline.recordCapture(pending.audio, session: pending.session, keyUpMs: keyUpMs)
                try await transcribeAndDeliver(pending.audio, features: features, session: pending.session)
            } catch {
                await failJob(pending.session, error)
            }
        }
        await processing?.value
    }

    // MARK: Microphone lost

    /// The input went away mid-recording. What was captured is saved to disk first, then the card offers to run it.
    private func captureInterrupted() async {
        guard phase == .recording else { return }
        // Capture and history registration both suspend before the session can own its recovery card.
        if captureStarting {
            interruptedDuringStart = true
            return
        }
        guard let current = session else { return }
        session = nil
        let saving = endTimers()
        endHandsFree()
        let keyUpAt = clock.nowNanos()
        var salvaged: CapturedAudio?
        do {
            salvaged = try await capture.stopSalvaging()
        } catch {
            Log.app.error("could not keep the interrupted capture: \(String(describing: error), privacy: .public)")
            await capture.cancel()
        }
        audioQuiet?.end()
        await saving?.value
        if salvaged?.samples.isEmpty != false {
            salvaged = await pipeline.recoverPartial(current)
        }
        sounds.playError()
        pill.hide()
        guard let audio = salvaged, !audio.samples.isEmpty else {
            await pipeline.finish(current, .failed, errorMessage: "microphone disconnected")
            pill.showMessage(PillMessage("Microphone disconnected", detail: "No audio could be recovered", isError: true), duration: 3)
            finished()
            return
        }
        let keyUpMs = clock.milliseconds(from: current.keyDownAt, to: keyUpAt)
        let features = await pipeline.recordCapture(audio, session: current, keyUpMs: keyUpMs)
        interrupted = PendingInterruption(session: current, audio: audio, features: features, keyUpAt: keyUpAt)
        Log.app.info("microphone lost mid-recording; kept \(audio.samples.count, privacy: .public) samples")
        cards.present(.micDisconnected(seconds: audio.audioMs / 1000), actions: [
            .insert: { [weak self] in Task { await self?.insertInterrupted() } },
            .discard: { [weak self] in Task { await self?.discardInterrupted() } },
        ])
        finished()
    }

    /// The card's Insert: runs the saved recording like any other and delivers wherever focus is now.
    func insertInterrupted() async {
        guard canStartRecording(), let pending = interrupted else { return }
        interrupted = nil
        enqueue { [self] previous in
            await previous?.value
            showProcessing()
            do {
                try await transcribeAndDeliver(pending.audio, features: pending.features, session: pending.session)
            } catch {
                await failJob(pending.session, error)
            }
        }
        await processing?.value
    }

    /// The card's Discard: the row ends as cancelled and the audio stays in the archive.
    func discardInterrupted() async {
        guard let pending = interrupted else { return }
        interrupted = nil
        await pipeline.finish(pending.session, .cancelled)
    }

    // MARK: Failure

    /// A recording that never got going.
    private func fail(_ session: DictationSession, _ error: Error) async {
        Log.app.error("dictation failed: \(String(describing: error), privacy: .public)")
        let saving = endTimers()
        await capture.cancel()
        await saving?.value
        pipeline.discardPartial(session)
        await pipeline.finish(session, .failed, errorMessage: String(describing: error))
        sounds.playError()
        pill.showMessage(Self.pillMessage(for: error), duration: 3)
        finished()
    }

    /// A queued dictation that failed after its capture ended. The capture may be recording something newer, so it is
    /// left alone, and so is the pill.
    private func failJob(_ session: DictationSession, _ error: Error) async {
        Log.app.error("dictation failed: \(String(describing: error), privacy: .public)")
        await pipeline.finish(session, .failed, errorMessage: String(describing: error))
        sounds.playError()
        if phase != .recording { pill.showMessage(Self.pillMessage(for: error), duration: 3) }
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
        case .selectedMicrophoneUnavailable:
            return PillMessage("Chosen microphone unavailable", detail: "Choose an input in Mouthtype Settings", isError: true)
        case .microphonePreferenceUnreadable:
            return PillMessage("Check microphone choice", detail: "Choose an input in Mouthtype Settings", isError: true)
        case .routeChanged: return PillMessage("Microphone changed", detail: "Try again", isError: true)
        case .engineStartFailed, .notRecording: return PillMessage("Couldn't record", detail: "Try again", isError: true)
        }
    }

    /// A recording ended without becoming a job.
    private func finished() {
        endHandsFree()
        session = nil
        phase = pendingJobs > 0 ? .processing : .idle
        onAttemptFinished?()
    }

    /// A queued job ended, whatever the outcome. A recording started meanwhile keeps the phase.
    private func jobFinished() {
        pendingJobs -= 1
        if phase != .recording { phase = pendingJobs > 0 ? .processing : .idle }
        onAttemptFinished?()
    }
}
