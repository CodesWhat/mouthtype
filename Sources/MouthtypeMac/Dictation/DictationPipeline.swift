import Foundation
import MouthtypeCore

/// One dictation's identity and key-down anchor. Every stage time is ms from `keyDownAt`.
struct DictationSession: Sendable {
    var id: String
    var startedAt: Date
    var keyDownAt: UInt64 // host nanoseconds (`HostClock`)
    var startFocus: FocusSnapshot?
    var cleanupStyle: StyleOptions?
    /// A rule's cleanup level; nil uses the global one.
    var cleanupLevel: CleanupLevel?
    /// False when the store is missing or `begin` failed; later writes are then skipped.
    var rowOpen = false
    /// Code names read from the editor for this dictation (see `EditorHintsGatherer`). Held in memory only: never
    /// stored, logged or written to history. Nil when the setting is off or the app isn't one it covers.
    var editorHints: Task<[VocabularyBias.Term], Never>?
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
        settings.enabled && settings.pipelineOptions.snippets && snippets.contains { $0.expansion.localizedCaseInsensitiveContains("{clipboard}") }
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

/// How many takes are between "audio in hand" and "engine done". The engine holds one bias for all takes, so a key-down
/// warm-up for a new take must not replace it while an earlier take is still being recognised or boosted.
final class TranscribeActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    func enter() { lock.withLock { active += 1 } }
    func leave() { lock.withLock { active -= 1 } }
    var isIdle: Bool { lock.withLock { active == 0 } }
}

/// Everything after the audio is in hand, off the main actor: features, the WAV, the trim, the engine call, the
/// timing shift and the store writes. The controller adds the paste; `--pipeline-selftest` runs it without one.
/// A store or archive failure is logged and never stops the dictation.
struct DictationPipeline: Sendable {
    let store: (any DictationStoring)?
    let archive: (any DictationArchiving)?
    let engine: any DictationEngine
    let clock: any DictationClock
    let transcribing = TranscribeActivity()

    var audioRetention: @Sendable () -> AudioRetentionPolicy = { AudioRetentionPreference.load() }
    var vocabulary: any VocabularyProviding = EmptyVocabulary()
    var boostSavedWords: @Sendable () -> Bool = { VocabularyBoostSetting.isEnabled() }
    var editorHints: @Sendable () -> Bool = { EditorHintsSetting.isEnabled() }
    var settings: @Sendable () -> CleanupSettings = { CleanupSettings.load() }
    var appStyles: @Sendable () -> AppCleanupStyles = { (try? AppCleanupStyles.load()) ?? AppCleanupStyles() }
    var textPipeline = TextPipeline()
    /// The local model pass for light and medium. Nil runs everything as basic.
    var smart: (any SmartCleaning)?
    var smartDiagnostic: @Sendable (String) -> Void = { message in
        Log.cleaner.info("\(message, privacy: .public)")
    }

    /// Cleanup slower than this is thrown away and the guarded text (after TranscriptGuard, before cleanup) goes out.
    static let cleanupBudgetMs = 50.0
    var cleanupBudget = Self.cleanupBudgetMs

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

    func recoverPartial(_ session: DictationSession) async -> CapturedAudio? {
        guard let archive else { return nil }
        return await Task.detached {
            do {
                let samples = try archive.readPartial(id: session.id)
                guard !samples.isEmpty else { return nil as CapturedAudio? }
                return CapturedAudio(
                    samples: samples, sampleRate: Double(AudioArchive.sampleRate),
                    deviceUID: nil, deviceName: nil, deviceTransport: "recovered",
                    firstSampleMs: nil, firstNonzeroMs: nil, captureStartMs: 0,
                    audioMs: Double(samples.count) * 1000 / Double(AudioArchive.sampleRate)
                )
            } catch {
                Log.app.error("partial audio recovery failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }.value
    }

    /// Features on the untrimmed samples, the WAV before any transcribing, then the capture row.
    func recordCapture(_ audio: CapturedAudio, session: DictationSession, keyUpMs: Int) async -> AudioFeatures {
        await recordCaptureAndArchive(audio, session: session, keyUpMs: keyUpMs).features
    }

    func preserveForTermination(_ audio: CapturedAudio, session: DictationSession, keyUpMs: Int) async -> Bool {
        if audio.samples.isEmpty {
            await finish(session, .empty)
            return true
        }
        let capture = await recordCaptureAndArchive(audio, session: session, keyUpMs: keyUpMs)
        // The row stays `recorded` on purpose: the next launch's scan only offers unfinished rows, and it ends
        // the row as failed ("interrupted") itself once it has offered it.
        return capture.durable
    }

    /// Starts the editor-name bias building once the hints are in, so the key-up `transcribe` finds the model built
    /// (or already part way) instead of starting it. Never waits for the build; `transcribe` still applies its own
    /// settle cap, which then covers only what is left. Does nothing without editor names, or while an earlier take is still being transcribed.
    @discardableResult
    func warmEditorBias(_ hints: Task<[VocabularyBias.Term], Never>?) -> Task<Void, Never>? {
        guard let hints else { return nil }
        return Task {
            let editorTerms = await hints.value
            // An earlier take still in recognition or boosting would be rescored with these names (or lose its own
            // while this build starts), so this take falls back to the release-time path.
            guard !editorTerms.isEmpty, !Task.isCancelled, transcribing.isIdle else { return }
            await engine.setVocabularyBias(
                VocabularyBoostSetting.bias(enabled: boostSavedWords(), rules: vocabulary.dictionary(), editorTerms: editorTerms),
                settleWithin: nil
            )
        }
    }

    func recordCaptureAndArchive(_ audio: CapturedAudio, session: DictationSession, keyUpMs: Int) async -> (features: AudioFeatures, durable: Bool) {
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
        let recorded = await write(session, "recordCapture") { store in
            try await store.recordCapture(session.id, CaptureRecord(
                captureStartMs: rounded(audio.captureStartMs), firstSampleMs: rounded(audio.firstSampleMs),
                firstNonzeroMs: rounded(audio.firstNonzeroMs), keyUpMs: keyUpMs, audioMs: rounded(audio.audioMs),
                voicedMs: rounded(features.voicedMs), audioPath: audioPath,
                audioExpiresAt: audioPath == nil ? nil : audioRetention().expiration(from: clock.now()),
                inputDeviceUID: audio.deviceUID, inputDeviceName: audio.deviceName, inputTransport: audio.deviceTransport,
                sampleRateHz: Int(audio.sampleRate), rmsDb: features.rmsDb, peakDb: features.peakDb,
                noiseFloorDb: features.noiseFloorDb
            ))
        }
        return (features, audioPath != nil && (recorded || store == nil || !session.rowOpen))
    }

    /// Nil when nothing was voiced or the engine heard nothing; the row is then already finished as `.empty`.
    /// `voicedMs` is the capture's voiced audio, for the guard against empty and stray output.
    func transcribe(
        _ audio: CapturedAudio, session: DictationSession, voicedMs: Double? = nil
    ) async throws -> TranscribedDictation? {
        transcribing.enter()
        defer { transcribing.leave() }
        guard SilenceTrimmer.voicedRange(audio.samples) != nil else {
            await finish(session, .empty)
            return nil
        }
        let trimmed = SilenceTrimmer.trim(audio.samples)
        let rules = vocabulary.dictionary()
        let editorTerms = await session.editorHints?.value ?? []
        // Only a take with editor names waits for the model rebuild they cause. Saved words alone build in the background.
        await engine.setVocabularyBias(
            VocabularyBoostSetting.bias(enabled: boostSavedWords(), rules: rules, editorTerms: editorTerms),
            settleWithin: editorTerms.isEmpty ? nil : VocabularyBias.editorSettle
        )
        var transcription = try await engine.transcribe(samples: trimmed.samples)
        // Editor names help this take and nothing else: they never reach the stored record.
        transcription.boostTermsApplied = VocabularyBoostSetting.withoutEditorTerms(
            transcription.boostTermsApplied, editorTerms: editorTerms, rules: rules
        )
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
                transcription: shifted, rawText: transcription.text, asrDoneMs: asrDoneMs, speechOnsetMs: onset,
                boostTerms: transcription.boostTermsApplied
            ))
        }
        let guarded = TranscriptGuard().apply(shifted, voicedMs: voicedMs, clean: session.cleanupLevel.map { $0 != .off } ?? settings().enabled)
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

    func cleanupStyle(forBundleID bundleID: String?, websiteHost: String? = nil) -> StyleOptions {
        let styles = appStyles()
        return styles.resolve(bundleID: bundleID, websiteHost: websiteHost, fallback: settings().style)
    }

    func cleanupInputs(style: StyleOptions? = nil, level: CleanupLevel? = nil) -> CleanupInputs {
        var chosen = settings()
        if let style { chosen.style = style }
        if let level { chosen.level = level }
        return CleanupInputs(settings: chosen, dictionary: vocabulary.dictionary(), snippets: vocabulary.snippets(), now: clock.now())
    }

    /// The cleanup. The deterministic pass cannot lose a dictation: past the time budget, or when it leaves nothing
    /// for text that had words, the guarded text is delivered instead. At light and medium the local model then works on
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
        let phrases = SnippetExpander(snippets: settings.pipelineOptions.snippets ? inputs.snippets : [],
                                     now: inputs.now, clipboard: clipboard)
        let spoken = phrases.matchingTriggers(in: transcribed.text)
        var options = settings.pipelineOptions
        options.snippets = false
        // Swearing removal must not cut into a saved spelling's heard form (even one waiting for the model to join it)
        // or a snippet trigger heard in the text.
        // The same goes for written spellings and snippet text, which the fallback passes run without the dictionary.
        let snippetsOn = settings.pipelineOptions.snippets
        let protectedPhrases = inputs.dictionary.flatMap { [$0.heard, $0.written] }
            + (snippetsOn ? inputs.snippets.flatMap { [$0.trigger, $0.expansion] } : [])
        let protectedWords = inputs.dictionary.map(\.written) + (snippetsOn ? inputs.snippets.map(\.expansion) : [])

        /// A take delivered as heard still loses its swearing.
        func asHeard(_ text: String) -> TextPipelineResult {
            guard options.profanity, options.style == .formal else { return TextPipelineResult(text: text) }
            var only = TextPipelineOptions.none
            only.profanity = true
            only.style = options.style
            return textPipeline.run(TextPipelineInput(text: text, options: only, protectedPhrases: protectedPhrases, protectedWords: protectedWords))
        }

        func deterministic(_ dictionary: [DictionaryRule], startedAt start: ContinuousClock.Instant)
            -> (result: TextPipelineResult, expanded: StageResult, expected: [String], ms: Double) {
            var result = textPipeline.run(TextPipelineInput(
                text: transcribed.text, dictionary: dictionary, snippets: [], context: context,
                now: inputs.now, clipboard: clipboard, options: options, protectedPhrases: protectedPhrases,
                protectedWords: protectedWords
            ))
            // Cleanup may remove a filler or format a number that is part of a saved trigger.
            // Keep the spoken trigger intact rather than silently losing its replacement.
            if !spoken.isEmpty, phrases.matchingTriggers(in: result.text) != spoken {
                result = asHeard(transcribed.text)
            }
            let expanded = phrases.apply(result.text)
            let expected = phrases.matchingTriggers(in: result.text)
            let elapsed = clock.now - start
            let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            return (result, expanded, expected, ms)
        }

        let dictionary = inputs.dictionary.filter { !settings.level.needsModel || smart == nil || !$0.isJoinedSpelling }
        let (result, expanded, expected, ms) = deterministic(dictionary, startedAt: start)
        var record = CleanupRecord(
            cleanerID: Self.cleanerID, level: CleanupLevel.basic.rawValue, style: settings.styleName,
            ms: Int(ms.rounded()), outcome: "ok"
        )
        if ms > cleanupBudget {
            Log.app.error("cleanup took \(ms, format: .fixed(precision: 1)) ms; delivering the guarded text")
            record.outcome = "timeout"
            let heard = asHeard(transcribed.text)
            return CleanedDictation(text: heard.text, edits: transcribed.guardEdits + heard.edits, cleanup: record)
        }
        for note in result.notes { Log.app.info("cleanup note: \(note, privacy: .public)") }
        let edits = transcribed.guardEdits + result.edits
        Log.app.info("cleanup ok ms=\(ms, format: .fixed(precision: 2)) edits=\(edits.count)")

        let level = settings.level
        guard level.needsModel, !result.text.isEmpty, let smart else {
            return CleanedDictation(text: expanded.text, edits: edits + expanded.edits, cleanup: record)
        }
        guard let delivery = await smart.runReady(SmartCleanupRequest(
            text: result.text, level: level, style: settings.style, destination: destination,
            dictionary: inputs.dictionary, snippets: [], context: context, appName: appName,
            protectedPhrases: protectedPhrases
        ), waitingUpTo: SmartCleanup.defaultBudget(words: TextMetrics.wordCount(result.text))) else {
            if dictionary.count != inputs.dictionary.count {
                let fallback = deterministic(inputs.dictionary, startedAt: clock.now)
                let totalMs = ms + fallback.ms
                record.ms = Int(totalMs.rounded())
                if totalMs > cleanupBudget {
                    Log.app.error("Basic fallback took \(totalMs, format: .fixed(precision: 1)) ms; delivering the guarded text")
                    record.outcome = "timeout"
                    let heard = asHeard(transcribed.text)
                    return CleanedDictation(text: heard.text, edits: transcribed.guardEdits + heard.edits, cleanup: record)
                }
                return CleanedDictation(text: fallback.expanded.text,
                    edits: transcribed.guardEdits + fallback.result.edits + fallback.expanded.edits, cleanup: record)
            }
            return CleanedDictation(text: expanded.text, edits: edits + expanded.edits, cleanup: record)
        }
        let model = delivery.model
        let modelResult = delivery.result
        record.cleanerID = model.id
        record.cleanerRev = model.revision
        record.level = level.rawValue
        record.ms = (record.ms ?? 0) + modelResult.milliseconds
        record.outcome = modelResult.outcome.rawValue
        record.promptSha = modelResult.promptSHA
        smartDiagnostic("smart cleanup \(modelResult.outcome.rawValue) ms=\(modelResult.milliseconds)")
        let final = phrases.apply(modelResult.text)
        guard phrases.matchingTriggers(in: modelResult.text) == expected else {
            record.outcome = "guard-rejected"
            return CleanedDictation(text: expanded.text, edits: edits + expanded.edits, cleanup: record)
        }
        let modelEdits = (modelResult.edit(from: result.text).map { [$0] } ?? []) + modelResult.postEdits
        return CleanedDictation(text: final.text, edits: edits + modelEdits + final.edits, cleanup: record,
                                deterministicText: final.text == expanded.text ? nil : expanded.text)
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

    @discardableResult private func write(
        _ session: DictationSession, _ label: String, _ body: (any DictationStoring) async throws -> Void
    ) async -> Bool {
        guard let store, session.rowOpen else { return false }
        do {
            try await body(store)
            return true
        } catch {
            Log.app.error("store \(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
