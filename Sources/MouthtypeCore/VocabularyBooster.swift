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
        let outcome = await Self.withTimeout(timeout) { await session.rescore(text: text, tokenTimings: tokenTimings, samples: samples) }
        guard let outcome else {
            Self.log.warning("vocabulary rescoring passed \(self.timeout.description, privacy: .public); using the plain transcript")
            return nil
        }
        guard let rescore = outcome, rescore.wasModified else { return nil }
        let boosted = rescore.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !boosted.isEmpty, boosted != text else { return nil }
        return BoostedText(text: boosted, appliedTerms: rescore.appliedTerms)
    }

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
    /// Re-times `words` to `text` after a replacement. Words that survive keep their own times. A changed run
    /// takes the span of the words it replaced, shared evenly among its new words, with the lowest confidence
    /// of the originals. A run that replaces nothing (pure insertion) is placed zero-width after the word before it.
    static func realign(_ words: [WordTiming], to text: String) -> [WordTiming] {
        let new = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, !new.isEmpty else { return [] }
        let rows = words.count, cols = new.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: cols + 1), count: rows + 1)
        for r in stride(from: rows - 1, through: 0, by: -1) {
            for c in stride(from: cols - 1, through: 0, by: -1) {
                table[r][c] = words[r].word == new[c] ? table[r + 1][c + 1] + 1 : max(table[r + 1][c], table[r][c + 1])
            }
        }
        var result: [WordTiming] = []
        var r = 0, c = 0
        while r < rows || c < cols {
            if r < rows, c < cols, words[r].word == new[c] {
                result.append(words[r])
                r += 1
                c += 1
                continue
            }
            // A changed run: advance both sides to the next shared word (or the end).
            var oldRun: [WordTiming] = []
            var newRun: [String] = []
            while r < rows || c < cols {
                if r < rows, c < cols, words[r].word == new[c] { break }
                let takeOld = c >= cols || (r < rows && table[r + 1][c] >= table[r][c + 1])
                if takeOld {
                    oldRun.append(words[r])
                    r += 1
                } else {
                    newRun.append(new[c])
                    c += 1
                }
            }
            guard !newRun.isEmpty else { continue }
            if let first = oldRun.first, let last = oldRun.last {
                let step = (last.end - first.start) / Double(newRun.count)
                let confidence = oldRun.map(\.confidence).min() ?? first.confidence
                for (offset, word) in newRun.enumerated() {
                    result.append(WordTiming(
                        word: word, start: first.start + step * Double(offset),
                        end: first.start + step * Double(offset + 1), confidence: confidence
                    ))
                }
            } else {
                let at = result.last?.end ?? 0
                result.append(contentsOf: newRun.map { WordTiming(word: $0, start: at, end: at, confidence: 0) })
            }
        }
        return result
    }
}
