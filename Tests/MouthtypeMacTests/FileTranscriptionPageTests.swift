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
    private func running() async -> (FileTranscriptionModel, PageGate) {
        let gate = PageGate()
        let transcription = FileTranscriptionModel(makeJob: { AudioFileTranscription(decoder: PageDecoder(), engine: PageEngine(gate: gate)) }, copy: { _ in })
        transcription.start(URL(fileURLWithPath: "/audio.wav"))
        for _ in 0..<500 where await !gate.entered { await Task.yield() }
        return (transcription, gate)
    }

    private func settings(_ transcribeOpens: @escaping @MainActor () -> Void) -> SettingsModel {
        SettingsModel(defaults: UserDefaults(suiteName: "FileTranscriptionPage-\(UUID().uuidString)")!, openTranscribeWindow: transcribeOpens)
    }

    @Test func openingTheTranscribeDestinationOpensTheWindowAndLeavesThePageAlone() {
        var opens = 0
        let model = settings { opens += 1 }
        model.page = .style
        model.openSettings(.general)
        #expect(model.open(.transcribeFile))
        #expect(opens == 1 && model.page == .style && model.settingsOpen)
    }

    @Test func switchingPagesAndClosingTheMainWindowLeaveARunGoing() async {
        let (transcription, gate) = await running()
        let model = settings {}
        #expect(model.select(.style) && model.select(.home))
        let main = SettingsWindow(model: model)
        main.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(transcription.isBusy && transcription.state == .transcribing)
        await gate.release()
        for _ in 0..<500 where transcription.isBusy { await Task.yield() }
        #expect(transcription.state == .finished && transcription.text == "Finished on another page.")
        main.window?.delegate = nil
    }

    @Test func closingTheTranscribeWindowCancelsARunningTranscription() async {
        let (transcription, gate) = await running()
        let controller = FileTranscriptionWindow(model: transcription)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(transcription.state == .cancelling)
        await gate.release()
        for _ in 0..<500 where transcription.isBusy { await Task.yield() }
        #expect(transcription.state == .cancelled)
        controller.window?.delegate = nil
    }

    @Test func theTranscribeWindowIsItsOwnTitledWindow() {
        let controller = FileTranscriptionWindow(model: FileTranscriptionModel(makeJob: { throw CocoaError(.featureUnsupported) }, copy: { _ in }))
        #expect(controller.window?.title == "Transcribe Audio File")
        #expect(controller.window?.styleMask.contains(.closable) == true)
        #expect(controller.window?.contentLayoutRect.size.width == FileTranscriptionView.size.width)
        controller.window?.delegate = nil
    }
}
