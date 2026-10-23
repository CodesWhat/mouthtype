import Foundation
import MouthtypeCore
import Observation

/// The optional "Try a test take" in Setup: records a few seconds, then shows what the engine heard and how loud the
/// input was. It never pastes, never touches the clipboard and never writes a transcript row or an audio file.
@MainActor @Observable final class SetupTestTake {
    enum State: Equatable {
        case idle, recording, transcribing
        case finished(Outcome)
        case failed(String)
    }

    struct Outcome: Equatable {
        var transcript: String
        var micName: String?
        var peakDb: Double
        var kind: SilentTakeKind

        /// A take with words in it, whatever the level.
        var heardSpeech: Bool { !transcript.isEmpty }
    }

    /// How long a take records unless it is stopped sooner.
    static let duration: Duration = .seconds(4)
    /// The level shown while recording runs from this floor up to 0 dB.
    static let meterFloorDb = -60.0

    private(set) var state: State = .idle
    /// The input level right now, 0 to 1, while recording.
    private(set) var level = 0.0

    private let capture: any DictationCapturing
    private let engine: any DictationEngine
    private let readLevel: @MainActor () -> Float
    private let canStart: @MainActor () -> Bool
    private let language: @MainActor () -> DictationLanguageRequest
    private let sleep: @Sendable (Duration) async throws -> Void
    private var task: Task<Void, Never>?
    private var stopRequested = false

    init(
        capture: any DictationCapturing, engine: any DictationEngine, readLevel: @escaping @MainActor () -> Float,
        canStart: @escaping @MainActor () -> Bool = { true },
        language: @escaping @MainActor () -> DictationLanguageRequest = { DictationLanguageSetting.load().request() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.capture = capture
        self.engine = engine
        self.readLevel = readLevel
        self.canStart = canStart
        self.language = language
        self.sleep = sleep
    }

    var isBusy: Bool { state == .recording || state == .transcribing }

    /// Maps a dBFS reading onto the meter's 0 to 1 range.
    static func meterFraction(db: Double) -> Double {
        min(max((db - meterFloorDb) / -meterFloorDb, 0), 1)
    }

    /// Starts a take. Does nothing while one runs or while a dictation holds the microphone.
    func start() {
        guard !isBusy else { return }
        guard canStart() else {
            state = .failed("Mouthtype is busy with a dictation. Try again in a moment.")
            return
        }
        stopRequested = false
        level = 0
        state = .recording
        task = Task { [weak self] in await self?.run() }
    }

    /// Ends a recording early and goes on to transcribe it.
    func stop() {
        guard state == .recording else { return }
        stopRequested = true
    }

    func reset() {
        guard !isBusy else { return }
        state = .idle
        level = 0
    }

    /// Drops a take in progress, for a window that closes mid-recording.
    func cancel() async {
        task?.cancel()
        await task?.value
        task = nil
    }

    private func run() async {
        do {
            try await capture.start(keyDownAtNanos: HostClock.now())
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        var peakDb = AudioFeatures.silenceDb
        var elapsed = Duration.zero
        let tick = Duration.milliseconds(100)
        while elapsed < Self.duration, !stopRequested, !Task.isCancelled {
            try? await sleep(tick)
            elapsed += tick
            let db = Double(readLevel())
            peakDb = max(peakDb, db)
            level = Self.meterFraction(db: db)
        }
        if Task.isCancelled {
            await capture.cancel()
            state = .idle
            return
        }
        state = .transcribing
        level = 0
        let audio: CapturedAudio
        do {
            audio = try await capture.stop()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        let features = AudioFeatures.compute(samples: audio.samples, sampleRate: Int(audio.sampleRate))
        let kind = SilentTakeKind.classify(features)
        var transcript = ""
        if SilenceTrimmer.voicedRange(audio.samples) != nil {
            do {
                let trimmed = SilenceTrimmer.trim(audio.samples)
                transcript = try await engine.transcribe(samples: trimmed.samples, language: language()).text
            } catch {
                state = .failed("Recognition failed: \(error.localizedDescription)")
                return
            }
        }
        state = .finished(Outcome(transcript: transcript, micName: audio.deviceName, peakDb: features.peakDb, kind: kind))
    }
}
