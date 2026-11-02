import Foundation

/// What the engine needs from the local model. The Thorough-model host adapts to it; tests use a fake.
public protocol VoiceEditModel: Sendable {
    /// Whether the model can generate, waiting up to `limit` for a load in progress.
    func isAvailable(waitingUpTo limit: Duration) async -> Bool
    /// Raw model output for the prompt. Throws `CancellationError` when cancelled, `CleanerError.unavailable` when the
    /// model went away.
    func generate(_ prompt: VoiceEditPrompt) async throws -> String
}

public enum VoiceEditResult: Sendable, Equatable {
    /// A replacement to preview. Nothing has been inserted; the caller owns Accept.
    case preview(replacement: String, instruction: String)
    case refused(VoiceEditRefusal)
    case cancelled
    case timedOut
    case modelUnavailable
    case modelFailed
}

/// Request to prompt to local model to guard to result. It never touches the selection and keeps nothing: the request,
/// prompt and output live in this call's locals, and nothing here logs or writes.
public actor VoiceEditEngine {
    public static let defaultTimeout = Duration.seconds(30)
    public static let defaultReadinessWait = Duration.seconds(5)

    private let model: any VoiceEditModel
    private let timeout: Duration
    private let readinessWait: Duration
    private let nonces: @Sendable () -> String

    public init(
        model: any VoiceEditModel, timeout: Duration = VoiceEditEngine.defaultTimeout,
        readinessWait: Duration = VoiceEditEngine.defaultReadinessWait,
        nonces: @escaping @Sendable () -> String = VoiceEditPrompt.randomNonce
    ) {
        self.model = model
        self.timeout = timeout
        self.readinessWait = readinessWait
        self.nonces = nonces
    }

    public func run(_ request: VoiceEditRequest) async -> VoiceEditResult {
        guard !request.selection.allSatisfy(\.isWhitespace) else { return .refused(.emptySelection) }
        guard !request.instruction.allSatisfy(\.isWhitespace) else { return .refused(.emptyInstruction) }
        if Task.isCancelled { return .cancelled }
        guard await model.isAvailable(waitingUpTo: readinessWait) else {
            return Task.isCancelled ? .cancelled : .modelUnavailable
        }
        if Task.isCancelled { return .cancelled }

        let prompt = VoiceEditPrompt.make(for: request, nonces: nonces)
        let model = model
        let work = Task { () -> Result<String, Error> in
            do { return .success(try await model.generate(prompt)) } catch { return .failure(error) }
        }
        let timeout = timeout
        let finished = await withTaskCancellationHandler {
            await SmartCleanup.waitForCompletion(work, sleep: { try await Task.sleep(for: timeout) })
        } onCancel: {
            work.cancel()
        }
        if Task.isCancelled {
            work.cancel()
            return .cancelled
        }
        guard finished else {
            work.cancel()
            return .timedOut
        }
        switch await work.value {
        case let .success(output):
            switch VoiceEditGuard.judge(selection: request.selection, instruction: request.instruction, output: output) {
            case let .accepted(replacement): return .preview(replacement: replacement, instruction: request.instruction)
            case let .refused(reason): return .refused(reason)
            }
        case let .failure(error):
            if error is CancellationError { return .cancelled }
            if case CleanerError.unavailable = error { return .modelUnavailable }
            return .modelFailed
        }
    }
}
