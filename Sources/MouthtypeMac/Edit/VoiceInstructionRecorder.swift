import Foundation
import MouthtypeCore

/// Records and transcribes one spoken editing instruction with the app's capture and speech engine. It is its own path:
/// no pill, no pipeline, no history row, no audio file, no clipboard. The audio and text live in this call's locals.
@MainActor final class VoiceInstructionRecorder: VoiceInstructionRecording {
    enum Failure: Error { case engineNotReady }

    private let capture: any DictationCapturing
    private let engine: any DictationEngine
    private let language: @MainActor () -> DictationLanguageRequest
    private var recording = false

    init(
        capture: any DictationCapturing, engine: any DictationEngine,
        language: @escaping @MainActor () -> DictationLanguageRequest = { DictationLanguageSetting.load().request() }
    ) {
        self.capture = capture
        self.engine = engine
        self.language = language
    }

    func start() async throws {
        guard engine.readiness == .ready else { throw Failure.engineNotReady }
        try await capture.start(keyDownAtNanos: HostClock.now())
        recording = true
    }

    func finish() async throws -> String {
        guard recording else { return "" }
        recording = false
        let audio = try await capture.stop()
        guard SilenceTrimmer.voicedRange(audio.samples) != nil else { return "" }
        let trimmed = SilenceTrimmer.trim(audio.samples)
        return try await engine.transcribe(samples: trimmed.samples, language: language()).text
    }

    func cancel() async {
        guard recording else { return }
        recording = false
        await capture.cancel()
    }
}
