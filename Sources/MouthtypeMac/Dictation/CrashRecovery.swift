import Foundation
import Observation
import MouthtypeCore

/// At launch, offers the newest dictation a crash or quit cut off, if its audio is still on disk. Recover runs the
/// audio through the normal transcribe and clean steps and shows the text on a card with Copy; it never pastes, since
/// the focus at launch isn't where the dictation was meant to go. Every row found is ended as failed ("interrupted")
/// before anything is offered, so no later launch offers it again.
@MainActor
@Observable
final class CrashRecovery {
    private let store: TranscriptStore
    private let archive: AudioArchive
    private let pipeline: DictationPipeline
    private let cards: any DictationCards
    private let pill: any DictationPill
    private let clock: any DictationClock
    private let launchedAt: Date
    private(set) var offered: RecoverableDictation?
    private(set) var isRecovering = false
    var onFinished: (@MainActor () -> Void)?
    var canRecover: @MainActor () -> Bool = { true }

    init(
        store: TranscriptStore, archive: AudioArchive, pipeline: DictationPipeline, cards: any DictationCards,
        pill: any DictationPill, clock: any DictationClock, launchedAt: Date
    ) {
        self.store = store
        self.archive = archive
        self.pipeline = pipeline
        self.cards = cards
        self.pill = pill
        self.clock = clock
        self.launchedAt = launchedAt
    }

    /// Looks once; raises the card for the newest recoverable dictation. Returns what the scan found.
    @discardableResult
    func offerIfNeeded() async -> RecoveryScan? {
        let store = store, archive = archive, launchedAt = launchedAt, now = clock.now()
        let scan: RecoveryScan
        do {
            scan = try await Task.detached {
                try DictationRecovery.scan(store: store, archive: archive, now: now, launchedAt: launchedAt)
            }.value
        } catch {
            Log.app.error("recovery scan failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        Log.app.info("recovery: \(scan.newest == nil ? "nothing" : "1") to offer, \(scan.olderCount) older kept, \(scan.lostCount) without audio")
        guard let newest = scan.newest else { return scan }
        offered = newest
        cards.present(
            .recoverOffer(seconds: newest.seconds, ago: max(0, now.timeIntervalSince(newest.startedAt)), older: scan.olderCount),
            actions: [
                .recover: { [weak self] in Task { await self?.recover() } },
                .discard: { [weak self] in Task { await self?.discard() } },
            ]
        )
        return scan
    }

    /// The card's Recover.
    func recover() async {
        guard !isRecovering, let item = offered else { return }
        guard canRecover() else {
            presentOffer(item, header: "Recovery is waiting\nFinish dictating or retry the speech model first.")
            return
        }
        isRecovering = true
        defer { isRecovering = false; onFinished?() }
        offered = nil
        let session = DictationSession(id: item.id, startedAt: item.startedAt, keyDownAt: clock.nowNanos(), rowOpen: true)
        pill.showProcessing()
        do {
            let url = item.audioURL
            let samples = try await Task.detached { try AudioArchive.read(contentsOf: url) }.value
            let audioMs = Double(samples.count) * 1000 / AudioCapture.targetSampleRate
            let audio = CapturedAudio(
                samples: samples, sampleRate: AudioCapture.targetSampleRate, deviceUID: nil, deviceName: nil,
                deviceTransport: "recovered", firstSampleMs: 0, firstNonzeroMs: 0, captureStartMs: 0, audioMs: audioMs
            )
            var voicedMs: Double?
            if item.isPartial {
                // Only the in-progress copy exists: write the archived WAV and the capture fields it never got.
                voicedMs = await pipeline.recordCapture(audio, session: session, keyUpMs: Int(audioMs.rounded())).voicedMs
            } else {
                voicedMs = AudioFeatures.compute(samples: samples, sampleRate: Int(AudioCapture.targetSampleRate)).voicedMs
            }
            guard let transcribed = try await pipeline.transcribe(audio, session: session, voicedMs: voicedMs) else {
                pill.showMessage(PillMessage("Nothing to recover", detail: "No speech in the audio"), duration: 3)
                return
            }
            let cleaned = await pipeline.clean(transcribed, inputs: pipeline.cleanupInputs(), context: nil, clipboard: nil)
            guard !cleaned.text.isEmpty else {
                await pipeline.finishEmpty(cleaned, session: session)
                pill.showMessage(PillMessage("Nothing to recover", detail: "No speech in the audio"), duration: 3)
                return
            }
            await pipeline.recordInsertion(
                DeliveryResult(method: .none, outcome: .unknown, focusMoved: false, target: nil, finalText: cleaned.text),
                session: session, cleaned: cleaned
            )
            pill.hide()
            cards.present(.recovered(cleaned.text))
        } catch {
            Log.app.error("recovery failed: \(String(describing: error), privacy: .public)")
            await pipeline.finish(session, .failed, errorMessage: DictationRecovery.interruptedMessage)
            pill.showMessage(PillMessage("Couldn't recover", detail: "The audio is kept", isError: true), duration: 3)
            var retry = item
            let archived = archive.url(for: item.id)
            if FileManager.default.fileExists(atPath: archived.path) {
                retry.audioURL = archived
                retry.isPartial = false
            }
            offered = retry
            presentOffer(retry, header: "Couldn't recover\nThe audio is kept. Try Recover again.")
        }
    }

    func savedRecordings() throws -> [RecoverableDictation] {
        try DictationRecovery.saved(store: store, archive: archive, now: clock.now(), launchedAt: launchedAt)
    }

    func offerSaved(_ item: RecoverableDictation) {
        guard !isRecovering else { return }
        offered = item
        presentOffer(item, header: "Recover a saved dictation?\n\(DeliveryCard.durationText(item.seconds))")
    }

    private func presentOffer(_ item: RecoverableDictation, header: String) {
        var card = DeliveryCard.recoverOffer(seconds: item.seconds, ago: max(0, clock.now().timeIntervalSince(item.startedAt)), older: 0)
        card.header = header
        cards.present(card, actions: [
            .recover: { [weak self] in Task { await self?.recover() } },
            .discard: { [weak self] in Task { await self?.discard() } },
        ])
    }

    /// The card's Discard: the row ends as cancelled and the audio stays in the archive.
    func discard() async {
        guard let item = offered else { return }
        offered = nil
        await pipeline.finish(
            DictationSession(id: item.id, startedAt: item.startedAt, keyDownAt: clock.nowNanos(), rowOpen: true), .cancelled
        )
        onFinished?()
    }
}
