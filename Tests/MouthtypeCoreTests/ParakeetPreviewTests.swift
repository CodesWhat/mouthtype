import Testing
@testable import MouthtypeCore

@Suite struct ParakeetPreviewTests {
    @Test func previewRejectsUnpreparedEngineWithoutLoadingModels() async {
        let engine = ParakeetEngine(version: .v3)
        await #expect(throws: EngineError.self) {
            try await engine.preview(samples: Array(repeating: 0.1, count: 32_000))
        }
    }

    @Test func insufficientPreviewAudioDoesNotLoadModels() async throws {
        let engine = ParakeetEngine(version: .v3)
        #expect(try await engine.preview(samples: []) == nil)
        #expect(try await engine.preview(samples: Array(repeating: 0.1, count: 31_999)) == nil)
    }
}
