import CryptoKit
import Foundation
import os

/// How the model pass ended. The raw values are what the store's `cleanup_outcome` holds.
public enum SmartOutcome: String, Sendable, Equatable {
    case ok
    case skipped
    case timeout
    case guardRejected = "guard-rejected"
    case failed
}

/// Which model produced a cleanup, for the store's `cleaner_id`, `cleaner_rev` and `prompt_sha`.
public struct SmartCleanerInfo: Sendable, Equatable {
    public var id: String
    public var revision: String?

    public init(id: String, revision: String? = nil) {
        self.id = id
        self.revision = revision
    }
}

public struct SmartCleanupRequest: Sendable {
    /// The deterministic pipeline's output.
    public var text: String
    public var level: CleanupLevel
    public var style: StyleOptions
    public var destination: S1MiniControls.Destination
    public var dictionary: [DictionaryRule]
    public var snippets: [Snippet]

    public init(
        text: String, level: CleanupLevel, style: StyleOptions = .formal,
        destination: S1MiniControls.Destination = .general, dictionary: [DictionaryRule] = [], snippets: [Snippet] = []
    ) {
        self.text = text
        self.level = level
        self.style = style
        self.destination = destination
        self.dictionary = dictionary
        self.snippets = snippets
    }
}

public struct SmartCleanupResult: Sendable, Equatable {
    /// What to deliver: the checked model text after the dictionary and style pass, or the request's text.
    public var text: String
    /// The model's own output, when it was accepted.
    public var modelText: String?
    public var outcome: SmartOutcome
    /// Why the output was thrown away, for the log.
    public var rejection: String?
    public var milliseconds: Int
    /// Changes the dictionary and style pass made to the model's output.
    public var postEdits: [EditOp]
    public var promptSHA: String?

    /// The model's change as one store edit, or nil when it left the text alone.
    public func edit(from detText: String) -> EditOp? {
        guard let modelText, modelText != detText else { return nil }
        return EditOp(
            stage: SmartCleanup.stageName, kind: .replace, fromText: detText, toText: modelText,
            wordDelta: TextMetrics.wordCount(modelText) - TextMetrics.wordCount(detText), position: 0
        )
    }
}

/// The model pass: skips inputs the model can't help with, runs one generation at a time under a time budget,
/// checks the output against the text it came from, then reapplies the dictionary and the style, which the model
/// knows nothing about. Anything that goes wrong returns the input text, so a dictation is never lost.
public actor SmartCleanup {
    public static let stageName = "llm"
    public static let minWords = 4
    public static let maxWords = 400
    public static let budgetBase = Duration.milliseconds(400)
    public static let budgetPerWord = Duration.milliseconds(12)
    public static let budgetCap = Duration.milliseconds(2500)

    /// 400 ms plus 12 ms a word, at most 2.5 s.
    public static func defaultBudget(words: Int) -> Duration {
        min(budgetBase + budgetPerWord * words, budgetCap)
    }

    /// The control lines to run, in order. S1-mini has no control for rewording, so `medium` is its strongest
    /// editing setting: the formal register, which smooths colloquialisms and expands contractions. Formal alone
    /// leaves self-corrections in ("at 2, actually, 3"), so it runs second, on text the semi-formal pass has
    /// already settled. It applies only to the formal writing style; casual styles keep their contractions, and
    /// there `medium` differs from `light` in the output check alone. Casing and the final full stop are the
    /// style stage's job after the model, so the model always gets a sentence-case register.
    public static func passes(
        level: CleanupLevel, style: StyleOptions, destination: S1MiniControls.Destination = .general
    ) -> [S1MiniControls] {
        let settle = S1MiniControls(styling: .semiFormal, structure: .lists, destination: destination)
        guard level == .medium, style.preset == .formal else { return [settle] }
        return [settle, S1MiniControls(styling: .formal, structure: .lists, destination: destination)]
    }

    private let cleaner: any TextCleaner
    private let budget: @Sendable (Int) -> Duration
    private let clock = ContinuousClock()
    private var current: Task<Result<String, Error>, Never>?

    public init(cleaner: any TextCleaner, budget: @escaping @Sendable (Int) -> Duration = SmartCleanup.defaultBudget) {
        self.cleaner = cleaner
        self.budget = budget
    }

    public func run(_ request: SmartCleanupRequest) async -> SmartCleanupResult {
        let start = clock.now
        let words = TextMetrics.wordCount(request.text)
        func finish(
            _ outcome: SmartOutcome, text: String? = nil, model: String? = nil, rejection: String? = nil,
            post: [EditOp] = [], sha: String? = nil
        ) -> SmartCleanupResult {
            let elapsed = clock.now - start
            let ms = Int((Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15).rounded())
            return SmartCleanupResult(
                text: text ?? request.text, modelText: model, outcome: outcome, rejection: rejection, milliseconds: ms,
                postEdits: post, promptSHA: sha
            )
        }
        guard request.level.needsModel, words >= Self.minWords, words <= Self.maxWords else { return finish(.skipped) }

        let deadline = start + budget(words)
        // A generation that outlived its own timeout still holds the model; wait for it, within this budget.
        while let busy = current {
            guard await Self.finished(busy, by: deadline, clock: clock) else { return finish(.timeout) }
            if current == busy { current = nil }
        }

        let passes = Self.passes(level: request.level, style: request.style, destination: request.destination)
        let cleaner = cleaner
        let text = CorrectionCommas.apply(request.text)
        let work = Task { () -> Result<String, Error> in
            do {
                var output = text
                for controls in passes {
                    output = CleanupPrompt.sanitize(try await cleaner.clean(output, context: CleanupContext(s1Controls: controls)))
                    if output.isEmpty { break }
                }
                return .success(output)
            } catch {
                return .failure(error)
            }
        }
        current = work
        let sha = S1MiniPrompt.promptSHA(passes.map(\.line))
        guard await Self.finished(work, by: deadline, clock: clock) else {
            work.cancel()
            return finish(.timeout, sha: sha)
        }
        if current == work { current = nil }

        switch await work.value {
        case let .failure(error):
            return finish(.failed, rejection: String(describing: error), sha: sha)
        case let .success(output):
            let model = SmartCleanupGuard.restoringTerminal(input: request.text, output: CleanupPrompt.sanitize(output))
            let post = Self.reapply(model, request: request)
            if let reason = SmartCleanupGuard.rejection(
                input: request.text, output: post.text, level: request.level, dictionary: request.dictionary,
                snippets: request.snippets
            ) {
                return finish(.guardRejected, rejection: reason, sha: sha)
            }
            return finish(.ok, text: post.text, model: model, post: post.edits, sha: sha)
        }
    }

    /// The dictionary and the style, over the model's text. Both are ours; the model takes no vocabulary.
    static func reapply(_ text: String, request: SmartCleanupRequest) -> TextPipelineResult {
        let options = TextPipelineOptions(
            fillers: false, spokenCommands: false, selfCorrection: false, numbers: false, dictionary: true, snippets: false, blend: false,
            whitespace: true, style: request.style
        )
        return TextPipeline().run(TextPipelineInput(text: text, dictionary: request.dictionary, options: options))
    }

    /// Whether `task` finished before `deadline`. The watcher on the task is not a child of this call, so a task
    /// that ignores cancellation can't hold the caller past the deadline.
    private static func finished(_ task: Task<Result<String, Error>, Never>, by deadline: ContinuousClock.Instant, clock: ContinuousClock) async -> Bool {
        let once = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { continuation in
            @Sendable func settle(_ value: Bool) {
                let first = once.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: value) }
            }
            let sleeper = Task {
                try? await clock.sleep(until: deadline)
                settle(false)
            }
            Task {
                _ = await task.value
                sleeper.cancel()
                settle(true)
            }
        }
    }
}

extension S1MiniPrompt {
    /// A short hash of the system prompt and the control lines, for the store's `prompt_sha`.
    public static func promptSHA(_ controlLines: [String]) -> String {
        let digest = SHA256.hash(data: Data(([system] + controlLines).joined(separator: "\n").utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
