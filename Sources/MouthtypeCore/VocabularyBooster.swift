import FluidAudio
import Foundation
import os
import Synchronization

/// Where recognition-time vocabulary boosting stands, for a status line in Settings.
public enum VocabularyBoostStatus: Sendable, Equatable {
    case off
    case downloading(fraction: Double?)
    case preparing
    case ready
    case failed(String)

    public var text: String {
        switch self {
        case .off: return ""
        case let .downloading(fraction):
            guard let fraction else { return "Downloading the vocabulary model\u{2026}" }
            return "Downloading the vocabulary model: \(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
        case .preparing: return "Preparing the vocabulary model\u{2026}"
        case .ready: return "Vocabulary model ready"
        case let .failed(message): return "Vocabulary model unavailable, dictating without it: \(message)"
        }
    }
}

extension Notification.Name {
    /// Posted (any thread) when `VocabularyBoostStatusCenter.current` changes.
    public static let vocabularyBoostStatusChanged = Notification.Name("MouthtypeVocabularyBoostStatusChanged")
}

/// Process-wide latest boost status. The engine writes it; Settings reads it and listens for the notification.
public enum VocabularyBoostStatusCenter {
    private static let state = Mutex<VocabularyBoostStatus>(.off)

    public static var current: VocabularyBoostStatus { state.withLock { $0 } }

    public static func set(_ status: VocabularyBoostStatus) {
        let changed = state.withLock { value -> Bool in
            guard value != status else { return false }
            value = status
            return true
        }
        if changed { NotificationCenter.default.post(name: .vocabularyBoostStatusChanged, object: nil) }
    }
}

/// What a rescoring pass decided. Text is only trusted when `wasModified`.
struct VocabularyRescore: Sendable, Equatable {
    var text: String
    var wasModified: Bool
    var appliedTerms: [String]

    init(text: String, wasModified: Bool, appliedTerms: [String]) {
        self.text = text
        self.wasModified = wasModified
        self.appliedTerms = appliedTerms
    }
}

/// The seam over FluidAudio's CTC session, so tests never load a model.
protocol VocabularyRescoring: Sendable {
    /// Nil means nothing to report. It must never throw: boosting cannot fail a take.
    func rescore(text: String, tokenTimings: [TokenTiming], samples: [Float]) async -> VocabularyRescore?
}

/// A boosted transcript: the new text and the terms that ended up in it.
struct BoostedText: Sendable, Equatable {
    var text: String
    var appliedTerms: [String]
}

/// Builds and caches one rescoring session per vocabulary and runs it, bounded, after the primary transcript.
/// Every failure path returns nil so the caller keeps the unboosted text.
actor VocabularyBooster {
    typealias Prepare = @Sendable (VocabularyBias, @escaping @Sendable (VocabularyBoostStatus) -> Void) async throws
        -> any VocabularyRescoring

    static let defaultTimeout: Duration = .milliseconds(1500)
    static let defaultRetryAfter: Duration = .seconds(300)

    private static let log = Logger(subsystem: "com.codeswhat.mouthtype", category: "vocabulary-boost")

    private let prepare: Prepare
    private let release: @Sendable () async -> Void
    private let timeout: Duration
    private let retryAfter: Duration
    private let report: @Sendable (VocabularyBoostStatus) -> Void

    private var bias: VocabularyBias?
    private var session: (any VocabularyRescoring)?
    private var building: Task<Void, Never>?
    private var failedAt: ContinuousClock.Instant?
    private var generation = 0
    /// True while a rescoring call is still running, including one its caller already gave up on. FluidAudio's
    /// scoring is synchronous and cancelling the task does not stop it, so a new take must not stack another on top.
    private var rescoring = false
    /// How many sessions were built, for tests and the log.
    private(set) var sessionsBuilt = 0

    init(
        timeout: Duration = VocabularyBooster.defaultTimeout,
        retryAfter: Duration = VocabularyBooster.defaultRetryAfter,
        prepare: @escaping Prepare,
        release: @escaping @Sendable () async -> Void = {},
        report: @escaping @Sendable (VocabularyBoostStatus) -> Void = { VocabularyBoostStatusCenter.set($0) }
    ) {
        self.timeout = timeout
        self.retryAfter = retryAfter
        self.prepare = prepare
        self.release = release
        self.report = report
    }

    /// Sets the vocabulary. An unchanged one keeps the cached session; a changed one rebuilds it in the background;
    /// nil or empty releases everything. Never waits for a download, so a take is not held up by one.
    func setBias(_ new: VocabularyBias?) async {
        let new = new?.isEmpty == false ? new : nil
        if new == bias {
            guard new != nil, session == nil, building == nil, let failedAt,
                  ContinuousClock.now - failedAt >= retryAfter else { return }
        }
        generation += 1
        building?.cancel()
        building = nil
        session = nil
        failedAt = nil
        bias = new
        guard let new else {
            report(.off)
            await release()
            return
        }
        start(new, generation: generation)
    }

    /// Resolves once the session for the current vocabulary is built or has failed. For tests and the bench.
    func waitUntilSettled() async {
        await building?.value
    }

    var isReady: Bool { session != nil }

    /// The rescored text, or nil to keep the unboosted one: not ready, nothing changed, timed out, or the rescorer had nothing.
    func boost(text: String, tokenTimings: [TokenTiming], samples: [Float]) async -> BoostedText? {
        guard let session, !tokenTimings.isEmpty, !samples.isEmpty else { return nil }
        guard !rescoring else {
            Self.log.warning("an earlier vocabulary rescoring is still running; using the plain transcript")
            return nil
        }
        rescoring = true
        let outcome = await Self.withTimeout(timeout) { [weak self] in
            let result = await session.rescore(text: text, tokenTimings: tokenTimings, samples: samples)
            await self?.rescoringFinished()
            return result
        }
        guard let outcome else {
            Self.log.warning("vocabulary rescoring passed \(self.timeout.description, privacy: .public); using the plain transcript")
            return nil
        }
        guard let rescore = outcome, rescore.wasModified else { return nil }
        let rebuilt = rescore.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rebuilt.isEmpty else { return nil }
        let boosted = Self.restoringPunctuation(original: text, boosted: rebuilt)
        guard boosted != text else { return nil }
        return BoostedText(text: boosted, appliedTerms: rescore.appliedTerms)
    }

    private func rescoringFinished() { rescoring = false }

    private func start(_ bias: VocabularyBias, generation: Int) {
        report(.preparing)
        let prepare = prepare
        let report = report
        building = Task { [weak self] in
            do {
                let built = try await prepare(bias, report)
                try Task.checkCancellation()
                await self?.finish(built, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                await self?.fail(error, generation: generation)
            }
        }
    }

    private func finish(_ built: any VocabularyRescoring, generation: Int) {
        guard generation == self.generation else { return }
        session = built
        sessionsBuilt += 1
        building = nil
        report(.ready)
    }

    private func fail(_ error: Error, generation: Int) {
        guard generation == self.generation else { return }
        Self.log.error("vocabulary model unavailable: \(error.localizedDescription, privacy: .public)")
        failedAt = .now
        building = nil
        report(.failed(error.localizedDescription))
    }

    /// Runs `operation` and returns its value, or nil if `limit` passes first. The slow call is abandoned, not awaited.
    static func withTimeout<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = Once(continuation)
            let work = Task { once.resolve(await operation()) }
            Task {
                try? await Task.sleep(for: limit)
                once.resolve(nil)
                work.cancel()
            }
        }
    }
}

/// Resumes a continuation exactly once, from whichever racer gets there first.
private final class Once<T: Sendable>: Sendable {
    private let slot: Mutex<CheckedContinuation<T?, Never>?>

    init(_ continuation: CheckedContinuation<T?, Never>) { slot = Mutex(continuation) }

    func resolve(_ value: T?) {
        let waiting = slot.withLock { slot -> CheckedContinuation<T?, Never>? in
            defer { slot = nil }
            return slot
        }
        waiting?.resume(returning: value)
    }
}

extension VocabularyBooster {
    /// One stretch of an alignment between the original words and the rescored words.
    enum Run: Equatable {
        case same(old: Int, new: Int)
        case changed(old: Range<Int>, new: Range<Int>)
    }

    /// Longest-common-subsequence alignment of two word lists, as shared words and the changed stretches between them.
    static func align(_ old: [String], _ new: [String]) -> [Run] {
        let rows = old.count, cols = new.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: cols + 1), count: rows + 1)
        for r in stride(from: rows - 1, through: 0, by: -1) {
            for c in stride(from: cols - 1, through: 0, by: -1) {
                table[r][c] = old[r] == new[c] ? table[r + 1][c + 1] + 1 : max(table[r + 1][c], table[r][c + 1])
            }
        }
        var runs: [Run] = []
        var r = 0, c = 0
        while r < rows || c < cols {
            if r < rows, c < cols, old[r] == new[c] {
                runs.append(.same(old: r, new: c))
                r += 1
                c += 1
                continue
            }
            let (startOld, startNew) = (r, c)
            while r < rows || c < cols {
                if r < rows, c < cols, old[r] == new[c] { break }
                if c >= cols || (r < rows && table[r + 1][c] >= table[r][c + 1]) { r += 1 } else { c += 1 }
            }
            runs.append(.changed(old: startOld..<r, new: startNew..<c))
        }
        return runs
    }

    /// The rescorer rebuilds its text from word timings and can drop the punctuation attached to a word it replaced
    /// ("next to fluid audio." came back as "FluidAudio"). Gives a replaced run back the punctuation its last word
    /// ended with, and the opening punctuation its first word began with, when the new words carry none.
    static func restoringPunctuation(original: String, boosted: String) -> String {
        let old = original.split(whereSeparator: \.isWhitespace).map(String.init)
        var new = boosted.split(whereSeparator: \.isWhitespace).map(String.init)
        for case let .changed(oldRange, newRange) in align(old, new) where !oldRange.isEmpty && !newRange.isEmpty {
            // Adjacent replacements share one changed span. When it replaces word for word, each pair keeps its own punctuation.
            func restoreTail(_ o: Int, _ n: Int) {
                let tail = old[o].reversed().prefix { !$0.isLetter && !$0.isNumber }
                if !tail.isEmpty, let end = new[n].last, end.isLetter || end.isNumber {
                    new[n] += String(tail.reversed())
                }
            }
            func restoreHead(_ o: Int, _ n: Int) {
                let head = old[o].prefix { !$0.isLetter && !$0.isNumber }
                if !head.isEmpty, let start = new[n].first, start.isLetter || start.isNumber {
                    new[n] = String(head) + new[n]
                }
            }
            if oldRange.count == newRange.count {
                for (o, n) in zip(oldRange, newRange) {
                    restoreTail(o, n)
                    restoreHead(o, n)
                }
            } else {
                restoreTail(oldRange.upperBound - 1, newRange.upperBound - 1)
                restoreHead(oldRange.lowerBound, newRange.lowerBound)
            }
        }
        return new.joined(separator: " ")
    }

    /// Re-times `words` to `text` after a replacement. Words that survive keep their own times. A changed run
    /// takes the span of the words it replaced, shared evenly among its new words, with the lowest confidence
    /// of the originals. A run that replaces nothing (pure insertion) is placed zero-width after the word before it.
    static func realign(_ words: [WordTiming], to text: String) -> [WordTiming] {
        let new = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, !new.isEmpty else { return [] }
        var result: [WordTiming] = []
        for run in align(words.map(\.word), new) {
            switch run {
            case let .same(old, _):
                result.append(words[old])
            case let .changed(oldRange, newRange):
                guard !newRange.isEmpty else { continue }
                let replaced = Array(words[oldRange])
                guard let first = replaced.first, let last = replaced.last else {
                    let at = result.last?.end ?? 0
                    result.append(contentsOf: newRange.map { WordTiming(word: new[$0], start: at, end: at, confidence: 0) })
                    continue
                }
                let step = (last.end - first.start) / Double(newRange.count)
                let confidence = replaced.map(\.confidence).min() ?? first.confidence
                for (offset, index) in newRange.enumerated() {
                    result.append(WordTiming(
                        word: new[index], start: first.start + step * Double(offset),
                        end: first.start + step * Double(offset + 1), confidence: confidence
                    ))
                }
            }
        }
        return result
    }
}
