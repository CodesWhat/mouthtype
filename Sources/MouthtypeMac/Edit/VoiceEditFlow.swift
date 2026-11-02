import Foundation
import MouthtypeCore
import Observation

/// What the flow needs from the engine, so the state machine is tested with a fake.
protocol VoiceEditing: Sendable {
    func run(_ request: VoiceEditRequest) async -> VoiceEditResult
}

extension VoiceEditEngine: VoiceEditing {}

/// Records one spoken instruction and returns its text. Nothing it hears is written anywhere.
@MainActor protocol VoiceInstructionRecording: AnyObject {
    func start() async throws
    /// Stops recording and transcribes it. An empty string means nothing was heard.
    func finish() async throws -> String
    func cancel() async
}

/// Why the flow declined to start. All of these are checked before anything is recorded.
enum VoiceEditFlowRefusal: Equatable {
    case busy
    case secureField
    case noSelection
    case captureTimedOut
    case selectionTooLong
    case modelUnavailable(String)

    var message: String {
        switch self {
        case .busy: "Finish the current dictation or file job first."
        case .secureField: "Password and other protected fields aren’t read."
        case .noSelection: "Select some text in an accessible text field first."
        case .captureTimedOut: "Couldn’t read the selection in time. Try again."
        case .selectionTooLong:
            "Select \(VoiceEditCoordinator.selectionLimit.formatted()) characters or fewer to edit by voice."
        case let .modelUnavailable(reason): reason
        }
    }
}

/// How a voice edit ended. Every failure leaves the original untouched.
enum VoiceEditEnd: Equatable {
    case refused(VoiceEditFlowRefusal)
    case recordingFailed
    case noInstruction
    case engineRefused(VoiceEditRefusal)
    case timedOut
    case modelUnavailable
    case modelFailed
    /// The selection or focus changed before Accept, or the app wouldn't take the write.
    case stale
    case accepted

    var message: String {
        switch self {
        case let .refused(refusal): refusal.message
        case .recordingFailed: "Couldn’t record the instruction. Check the microphone and try again."
        case .noInstruction: "Didn’t hear an instruction. Try again."
        case let .engineRefused(refusal): Self.message(for: refusal)
        case .timedOut: "The local model took too long. The text is unchanged."
        case .modelUnavailable: "The Thorough cleanup model isn’t available. The text is unchanged."
        case .modelFailed: "The local model failed. The text is unchanged."
        case .stale: "The selection or focus changed, so nothing was replaced. Select the text again and retry."
        case .accepted: "Replacement requested. Press Cmd-Z in that app to undo."
        }
    }

    var isFailure: Bool { self != .accepted }

    private static func message(for refusal: VoiceEditRefusal) -> String {
        switch refusal {
        case .emptySelection: "Select some text in an accessible text field first."
        case .emptyInstruction: "Didn’t hear an instruction. Try again."
        case .modelDeclined: "The model couldn’t make that edit. The text is unchanged."
        case .unchanged: "That instruction wouldn’t change the text."
        case .notShorter: "The model’s result wasn’t shorter, so it was dropped. The text is unchanged."
        case .tooLong: "The model’s result was far longer than the selection, so it was dropped."
        case .emptyOutput, .chatter, .echoesPromptFraming, .echoesInstruction, .controlCharacters:
            "The model didn’t return a usable edit. Try rephrasing the instruction. The text is unchanged."
        }
    }
}

enum VoiceEditPhase: Equatable {
    case idle
    case readingSelection
    case recording
    case transcribing
    case generating
    /// The replacement is on screen and waiting for Accept or Cancel.
    case preview
    case ended(VoiceEditEnd)

    var isActive: Bool {
        switch self {
        case .idle, .ended: false
        default: true
        }
    }
}

/// The Edit Selection by Voice flow: read the selection, record one instruction, run the engine, preview, then Accept
/// through the editor's own revalidation. It is separate from dictation: the instruction never reaches the insertion
/// pipeline, and the selection, instruction and replacement are held in memory only until the flow ends.
@MainActor @Observable final class VoiceEditCoordinator {
    nonisolated static let selectionLimit = 8_000
    nonisolated static let defaultRecordingLimit: Duration = .seconds(20)

    private(set) var phase = VoiceEditPhase.idle
    /// What the user asked for, shown with the preview.
    private(set) var instruction = ""
    private(set) var replacement = ""
    /// The app that owns the selection, for the panel's subtitle.
    private(set) var sourceApp: String?

    @ObservationIgnored private let editor: any SelectionEditing
    @ObservationIgnored private let recorder: any VoiceInstructionRecording
    @ObservationIgnored private let engine: any VoiceEditing
    @ObservationIgnored private let busy: @MainActor () -> Bool
    @ObservationIgnored private let secureContext: @MainActor () -> Bool
    @ObservationIgnored private let modelUnavailableReason: @MainActor () -> String?
    @ObservationIgnored private let appName: @MainActor (pid_t) -> String?
    @ObservationIgnored private let changed: @MainActor () -> Void
    @ObservationIgnored private let captureBudget: TimeInterval
    @ObservationIgnored private let recordingLimit: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var selection: SelectedText?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pipeline: Task<Void, Never>?
    @ObservationIgnored private var limitTask: Task<Void, Never>?

    init(
        editor: any SelectionEditing, recorder: any VoiceInstructionRecording, engine: any VoiceEditing,
        busy: @escaping @MainActor () -> Bool = { false }, secureContext: @escaping @MainActor () -> Bool = { false },
        modelUnavailableReason: @escaping @MainActor () -> String? = { nil },
        appName: @escaping @MainActor (pid_t) -> String? = { _ in nil }, changed: @escaping @MainActor () -> Void = {},
        captureBudget: TimeInterval = 0.5, recordingLimit: Duration = VoiceEditCoordinator.defaultRecordingLimit,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.editor = editor
        self.recorder = recorder
        self.engine = engine
        self.busy = busy
        self.secureContext = secureContext
        self.modelUnavailableReason = modelUnavailableReason
        self.appName = appName
        self.changed = changed
        self.captureBudget = captureBudget
        self.recordingLimit = recordingLimit
        self.sleep = sleep
    }

    var canAccept: Bool { phase == .preview && !replacement.isEmpty }

    /// Checks everything that can be checked before recording, reads the selection and starts recording the instruction.
    /// Returns once recording has started or the flow has ended.
    func begin() async {
        guard !phase.isActive else { return }
        reset()
        generation += 1
        let id = generation
        if busy() { return end(.refused(.busy)) }
        if secureContext() { return end(.refused(.secureField)) }
        if let reason = modelUnavailableReason() { return end(.refused(.modelUnavailable(reason))) }
        setPhase(.readingSelection)
        let captured: SelectedText
        do {
            captured = try await editor.captureOffMain(budget: captureBudget)
        } catch {
            guard id == generation else { return }
            return end(.refused((error as? SelectionCleanupError) == .timedOut ? .captureTimedOut : .noSelection))
        }
        guard id == generation else { return }
        if captured.text.allSatisfy(\.isWhitespace) { return end(.refused(.noSelection)) }
        if captured.text.count > Self.selectionLimit { return end(.refused(.selectionTooLong)) }
        selection = captured
        sourceApp = appName(captured.pid)
        setPhase(.recording)
        do {
            try await recorder.start()
        } catch {
            guard id == generation else { return }
            return end(.recordingFailed)
        }
        guard id == generation else {
            await recorder.cancel()
            return
        }
        limitTask = Task { [weak self, sleep, recordingLimit] in
            try? await sleep(recordingLimit)
            guard !Task.isCancelled else { return }
            await self?.stopRecording()
        }
    }

    /// Ends the recording, transcribes the instruction and runs the engine. Returns when the flow reaches a preview or ends.
    func stopRecording() async {
        guard phase == .recording else { return }
        limitTask?.cancel()
        limitTask = nil
        setPhase(.transcribing)
        let id = generation
        let task = Task { await self.process(id) }
        pipeline = task
        await task.value
    }

    private func process(_ id: Int) async {
        let heard: String
        do {
            heard = try await recorder.finish()
        } catch {
            guard id == generation else { return }
            return end(.recordingFailed)
        }
        guard id == generation, let selection else { return }
        let spoken = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return end(.noInstruction) }
        setPhase(.generating)
        let result = await engine.run(VoiceEditRequest(selection: selection.text, instruction: spoken))
        guard id == generation else { return }
        switch result {
        case let .preview(text, instruction):
            self.instruction = instruction
            replacement = text
            setPhase(.preview)
        case let .refused(refusal): end(.engineRefused(refusal))
        case .cancelled:
            reset()
            setPhase(.idle)
        case .timedOut: end(.timedOut)
        case .modelUnavailable: end(.modelUnavailable)
        case .modelFailed: end(.modelFailed)
        }
    }

    /// Replaces the selection through the editor's revalidation, once. Whatever the outcome, nothing is kept afterwards.
    func accept() {
        guard canAccept, let selection else { return }
        guard !busy() else { return end(.refused(.busy)) }
        let text = SelectionCleanupModel.restoringBoundaryWhitespace(of: selection.text, in: replacement)
        end(editor.replace(selection, with: text) ? .accepted : .stale)
    }

    /// Drops whatever is in flight. The original text is never touched.
    func cancel() async {
        let wasRecording = phase == .recording || phase == .transcribing
        generation += 1
        limitTask?.cancel()
        limitTask = nil
        pipeline?.cancel()
        pipeline = nil
        reset()
        if phase != .idle { setPhase(.idle) }
        if wasRecording { await recorder.cancel() }
    }

    private func end(_ outcome: VoiceEditEnd) {
        limitTask?.cancel()
        limitTask = nil
        pipeline = nil
        reset()
        setPhase(.ended(outcome))
    }

    private func reset() {
        selection = nil
        instruction = ""
        replacement = ""
        sourceApp = nil
    }

    private func setPhase(_ new: VoiceEditPhase) {
        phase = new
        changed()
    }
}
