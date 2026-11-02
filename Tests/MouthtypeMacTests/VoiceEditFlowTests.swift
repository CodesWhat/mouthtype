import AppKit
import Foundation
import MouthtypeCore
import Testing
@testable import MouthtypeMac

@MainActor private final class FakeVoiceEditor: SelectionEditing {
    var selection = SelectedText(pid: 42, element: nil, range: NSRange(location: 0, length: 11), text: "hello world")
    var captureError: Error?
    var captures = 0
    var replaceAccepted = true
    private(set) var replaceCalls: [(original: SelectedText, text: String)] = []

    func capture() throws -> SelectedText { throw SelectionCleanupError.unavailable }
    func captureOffMain(budget: TimeInterval) async throws -> SelectedText {
        captures += 1
        if let captureError { throw captureError }
        return selection
    }
    func replace(_ original: SelectedText, with replacement: String) -> Bool {
        replaceCalls.append((original, replacement))
        return replaceAccepted
    }
}

@MainActor private final class FakeRecorder: VoiceInstructionRecording {
    var heard = "make it shorter"
    var startError: Error?
    private(set) var starts = 0
    private(set) var finishes = 0
    private(set) var cancels = 0
    func start() async throws {
        starts += 1
        if let startError { throw startError }
    }
    func finish() async throws -> String {
        finishes += 1
        return heard
    }
    func cancel() async { cancels += 1 }
}

private final class FakeEngine: VoiceEditing, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [VoiceEditRequest] = []
    var result: VoiceEditResult = .preview(replacement: "hi world", instruction: "make it shorter")
    /// When set, the engine suspends until its task is cancelled, then reports cancellation like the real one.
    var blocks = false
    var requests: [VoiceEditRequest] { lock.withLock { _requests } }

    func run(_ request: VoiceEditRequest) async -> VoiceEditResult {
        lock.withLock { _requests.append(request) }
        if blocks {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            return .cancelled
        }
        return result
    }
}

@MainActor private struct Rig {
    let editor = FakeVoiceEditor()
    let recorder = FakeRecorder()
    let engine = FakeEngine()
    var busy = false
    var secure = false
    var unavailable: String?
    var recordingLimit = Duration.seconds(600)
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    func coordinator() -> VoiceEditCoordinator {
        let busy = busy, secure = secure, unavailable = unavailable
        return VoiceEditCoordinator(
            editor: editor, recorder: recorder, engine: engine, busy: { busy }, secureContext: { secure },
            modelUnavailableReason: { unavailable }, recordingLimit: recordingLimit, sleep: sleep)
    }
}

@MainActor private func wait(for coordinator: VoiceEditCoordinator, _ phase: VoiceEditPhase) async {
    for _ in 0..<400 where coordinator.phase != phase { try? await Task.sleep(for: .milliseconds(5)) }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct VoiceEditFlowTests {
    @Test func secureFieldRefusesBeforeReadingOrRecording() async {
        var rig = Rig()
        rig.secure = true
        let flow = rig.coordinator()
        await flow.begin()
        #expect(flow.phase == .ended(.refused(.secureField)))
        #expect(rig.editor.captures == 0 && rig.recorder.starts == 0)
    }

    @Test func noSelectionRefusesBeforeRecording() async {
        let rig = Rig()
        rig.editor.captureError = SelectionCleanupError.unavailable
        let flow = rig.coordinator()
        await flow.begin()
        #expect(flow.phase == .ended(.refused(.noSelection)))
        #expect(rig.recorder.starts == 0)
    }

    @Test func whitespaceOnlySelectionCountsAsNoSelection() async {
        let rig = Rig()
        rig.editor.selection.text = " \n\t "
        let flow = rig.coordinator()
        await flow.begin()
        #expect(flow.phase == .ended(.refused(.noSelection)))
        #expect(rig.recorder.starts == 0)
    }

    @Test func slowSelectionReadRefusesWithATimeoutReason() async {
        let rig = Rig()
        rig.editor.captureError = SelectionCleanupError.timedOut
        let flow = rig.coordinator()
        await flow.begin()
        #expect(flow.phase == .ended(.refused(.captureTimedOut)))
        #expect(rig.recorder.starts == 0)
    }

    @Test func oversizedSelectionRefusesAndTheLimitItselfPasses() async {
        let rig = Rig()
        rig.editor.selection.text = String(repeating: "a", count: VoiceEditCoordinator.selectionLimit + 1)
        let flow = rig.coordinator()
        await flow.begin()
        #expect(flow.phase == .ended(.refused(.selectionTooLong)))
        #expect(rig.recorder.starts == 0)

        rig.editor.selection.text = String(repeating: "a", count: VoiceEditCoordinator.selectionLimit)
        await flow.begin()
        #expect(flow.phase == .recording)
        #expect(rig.recorder.starts == 1)
        await flow.cancel()
    }

    @Test func unavailableModelAndBusyAppRefuseBeforeAnythingIsRead() async {
        var rig = Rig()
        rig.unavailable = "Download the model first."
        var flow = rig.coordinator()
        await flow.begin()
        #expect(flow.phase == .ended(.refused(.modelUnavailable("Download the model first."))))
        #expect(rig.editor.captures == 0 && rig.recorder.starts == 0)

        rig = Rig()
        rig.busy = true
        flow = rig.coordinator()
        await flow.begin()
        #expect(flow.phase == .ended(.refused(.busy)))
        #expect(rig.editor.captures == 0 && rig.recorder.starts == 0)
    }

    @Test func recordingFailureEndsWithAReasonAndNoWrite() async {
        let rig = Rig()
        rig.recorder.startError = CocoaError(.fileReadUnknown)
        let flow = rig.coordinator()
        await flow.begin()
        #expect(flow.phase == .ended(.recordingFailed))
        #expect(rig.editor.replaceCalls.isEmpty)
    }

    @Test func cancelDuringRecordingStopsTheRecorderAndNeverGenerates() async {
        let rig = Rig()
        let flow = rig.coordinator()
        await flow.begin()
        #expect(flow.phase == .recording)
        await flow.cancel()
        #expect(flow.phase == .idle)
        #expect(rig.recorder.cancels == 1 && rig.recorder.finishes == 0)
        #expect(rig.engine.requests.isEmpty && rig.editor.replaceCalls.isEmpty)
    }

    @Test func cancelDuringGenerationDropsTheResultAndLeavesTheOriginal() async {
        let rig = Rig()
        rig.engine.blocks = true
        let flow = rig.coordinator()
        await flow.begin()
        let run = Task { await flow.stopRecording() }
        await wait(for: flow, .generating)
        #expect(flow.phase == .generating)
        await flow.cancel()
        await run.value
        #expect(flow.phase == .idle)
        #expect(flow.replacement.isEmpty && flow.instruction.isEmpty)
        #expect(rig.editor.replaceCalls.isEmpty)
    }

    @Test func acceptBeforeThePreviewDoesNothing() async {
        let rig = Rig()
        rig.engine.blocks = true
        let flow = rig.coordinator()
        await flow.begin()
        flow.accept()
        let run = Task { await flow.stopRecording() }
        await wait(for: flow, .generating)
        flow.accept()
        #expect(rig.editor.replaceCalls.isEmpty)
        await flow.cancel()
        await run.value
    }

    @Test func spokenInstructionGoesToTheEngineSeparatelyFromTheSelection() async {
        let rig = Rig()
        rig.recorder.heard = "  make it shorter \n"
        let flow = rig.coordinator()
        await flow.begin()
        await flow.stopRecording()
        #expect(rig.engine.requests == [VoiceEditRequest(selection: "hello world", instruction: "make it shorter")])
        #expect(flow.phase == .preview)
        #expect(flow.replacement == "hi world" && flow.instruction == "make it shorter")
        #expect(rig.editor.replaceCalls.isEmpty)
    }

    @Test func acceptRevalidatesAndReplacesExactlyOnceThenKeepsNothing() async {
        let rig = Rig()
        rig.editor.selection.text = " hello world\n"
        rig.editor.selection.range = NSRange(location: 0, length: 13)
        let flow = rig.coordinator()
        await flow.begin()
        await flow.stopRecording()
        flow.accept()
        flow.accept()
        #expect(rig.editor.replaceCalls.count == 1)
        #expect(rig.editor.replaceCalls.first?.original == rig.editor.selection)
        #expect(rig.editor.replaceCalls.first?.text == " hi world\n")
        #expect(flow.phase == .ended(.accepted))
        #expect(flow.replacement.isEmpty && flow.instruction.isEmpty && flow.sourceApp == nil)
    }

    @Test func staleSelectionOrFocusAtAcceptLeavesTheOriginalWithAReason() async {
        let rig = Rig()
        rig.editor.replaceAccepted = false
        let flow = rig.coordinator()
        await flow.begin()
        await flow.stopRecording()
        flow.accept()
        #expect(flow.phase == .ended(.stale))
        #expect(VoiceEditEnd.stale.isFailure && !VoiceEditEnd.stale.message.isEmpty)
        #expect(rig.editor.replaceCalls.count == 1)
        #expect(flow.replacement.isEmpty)
    }

    @Test(arguments: [
        (VoiceEditResult.refused(.modelDeclined), VoiceEditEnd.engineRefused(.modelDeclined)),
        (VoiceEditResult.refused(.chatter), VoiceEditEnd.engineRefused(.chatter)),
        (VoiceEditResult.timedOut, VoiceEditEnd.timedOut),
        (VoiceEditResult.modelUnavailable, VoiceEditEnd.modelUnavailable),
        (VoiceEditResult.modelFailed, VoiceEditEnd.modelFailed),
    ])
    func engineFailuresEndWithoutAPreviewOrAWrite(result: VoiceEditResult, expected: VoiceEditEnd) async {
        let rig = Rig()
        rig.engine.result = result
        let flow = rig.coordinator()
        await flow.begin()
        await flow.stopRecording()
        #expect(flow.phase == .ended(expected))
        #expect(!expected.message.isEmpty && expected.isFailure)
        #expect(flow.replacement.isEmpty)
        #expect(rig.editor.replaceCalls.isEmpty)
    }

    @Test func silenceEndsWithoutRunningTheEngine() async {
        let rig = Rig()
        rig.recorder.heard = "   "
        let flow = rig.coordinator()
        await flow.begin()
        await flow.stopRecording()
        #expect(flow.phase == .ended(.noInstruction))
        #expect(rig.engine.requests.isEmpty)
    }

    @Test func recordingStopsItselfAtTheLimit() async {
        var rig = Rig()
        rig.recordingLimit = .milliseconds(1)
        rig.sleep = { _ in }
        let flow = rig.coordinator()
        await flow.begin()
        await wait(for: flow, .preview)
        #expect(flow.phase == .preview)
        #expect(rig.recorder.finishes == 1)
        #expect(rig.editor.replaceCalls.isEmpty)
    }

    @Test func aFinishedFlowCanBeStartedAgain() async {
        let rig = Rig()
        rig.editor.captureError = SelectionCleanupError.unavailable
        let flow = rig.coordinator()
        await flow.begin()
        rig.editor.captureError = nil
        await flow.begin()
        #expect(flow.phase == .recording)
        await flow.cancel()
    }

    @Test func nothingIsKeptOrWrittenToDefaultsAfterAnyEnding() async {
        let suiteName = "voice-edit-flow-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let rig = Rig()
        let flow = rig.coordinator()
        await flow.begin()
        await flow.stopRecording()
        flow.accept()
        await flow.cancel()
        #expect(flow.phase == .idle)
        #expect(flow.instruction.isEmpty && flow.replacement.isEmpty && flow.sourceApp == nil)
        #expect(defaults.dictionaryRepresentation().keys.filter { $0.contains("oiceEdit") }.isEmpty)
    }
}

@MainActor @Suite struct VoiceEditShortcutTests {
    @Test func unsetByDefaultAndStoredOnlyWhenChosen() {
        let suiteName = "voice-edit-shortcut-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(VoiceEditShortcut.current(defaults) == .off && VoiceEditShortcut.current(defaults).shortcut == nil)
        VoiceEditShortcut.set(.controlOptionE, in: defaults)
        #expect(VoiceEditShortcut.current(defaults) == .controlOptionE && VoiceEditShortcut.current(defaults).shortcut != nil)
        VoiceEditShortcut.set(.off, in: defaults)
        #expect(defaults.object(forKey: VoiceEditShortcut.preferenceKey) == nil)
    }

    @Test func noChoiceCollidesWithPasteLastOrCopyLast() {
        for choice in VoiceEditShortcut.allCases {
            guard let shortcut = choice.shortcut else { continue }
            #expect(shortcut != .pasteLast && shortcut != .copyLast)
        }
    }
}

@MainActor @Suite struct VoiceEditHostAdapterTests {
    private func readyHost(output: String?) async -> CleanerHost {
        let model = FakeSmartModel(downloaded: true)
        model.voiceEditOutput = output
        let host = CleanerHost(model: model, level: { .medium })
        host.start()
        for _ in 0..<200 {
            if case .ready = host.state { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return host
    }

    @Test func absentModelIsNotAvailableAndTheEngineReportsIt() async {
        let host = CleanerHost(model: FakeSmartModel(downloaded: false), level: { .medium })
        #expect(await host.isAvailable(waitingUpTo: .milliseconds(50)) == false)
        let result = await VoiceEditEngine(model: host, readinessWait: .milliseconds(50))
            .run(VoiceEditRequest(selection: "hello world", instruction: "make it shorter"))
        #expect(result == .modelUnavailable)
    }

    @Test func readyHostGeneratesAPreviewThroughTheEngine() async {
        let host = await readyHost(output: "hi")
        #expect(await host.isAvailable(waitingUpTo: .seconds(1)))
        let result = await VoiceEditEngine(model: host)
            .run(VoiceEditRequest(selection: "hello world", instruction: "make it shorter"))
        #expect(result == .preview(replacement: "hi", instruction: "make it shorter"))
    }

    @Test func hostOutputThatEchoesThePromptIsRefused() async {
        let host = await readyHost(output: nil)
        let result = await VoiceEditEngine(model: host)
            .run(VoiceEditRequest(selection: "hello world", instruction: "make it shorter"))
        guard case .refused = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
    }
}
