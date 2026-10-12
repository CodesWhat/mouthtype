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
    var text: String
    var asrDoneMs: Int
    var words: [WordTiming]
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
    func transcribe(_ audio: CapturedAudio, session: DictationSession) async throws -> TranscribedDictation? {
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
        guard !transcription.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await finish(session, .empty)
            return nil
        }
        return TranscribedDictation(text: transcription.text, asrDoneMs: asrDoneMs, words: shifted.words)
    }

    func recordInsertion(_ result: DeliveryResult, session: DictationSession) async {
        let insertDoneMs = clock.milliseconds(from: session.keyDownAt, to: clock.nowNanos())
        await write(session, "recordInsertion") { store in
            try await store.recordInsertion(session.id, InsertionRecord(
                finalText: result.finalText, method: result.storeMethod, outcome: result.storeOutcome,
                focusMoved: result.focusMoved, insertDoneMs: insertDoneMs, target: result.target?.target
            ))
        }
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
