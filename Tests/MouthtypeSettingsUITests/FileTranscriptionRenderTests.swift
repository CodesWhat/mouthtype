import AppKit
import MouthtypeCore
import SwiftUI
import Testing
@testable import MouthtypeMac

@MainActor @Suite(.serialized) struct FileTranscriptionRenderTests {
    @Test func fileFlowRendersIdleAndFullResultWithoutOpeningOrCopying() async throws {
        var copies = 0
        let model = FileTranscriptionModel(makeJob: {
            AudioFileTranscription(decoder: RenderFileDecoder(), engine: RenderFileEngine())
        }, copy: { _ in copies += 1 })
        let settings = SettingsModel(defaults: UserDefaults(suiteName: "FileRender-\(UUID().uuidString)")!, fileTranscription: model)
        settings.transcribeOpen = true
        try render(settings, size: SettingsTheme.minimumSize, name: "file-idle")
        model.start(URL(fileURLWithPath: "/not-opened/recording.wav"))
        for _ in 0..<500 where model.isBusy { await Task.yield() }
        #expect(model.state == .finished)
        #expect(model.text == RenderFileEngine.text)
        try render(settings, size: SettingsTheme.minimumSize, name: "file-result-minimum")
        #expect(copies == 0)
    }

    private func render(_ settings: SettingsModel, size: NSSize, name: String) throws {
        let bitmap = try SettingsRender.render(TranscribeFileSheet(model: settings, actions: SettingsActions()), dark: false, size: NSSize(width: 560, height: 520))
        #expect(bitmap.pixelsWide >= 560 && bitmap.pixelsHigh >= 520)
        try SettingsRender.save(bitmap, name: name)
    }
}

private struct RenderFileDecoder: AudioFileDecoding {
    func decode(_ url: URL, limits: AudioFileLimits) async throws -> DecodedAudioFile {
        DecodedAudioFile(samples: [0.1], durationSeconds: 1)
    }
}
private struct RenderFileEngine: Transcriber {
    let id = "render", displayName = "Render only"
    static let text = Array(repeating: "Émilie shared the draft. 世界 👋", count: 70).joined(separator: "\n")
    func prepare() async throws { Issue.record("No model preparation in render tests") }
    func transcribe(samples: [Float]) async throws -> Transcription {
        Transcription(text: Self.text, processingSeconds: 0, engineID: id)
    }
}
