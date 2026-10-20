import AppKit
import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

private actor PageGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { waiter = $0 } }
    func release() { waiter?.resume(); waiter = nil }
}
private struct PageDecoder: AudioFileDecoding {
    func decode(_ url: URL, limits: AudioFileLimits) async throws -> DecodedAudioFile {
        DecodedAudioFile(samples: [0.1], durationSeconds: 1)
    }
}
private struct PageEngine: Transcriber {
    let id = "page", displayName = "Page"
    let gate: PageGate
    func prepare() async throws {}
    func transcribe(samples: [Float]) async throws -> Transcription {
        await gate.wait()
        return Transcription(text: "Finished on another page.", processingSeconds: 0, engineID: id)
    }
}

@MainActor @Suite struct FileTranscriptionPageTests {
    private func running() async -> (SettingsModel, FileTranscriptionModel, PageGate) {
        let gate = PageGate()
        let transcription = FileTranscriptionModel(makeJob: { AudioFileTranscription(decoder: PageDecoder(), engine: PageEngine(gate: gate)) }, copy: { _ in })
        let defaults = UserDefaults(suiteName: "FileTranscriptionPage-\(UUID().uuidString)")!
        let model = SettingsModel(defaults: defaults, fileTranscription: transcription)
        model.page = .transcribeFile
        transcription.start(URL(fileURLWithPath: "/audio.wav"))
        for _ in 0..<500 where await !gate.entered { await Task.yield() }
        return (model, transcription, gate)
    }

    @Test func switchingPagesDuringARunKeepsItGoingAndTheResultIsThereOnReturn() async {
        let (model, transcription, gate) = await running()
        #expect(transcription.isBusy)
        #expect(model.select(.general))
        #expect(model.select(.home))
        #expect(transcription.isBusy && transcription.state == .transcribing)
        await gate.release()
        for _ in 0..<500 where transcription.isBusy { await Task.yield() }
        #expect(model.select(.transcribeFile))
        #expect(transcription.state == .finished && transcription.text == "Finished on another page.")
    }

    @Test func closingTheWindowCancelsARunningTranscriptionLikeTheOldWindowDid() async {
        let (model, transcription, gate) = await running()
        let controller = SettingsWindow(model: model)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(transcription.state == .cancelling)
        await gate.release()
        for _ in 0..<500 where transcription.isBusy { await Task.yield() }
        #expect(transcription.state == .cancelled)
        controller.window?.delegate = nil
    }
}
