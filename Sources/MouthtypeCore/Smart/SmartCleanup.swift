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
    public var context: InsertionContext?
    public var appName: String?
    /// Phrases swearing removal must leave alone after the model, such as snippet triggers the caller expands itself.
    public var protectedPhrases: [String]

    public init(
        text: String, level: CleanupLevel, style: StyleOptions = .formal,
        destination: S1MiniControls.Destination = .general, dictionary: [DictionaryRule] = [], snippets: [Snippet] = [],
        context: InsertionContext? = nil, appName: String? = nil, protectedPhrases: [String] = []
    ) {
        self.text = text
        self.level = level
        self.style = style
        self.destination = destination
        self.dictionary = dictionary
        self.snippets = snippets
        self.context = context
        self.appName = appName
        self.protectedPhrases = protectedPhrases
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
/// checks the output against the text it came from, then reapplies the dictionary, cursor blending and style.
/// Anything that goes wrong returns the input text, so a dictation is never lost.
public actor SmartCleanup {
    public static let stageName = "llm"
    public static let minWords = 2
    public static let maxWords = 400
    public static let budgetBase = Duration.milliseconds(400)
    public static let budgetPerWord = Duration.milliseconds(16)
    public static let budgetCap = Duration.seconds(5)
    public static let qualityBase = Duration.milliseconds(1200)
    public static let qualityPerWord = Duration.milliseconds(45)
    public static let qualityCap = Duration.seconds(20)

    /// 400 ms plus 16 ms a word, at most 5 s. The native model decodes about 8 ms a word on a quiet machine, so this
    /// leaves room for a loaded one. A take that finishes early returns early; the budget only bounds a stall.
    public static func defaultBudget(words: Int) -> Duration {
        min(budgetBase + budgetPerWord * words, budgetCap)
    }

    /// 1.2 s plus 45 ms a word, at most 20 s. Gemma decodes about 14 ms a token (roughly 20 ms a word) with the shared
    /// prompt prefix cached, so N words need about 20 ms times N when quiet and two to three times that when busy.
    public static func qualityBudget(words: Int) -> Duration {
        min(qualityBase + qualityPerWord * words, qualityCap)
    }

    /// Native cleanup preserves the spoken register; casing and punctuation are applied afterward.
    public static func passes(
        level: CleanupLevel, style: StyleOptions, destination: S1MiniControls.Destination = .general
    ) -> [S1MiniControls] {
        [S1MiniControls(styling: .semiFormal, structure: .lists, destination: destination)]
    }

    private let cleaner: any TextCleaner
    private let budget: @Sendable (Int) -> Duration
    private let clock = ContinuousClock()
    private struct Draft: Sendable {
        var text: String
        var guardInput: String
        var resolvedInput: String?
        var ordinary: [NameJoining.Candidate]
    }
    private var current: Task<Result<Draft, Error>, Never>?
    /// The explicit selected-text transform holding the model, if any. Dictation waits for it like a stuck generation.
    private var transforming: Task<Result<String, Error>, Never>?
    private var modelPaused = false
    private let customBudget: Bool

    public init(cleaner: any TextCleaner, budget: (@Sendable (Int) -> Duration)? = nil) {
        self.cleaner = cleaner
        self.budget = budget ?? (cleaner.usesNativeControls ? SmartCleanup.defaultBudget : SmartCleanup.qualityBudget)
        self.customBudget = budget != nil
    }

    /// Settle a timed-out generation before unloading its model or exiting the process.
    /// Dictation deadlines still return fallback immediately; only explicit teardown waits here.
    public func waitForPendingWork() async {
        while true {
            if let busy = current {
                _ = await busy.value
                if current == busy { current = nil }
            } else if let busy = transforming {
                _ = await busy.value
                if transforming == busy { transforming = nil }
            } else {
                return
            }
        }
    }

    /// Runs one explicit transform on the model, one generation at a time with dictation cleanup. It waits for any
    /// earlier generation (including a cancelled one still settling) and holds the model until its own generation has
    /// finished, so unload and the next request wait for it. A transform in progress is never cut short by dictation.
    public func transform(_ kind: TextTransform, text: String) async throws -> String {
        func unloading() -> CleanerError {
            .unavailable(reason: "The cleanup model is unloading. Try again in a moment.")
        }
        while true {
            try Task.checkCancellation()
            if let busy = current {
                _ = await busy.value
                if current == busy { current = nil }
            } else if let busy = transforming {
                _ = await busy.value
                if transforming == busy { transforming = nil }
            } else {
                break
            }
        }
        guard !modelPaused else { throw unloading() }
        try Task.checkCancellation()
        let cleaner = cleaner
        let work = Task { () -> Result<String, Error> in
            do { return .success(try await cleaner.clean(text, context: CleanupContext(transform: kind))) } catch { return .failure(error) }
        }
        transforming = work
        let outcome = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        if transforming == work { transforming = nil }
        return try outcome.get()
    }

    public func pauseForModelUnload() async {
        modelPaused = true
        await waitForPendingWork()
    }

    public func resumeAfterModelLoad() { modelPaused = false }

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
        guard !modelPaused, request.level.needsModel, words >= Self.minWords, words <= Self.maxWords else { return finish(.skipped) }

        let context = CleanupContext(vocabulary: DictionaryReplacer(rules: request.dictionary).cleanupVocabulary(), appName: request.appName,
            level: request.level, before: request.context?.before, after: request.context?.after,
            omitProfanity: request.style == .formal)
        let joining = NameJoining.candidates(in: request.text,
            spellings: CleanupPrompt.nearbySpellings(context) + request.dictionary.map(\.written))
        let text = CorrectionCommas.apply(request.text)
        let settleCorrections = !cleaner.usesNativeControls && text.range(
            of: #"(?:,\s*|[.!?]\s+)(?:actually|no\s+wait|no\s+sorry|sorry|i\s+mean|or\s+rather|make\s+that|scratch\s+that)\b"#,
            options: [.regularExpression, .caseInsensitive]) != nil
        let allowance = customBudget || cleaner.usesNativeControls ? budget(words)
            : min(budget(words) * (settleCorrections ? 2 : 1), Self.qualityCap)
        let deadline = start + allowance
        // A generation that outlived its own timeout still holds the model; wait for it, within this budget.
        while true {
            if let busy = current {
                guard await Self.finished(busy, by: deadline, clock: clock) else { return finish(.timeout) }
                if current == busy { current = nil }
            } else if let busy = transforming {
                guard await Self.finished(busy, by: deadline, clock: clock) else { return finish(.timeout) }
                if transforming == busy { transforming = nil }
            } else {
                break
            }
        }

        guard !modelPaused else { return finish(.skipped) }
        let passes = cleaner.usesNativeControls
            ? Self.passes(level: request.level, style: request.style, destination: request.destination)
            : [S1MiniControls.benchmark]
        let cleaner = cleaner
        let approved = joining.filter { NameJoining.isProjectReference($0, in: request.text) }
        let correctionContext = CleanupContext(correctionsOnly: true)
        let work = Task { () -> Result<Draft, Error> in
            do {
                let ordinary = joining.filter { !approved.contains($0) }
                let guardInput = NameJoining.applying(approved, to: request.text)
                var output = CorrectionCommas.apply(guardInput)
                var resolvedInput: String?
                if settleCorrections {
                    try Task.checkCancellation()
                    output = CleanupPrompt.sanitize(try await cleaner.clean(output, context: correctionContext), input: guardInput)
                    resolvedInput = output
                    if output.isEmpty { return .success(Draft(text: output, guardInput: guardInput, resolvedInput: resolvedInput, ordinary: ordinary)) }
                }
                for controls in passes {
                    try Task.checkCancellation()
                    var passContext = context
                    passContext.s1Controls = controls
                    output = CleanupPrompt.sanitize(try await cleaner.clean(output, context: passContext), input: guardInput)
                    if output.isEmpty { break }
                }
                return .success(Draft(text: output, guardInput: guardInput, resolvedInput: resolvedInput, ordinary: ordinary))
            } catch {
                return .failure(error)
            }
        }
        current = work
        var description = cleaner.usesNativeControls
            ? ([S1MiniPrompt.system] + passes.map(\.line)).joined(separator: "\n")
            : CleanupPrompt.system(for: context) + CleanupPrompt.reference(context)
        if settleCorrections { description = CleanupPrompt.system(for: correctionContext) + "\n" + description }
        if !joining.isEmpty { description += "\njoined-spelling-software-context-v1" }
        let sha = SHA256.hash(data: Data(description.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        guard await Self.finished(work, by: deadline, clock: clock) else {
            work.cancel()
            return finish(.timeout, sha: sha)
        }
        if current == work { current = nil }

        switch await work.value {
        case let .failure(error):
            return finish(.failed, rejection: String(describing: error), sha: sha)
        case let .success(draft):
            let model = SmartCleanupGuard.restoringMeridiem(input: request.text, output: SmartCleanupGuard.restoringTerminal(
                input: request.text, output: CleanupPrompt.sanitize(draft.text, input: request.text)))
            if SmartCleanupGuard.copiesSurroundingText(input: request.text, output: model,
                references: [context.before, context.after].compactMap { $0 }) {
                return finish(.guardRejected, rejection: "surrounding text copied into output", sha: sha)
            }
            let restoredNames = NameJoining.candidates(in: model, spellings: approved.map(\.written))
                .filter { NameJoining.isProjectReference($0, in: model) }
            let post = Self.reapply(NameJoining.applying(restoredNames, to: model), request: request,
                deferredNames: Set(joining.map(\.written)))
            guard NameJoining.preservesOrdinary(draft.ordinary, in: post.text) else {
                return finish(.guardRejected, rejection: "ordinary words changed into a name", sha: sha)
            }
            if let reason = SmartCleanupGuard.rejection(
                input: draft.guardInput, output: post.text, level: request.level, dictionary: request.dictionary,
                snippets: request.snippets, nearbySpellings: CleanupPrompt.nearbySpellings(context), resolvedInput: draft.resolvedInput
            ) {
                return finish(.guardRejected, rejection: reason, sha: sha)
            }
            return finish(.ok, text: post.text, model: model, post: post.edits, sha: sha)
        }
    }

    /// Reapply exact dictionary spelling, cursor blending and style after generation.
    static func reapply(_ text: String, request: SmartCleanupRequest, deferredNames: Set<String> = []) -> TextPipelineResult {
        let options = TextPipelineOptions(
            fillers: false, spokenCommands: false, selfCorrection: false, numbers: false, dictionary: true, snippets: false, blend: request.context != nil,
            whitespace: true, style: request.style
        )
        let rules = request.dictionary.filter { !$0.isJoinedSpelling || !deferredNames.contains($0.written) }
        return TextPipeline().run(TextPipelineInput(
            text: text, dictionary: rules, context: request.context, options: options,
            protectedPhrases: request.protectedPhrases + request.dictionary.map(\.heard)))
    }

    /// Whether `task` finished before `deadline`. The watcher on the task is not a child of this call, so a task
    /// that ignores cancellation can't hold the caller past the deadline.
    private static func finished<Value: Sendable>(_ task: Task<Value, Never>, by deadline: ContinuousClock.Instant, clock: ContinuousClock) async -> Bool {
        await waitForCompletion(task, sleep: { try await clock.sleep(until: deadline) })
    }

    static func waitForCompletion<Value: Sendable>(
        _ task: Task<Value, Never>, sleep: @escaping @Sendable () async throws -> Void,
        cancelTimer: @escaping @Sendable (Task<Void, Never>) -> Void = { $0.cancel() }
    ) async -> Bool {
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
                do { try await sleep() } catch { return }
                settle(false)
            }
            Task {
                _ = await task.value
                settle(true)
                cancelTimer(sleeper)
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
