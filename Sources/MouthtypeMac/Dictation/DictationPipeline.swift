import Foundation
import MouthtypeCore

/// One dictation's identity and key-down anchor. Every stage time is ms from `keyDownAt`.
struct DictationSession: Sendable {
    var id: String
    var startedAt: Date
    var keyDownAt: UInt64 // host nanoseconds (`HostClock`)
    var startFocus: FocusSnapshot?
    /// False when the store is missing or `begin` failed; later writes are then skipped.
    var rowOpen = false
}

struct TranscribedDictation: Sendable {
    /// What the cleanup pass starts from: the engine's text after the guard.
    var text: String
    /// The engine's text exactly.
    var rawText: String
    var asrDoneMs: Int
    var words: [WordTiming]
    /// Words and tags the guard dropped.
    var guardEdits: [EditOp] = []
}

/// What a dictation's cleanup needs, read once so one dictation sees one set of switches.
struct CleanupInputs: Sendable {
    var settings: CleanupSettings
    var dictionary: [DictionaryRule]
    var snippets: [Snippet]
    var now: Date

    var needsClipboard: Bool {
        settings.enabled && settings.pipelineOptions.snippets && snippets.contains { $0.expansion.contains("{clipboard}") }
    }
}

/// The text to deliver and what to store about how it got there.
struct CleanedDictation: Sendable {
    var text: String
    var edits: [EditOp]
    var cleanup: CleanupRecord
    /// The deterministic pass's output, when the model pass changed it. Otherwise `text` is that output.
    var deterministicText: String?
}

/// Everything after the audio is in hand, off the main actor: features, the WAV, the trim, the engine call, the
/// timing shift and the store writes. The controller adds the paste; `--pipeline-selftest` runs it without one.
/// A store or archive failure is logged and never stops the dictation.
struct DictationPipeline: Sendable {
    let store: (any DictationStoring)?
    let archive: (any DictationArchiving)?
    let engine: any DictationEngine
    let clock: any DictationClock

    var retention: TimeInterval = AudioArchive.defaultRetention
    var vocabulary: any VocabularyProviding = EmptyVocabulary()
    var settings: @Sendable () -> CleanupSettings = { CleanupSettings.load() }
    var textPipeline = TextPipeline()
    /// The local model pass for light and medium. Nil runs everything as basic.
    var smart: (any SmartCleaning)?

    /// Cleanup slower than this is thrown away and the raw text goes out.
    static let cleanupBudgetMs = 50.0

    func begin(_ session: DictationSession, target: DictationTarget) async -> Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let start = DictationStart(
            id: session.id, startedAt: session.startedAt, mode: .hold, trigger: .fn, target: target,
            appVersion: AppInfo.version,
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        )
        guard let store else { return false }
        do {
            try await store.begin(start)
            return true
        } catch {
            Log.app.error("store begin failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Adds the next stretch of a recording in progress to its in-progress copy. False when it couldn't be written.
    func appendPartial(_ samples: [Float], session: DictationSession) async -> Bool {
        guard let archive, archive.writesPartials else { return false }
        return await Task.detached {
            do {
                try archive.appendPartial(samples: samples, id: session.id)
                return true
            } catch {
                Log.app.error("partial audio write failed: \(String(describing: error), privacy: .public)")
                return false
            }
        }.value
    }

    /// A recording that was thrown away takes its in-progress copy with it.
    func discardPartial(_ session: DictationSession) {
        archive?.discardPartial(id: session.id)
    }

    /// Features on the untrimmed samples, the WAV before any transcribing, then the capture row.
    func recordCapture(_ audio: CapturedAudio, session: DictationSession, keyUpMs: Int) async -> AudioFeatures {
        let features = AudioFeatures.compute(samples: audio.samples, sampleRate: Int(audio.sampleRate))
        var audioPath: String?
        if let archive {
            do {
                audioPath = try archive.archive(samples: audio.samples, id: session.id).path
            } catch {
                Log.app.error("audio archive write failed: \(String(describing: error), privacy: .public)")
            }
        }
        func rounded(_ ms: Double?) -> Int? { ms.map { Int($0.rounded()) } }
        await write(session, "recordCapture") { store in
            try await store.recordCapture(session.id, CaptureRecord(
                captureStartMs: rounded(audio.captureStartMs), firstSampleMs: rounded(audio.firstSampleMs),
                firstNonzeroMs: rounded(audio.firstNonzeroMs), keyUpMs: keyUpMs, audioMs: rounded(audio.audioMs),
                voicedMs: rounded(features.voicedMs), audioPath: audioPath,
                audioExpiresAt: audioPath == nil ? nil : clock.now().addingTimeInterval(retention),
                inputDeviceUID: audio.deviceUID, inputDeviceName: audio.deviceName, inputTransport: audio.deviceTransport,
                sampleRateHz: Int(audio.sampleRate), rmsDb: features.rmsDb, peakDb: features.peakDb,
                noiseFloorDb: features.noiseFloorDb
            ))
        }
        return features
    }

    /// Nil when nothing was voiced or the engine heard nothing; the row is then already finished as `.empty`.
    /// `voicedMs` is the capture's voiced audio, for the guard against empty and stray output.
    func transcribe(
        _ audio: CapturedAudio, session: DictationSession, voicedMs: Double? = nil
    ) async throws -> TranscribedDictation? {
        guard SilenceTrimmer.voicedRange(audio.samples) != nil else {
            await finish(session, .empty)
            return nil
        }
        let trimmed = SilenceTrimmer.trim(audio.samples)
        let transcription = try await engine.transcribe(samples: trimmed.samples)
        let asrDoneMs = clock.milliseconds(from: session.keyDownAt, to: clock.nowNanos())

        // The engine's times are relative to the trimmed audio; put them back on the untrimmed capture.
        let head = trimmed.headTrimmedMs / 1000
        var shifted = transcription
        shifted.words = transcription.words.map { word in
            var word = word
            word.start += head
            word.end += head
            return word
        }
        let onset = shifted.words.first.map { Int(((audio.firstSampleMs ?? 0) + $0.start * 1000).rounded()) }
        await write(session, "recordTranscription") { store in
            try await store.recordTranscription(session.id, TranscriptionRecord(
                transcription: shifted, rawText: transcription.text, asrDoneMs: asrDoneMs, speechOnsetMs: onset
            ))
        }
        let guarded = TranscriptGuard().apply(shifted, voicedMs: voicedMs, clean: settings().enabled)
        guard !guarded.isEmpty else {
            if !guarded.edits.isEmpty { await write(session, "appendEdits") { try await $0.appendEdits(session.id, guarded.edits) } }
            await finish(session, .empty)
            return nil
        }
        return TranscribedDictation(
            text: guarded.text, rawText: transcription.text, asrDoneMs: asrDoneMs, words: shifted.words,
            guardEdits: guarded.edits
        )
    }

    func cleanupInputs() -> CleanupInputs {
        CleanupInputs(settings: settings(), dictionary: vocabulary.dictionary(), snippets: vocabulary.snippets(), now: clock.now())
    }

    /// The cleanup. The deterministic pass cannot lose a dictation: past the time budget, or when it leaves nothing
    /// for text that had words, the raw text is delivered instead. At light and medium the local model then works on
    /// its output, and anything it does wrong delivers the deterministic text. `context` and `clipboard` are used
    /// here and dropped.
    func clean(
        _ transcribed: TranscribedDictation, inputs: CleanupInputs, context: InsertionContext?, clipboard: String?,
        destination: S1MiniControls.Destination = .general, appName: String? = nil
    ) async -> CleanedDictation {
        let settings = inputs.settings
        guard settings.enabled else {
            return CleanedDictation(
                text: transcribed.rawText, edits: [],
                cleanup: CleanupRecord(cleanerID: Self.cleanerID, level: CleanupLevel.off.rawValue, outcome: "skipped")
            )
        }
        let clock = ContinuousClock()
        let start = clock.now
        let result = textPipeline.run(TextPipelineInput(
            text: transcribed.text, dictionary: inputs.dictionary.filter { !settings.level.needsModel || smart == nil || !$0.isJoinedSpelling }, snippets: inputs.snippets, context: context,
            now: inputs.now, clipboard: clipboard, options: settings.pipelineOptions
        ))
        let elapsed = clock.now - start
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        var record = CleanupRecord(
            cleanerID: Self.cleanerID, level: CleanupLevel.basic.rawValue, style: settings.styleName,
            ms: Int(ms.rounded()), outcome: "ok"
        )
        if ms > Self.cleanupBudgetMs {
            Log.app.error("cleanup took \(ms, format: .fixed(precision: 1)) ms; delivering the raw text")
            record.outcome = "timeout"
            return CleanedDictation(text: transcribed.rawText, edits: transcribed.guardEdits, cleanup: record)
        }
        for note in result.notes { Log.app.info("cleanup note: \(note, privacy: .public)") }
        let edits = transcribed.guardEdits + result.edits
        Log.app.info("cleanup ok ms=\(ms, format: .fixed(precision: 2)) edits=\(edits.count)")

        let level = settings.level
        guard level.needsModel, !result.text.isEmpty, let smart else {
            return CleanedDictation(text: result.text, edits: edits, cleanup: record)
        }
        guard let delivery = await smart.runReady(SmartCleanupRequest(
            text: result.text, level: level, style: settings.style, destination: destination,
            dictionary: inputs.dictionary, snippets: inputs.snippets, context: context, appName: appName
        ), waitingUpTo: SmartCleanup.defaultBudget(words: TextMetrics.wordCount(result.text))) else {
            return CleanedDictation(text: result.text, edits: edits, cleanup: record)
        }
        let model = delivery.model
        let modelResult = delivery.result
        record.cleanerID = model.id
        record.cleanerRev = model.revision
        record.level = level.rawValue
        record.ms = (record.ms ?? 0) + modelResult.milliseconds
        record.outcome = modelResult.outcome.rawValue
        record.promptSha = modelResult.promptSHA
        if let reason = modelResult.rejection {
            Log.cleaner.info("smart cleanup \(modelResult.outcome.rawValue, privacy: .public): \(reason, privacy: .public)")
        }
        Log.cleaner.info("smart cleanup \(modelResult.outcome.rawValue, privacy: .public) ms=\(modelResult.milliseconds)")
        let modelEdits = (modelResult.edit(from: result.text).map { [$0] } ?? []) + modelResult.postEdits
        return CleanedDictation(text: modelResult.text, edits: edits + modelEdits, cleanup: record,
                                deterministicText: modelResult.text == result.text ? nil : result.text)
    }

    static let cleanerID = "deterministic"

    /// The cleanup left nothing (the dictation was only fillers): the row ends as empty, its edits kept.
    func finishEmpty(_ cleaned: CleanedDictation, session: DictationSession) async {
        if !cleaned.edits.isEmpty { await write(session, "appendEdits") { try await $0.appendEdits(session.id, cleaned.edits) } }
        await finish(session, .empty)
    }

    func recordInsertion(_ result: DeliveryResult, session: DictationSession, cleaned: CleanedDictation? = nil) async {
        let insertDoneMs = clock.milliseconds(from: session.keyDownAt, to: clock.nowNanos())
        await write(session, "recordInsertion") { store in
            try await store.recordInsertion(session.id, InsertionRecord(
                finalText: result.finalText, detText: cleaned?.deterministicText ?? cleaned?.text, cleanup: cleaned?.cleanup, method: result.storeMethod,
                outcome: result.storeOutcome, focusMoved: result.focusMoved, pasteReceiptMs: result.pasteReceiptMs,
                insertDoneMs: insertDoneMs,
                target: result.target?.target
            ))
        }
        if let edits = cleaned?.edits, !edits.isEmpty {
            await write(session, "appendEdits") { try await $0.appendEdits(session.id, edits) }
        }
    }

    /// The read-back of a paste ended: the row's outcome becomes confirmed, not landed or stays unknown.
    func recordVerdict(_ session: DictationSession, _ verification: PasteVerification) async {
        await write(session, "recordInsertVerdict") { store in
            try await store.recordInsertVerdict(
                session.id, outcome: verification.verdict.storeOutcome, pasteReceiptMs: verification.receiptMs
            )
        }
    }

    /// The hold became a hands-free recording: the row opened as hold/fn says so now.
    func recordLock(_ session: DictationSession, trigger: DictationTrigger) async {
        await write(session, "recordLock") { store in
            try await store.recordLock(session.id, mode: .handsFree, trigger: trigger)
        }
    }

    /// An Undo runs a cancelled dictation after all: its row goes back to started.
    func reopen(_ session: DictationSession) async {
        await write(session, "reopen") { store in try await store.reopen(session.id) }
    }

    func finish(_ session: DictationSession, _ status: DictationStatus, errorMessage: String? = nil) async {
        await write(session, "finish") { store in
            try await store.finish(session.id, status: status, errorMessage: errorMessage)
        }
    }

    private func write(
        _ session: DictationSession, _ label: String, _ body: (any DictationStoring) async throws -> Void
    ) async {
        guard let store, session.rowOpen else { return }
        do {
            try await body(store)
        } catch {
            Log.app.error("store \(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }
}
