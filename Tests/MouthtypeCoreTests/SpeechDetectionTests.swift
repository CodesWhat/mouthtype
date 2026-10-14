import Foundation
import FluidAudio
import Testing
@testable import MouthtypeCore

@Suite struct SpeechDetectionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHTYPE_SPEECH_FIXTURES"] != nil))
    func archivedEmptyTakesHaveNoSpeechAndSpokenWordsSurvive() async throws {
        struct Fixture: Decodable {
            var path: String
            var speech: Bool
        }
        let path = try #require(ProcessInfo.processInfo.environment["MOUTHTYPE_SPEECH_FIXTURES"])
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let detector = try await VadManager(config: VadConfig(defaultThreshold: 0.5))
        let engine = try EngineCatalog.make(id: "parakeet-tdt-v3")
        try await engine.prepare()
        for fixture in fixtures {
            let samples = try AudioLoading.loadSamples(from: URL(fileURLWithPath: fixture.path))
            let results = try await detector.process(samples)
            let peak = results.map(\.probability).max() ?? 0
            print("SPEECH-CHECK \(URL(fileURLWithPath: fixture.path).lastPathComponent): peak=\(peak) expected=\(fixture.speech)")
            #expect(results.contains { $0.isVoiceActive } == fixture.speech)
            let transcription = try await engine.transcribe(samples: samples)
            #expect(!transcription.text.isEmpty == fixture.speech)
            let trimmed = SilenceTrimmer.trim(samples)
            let pipelineTranscription = try await engine.transcribe(samples: trimmed.samples)
            #expect(!pipelineTranscription.text.isEmpty == fixture.speech)
        }
    }
}
