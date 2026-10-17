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
        let controller = FileTranscriptionWindow(model: model)
        #expect(controller.window?.title == "Transcribe Audio File")
        try render(controller, size: NSSize(width: 760, height: 600), name: "file-idle")
        model.start(URL(fileURLWithPath: "/not-opened/recording.wav"))
        for _ in 0..<500 where model.isBusy { await Task.yield() }
        #expect(model.state == .finished)
        #expect(model.text == RenderFileEngine.text)
        try render(controller, size: NSSize(width: 560, height: 440), name: "file-result-minimum")
        #expect(copies == 0)
        #expect(controller.window?.isVisible == false)
    }

    private func render(_ controller: FileTranscriptionWindow, size: NSSize, name: String) throws {
        controller.window?.appearance = NSAppearance(named: .aqua)
        controller.window?.setContentSize(size)
        let view = try #require(controller.window?.contentView)
        view.setFrameSize(size)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(!controller.window!.isVisible)
        #expect(bitmap.pixelsWide >= Int(size.width) && bitmap.pixelsHigh >= Int(size.height))
        if let directory = ProcessInfo.processInfo.environment["MOUTHTYPE_SETTINGS_PREVIEWS"] {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: output.appendingPathComponent(name + ".png"))
        }
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
