import AppKit
import MouthtypeCore
import SwiftUI
import Testing
@testable import MouthtypeMac

@MainActor @Suite(.serialized) struct FileTranscriptionRenderTests {
    private func model(gate: RenderGate? = nil, failing: Bool = false) -> FileTranscriptionModel {
        FileTranscriptionModel(makeJob: {
            AudioFileTranscription(decoder: RenderFileDecoder(failing: failing), engine: RenderFileEngine(gate: gate))
        }, copy: { _ in })
    }

    @Test func emptyBusyDoneAndFailedRenderInLightAndDark() async throws {
        let gate = RenderGate()
        let transcription = model(gate: gate)

        try renderBoth(transcription, name: "transcribe-empty")
        #expect(transcription.state == .idle)

        transcription.start(URL(fileURLWithPath: "/not-opened/standup.m4a"))
        for _ in 0..<500 where await !gate.entered { await Task.yield() }
        #expect(transcription.state == .transcribing)
        try renderBoth(transcription, name: "transcribe-busy")

        await gate.release()
        for _ in 0..<500 where transcription.isBusy { await Task.yield() }
        #expect(transcription.state == .finished && transcription.text == RenderFileEngine.text)
        try renderBoth(transcription, name: "transcribe-done")

        // A failed second import keeps the transcript on screen.
        let failing = model(failing: true)
        failing.start(URL(fileURLWithPath: "/not-opened/broken.wav"))
        for _ in 0..<500 where failing.isBusy { await Task.yield() }
        #expect(failing.state == .failed && !failing.hasResult)
        try renderBoth(failing, name: "transcribe-failed")
    }

    @Test func aFailedImportOverAResultRendersWithTheKeptTranscript() async throws {
        var fail = false
        let transcription = FileTranscriptionModel(makeJob: {
            AudioFileTranscription(decoder: RenderFileDecoder(failing: fail), engine: RenderFileEngine(gate: nil))
        }, copy: { _ in })
        transcription.start(URL(fileURLWithPath: "/not-opened/standup.m4a"))
        for _ in 0..<500 where transcription.isBusy { await Task.yield() }
        fail = true
        transcription.start(URL(fileURLWithPath: "/not-opened/broken.wav"))
        for _ in 0..<500 where transcription.isBusy { await Task.yield() }
        #expect(transcription.state == .failed && transcription.hasResult)
        try renderBoth(transcription, name: "transcribe-failed-kept")
    }

    @Test func renderingNeverCopiesOrOpensAFile() async throws {
        var copies = 0
        let transcription = FileTranscriptionModel(makeJob: {
            AudioFileTranscription(decoder: RenderFileDecoder(failing: false), engine: RenderFileEngine(gate: nil))
        }, copy: { _ in copies += 1 })
        transcription.start(URL(fileURLWithPath: "/not-opened/recording.wav"))
        for _ in 0..<500 where transcription.isBusy { await Task.yield() }
        try renderBoth(transcription, name: "transcribe-no-side-effects")
        #expect(copies == 0)
    }

    @Test func durationReadsAsMinutesAndSeconds() {
        #expect(FileTranscriptionView.durationText(252) == "4 min 12 s")
        #expect(FileTranscriptionView.durationText(42.4) == "42 s")
    }

    private func renderBoth(_ model: FileTranscriptionModel, name: String) throws {
        for dark in [false, true] {
            let size = FileTranscriptionView.size
            let bitmap = try SettingsRender.render(FileTranscriptionView(model: model, choose: {}, save: {}), dark: dark, size: size)
            #expect(bitmap.pixelsWide >= Int(size.width) && bitmap.pixelsHigh >= Int(size.height))
            try SettingsRender.save(bitmap, name: "\(name)-\(dark ? "dark" : "light")")
        }
    }
}

private actor RenderGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { waiter = $0 } }
    func release() { waiter?.resume(); waiter = nil }
}
private struct RenderFileDecoder: AudioFileDecoding {
    var failing = false
    func decode(_ url: URL, limits: AudioFileLimits) async throws -> DecodedAudioFile {
        if failing { throw AudioFileError.invalidAudio }
        return DecodedAudioFile(samples: [0.1], durationSeconds: 252)
    }
}
private struct RenderFileEngine: Transcriber {
    let id = "render", displayName = "Render only"
    var gate: RenderGate?
    static let text = Array(repeating: "Émilie shared the draft. 世界 👋", count: 70).joined(separator: "\n")
    func prepare() async throws { Issue.record("No model preparation in render tests") }
    func transcribe(samples: [Float]) async throws -> Transcription {
        await gate?.wait()
        return Transcription(text: Self.text, processingSeconds: 0, engineID: id)
    }
}
