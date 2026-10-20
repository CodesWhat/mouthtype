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
    /// One replacement the rescorer made: the words it heard and the saved spelling it put in their place.
    struct Replacement: Sendable, Equatable {
        var heard: String
        var term: String
    }

    var text: String
    var wasModified: Bool
    var appliedTerms: [String]
    var replacements: [Replacement]

    init(text: String, wasModified: Bool, appliedTerms: [String], replacements: [Replacement] = []) {
        self.text = text
        self.wasModified = wasModified
        self.appliedTerms = appliedTerms
        self.replacements = replacements
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
        DependencyLogging.keepTermsOutOfLogs()
    }

    /// Sets the vocabulary. An unchanged one keeps the cached session; a changed one rebuilds it in the background;
    /// nil or empty releases everything. Never waits for a download, so a take is not held up by one.
    /// With `settleWithin`, a changed vocabulary also waits that long for its session, so a take whose terms differ
    /// from the last one's (editor hints) is still boosted. A slow build is left running and the take goes unboosted.
    func setBias(_ new: VocabularyBias?, settleWithin: Duration? = nil) async {
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
        if let settleWithin, let building {
            _ = await Self.withTimeout(settleWithin) { await building.value }
        }
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
        let known = Self.knownTerms(bias: bias, replacements: rescore.replacements)
        let boosted = Self.restoringPunctuation(original: text, boosted: rebuilt, known: known)
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

    /// A saved spelling and the spoken forms it replaces, as normalized word lists.
    struct KnownTerm: Equatable {
        var words: [String]
        var spoken: [[String]]
    }

    /// Lowercased letters and digits only, so "Guard)," and "guard" compare equal.
    static func normalizedWord(_ word: String) -> String {
        String(word.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    static func normalizedWords(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map { normalizedWord(String($0)) }.filter { !$0.isEmpty }
    }

    /// The vocabulary's spellings with their saved heard forms, plus what the rescorer actually replaced this take.
    static func knownTerms(bias: VocabularyBias?, replacements: [VocabularyRescore.Replacement]) -> [KnownTerm] {
        var order: [[String]] = []
        var spoken: [[String]: [[String]]] = [:]
        func add(_ term: String, heard: [String]) {
            let words = normalizedWords(term)
            guard !words.isEmpty else { return }
            if spoken[words] == nil { order.append(words) }
            for form in heard {
                let formWords = normalizedWords(form)
                if !formWords.isEmpty, !(spoken[words] ?? []).contains(formWords) { spoken[words, default: []].append(formWords) }
            }
            if spoken[words] == nil { spoken[words] = [] }
        }
        for entry in bias?.entries ?? [] { add(entry.text, heard: entry.aliases) }
        for replacement in replacements { add(replacement.term, heard: [replacement.heard]) }
        return order.map { KnownTerm(words: $0, spoken: spoken[$0] ?? []) }
    }

    private static func isWordChar(_ character: Character?) -> Bool {
        character.map { $0.isLetter || $0.isNumber } ?? false
    }

    /// One piece of a changed span of rescored words: a saved term of one or more words, or a single other word.
    private struct Segment {
        var range: Range<Int>
        var term: KnownTerm?
    }

    /// Cuts the rescored words of a changed span into saved terms (longest first) and single leftover words.
    /// A term never spans a word that has punctuation after it, so a comma cannot end up inside a name.
    private static func segment(_ words: [String], range: Range<Int>, known: [KnownTerm]) -> [Segment] {
        let byLength = known.sorted { $0.words.count > $1.words.count }
        var segments: [Segment] = []
        var at = range.lowerBound
        while at < range.upperBound {
            let match = byLength.first { term in
                let end = at + term.words.count
                guard end <= range.upperBound else { return false }
                return (0..<term.words.count).allSatisfy { k in
                    normalizedWord(words[at + k]) == term.words[k]
                        && (k == term.words.count - 1 || isWordChar(words[at + k].last))
                }
            }
            let length = match?.words.count ?? 1
            segments.append(Segment(range: at..<(at + length), term: match))
            at += length
        }
        return segments
    }

    /// How many original words each segment replaced, or nil when that can't be settled. Terms are matched to the
    /// original words through their spoken forms; with no spoken form to go on, a span that is one segment, or has
    /// one original word per segment, is still unambiguous.
    private static func partition(_ segments: [Segment], over old: [String]) -> [Int]? {
        // Spans this large are never real speech; keep the original words rather than risk a slow search.
        guard segments.count <= 64, old.count <= 64 else { return nil }
        let total = old.count
        func lengths(_ index: Int, _ position: Int) -> [Int] {
            guard let term = segments[index].term else { return position + 1 <= total ? [1] : [] }
            return Set(term.spoken.map(\.count)).sorted().filter { length in
                position + length <= total
                    && term.spoken.contains { $0.count == length && Array(old[position..<(position + length)]) == $0 }
            }
        }
        // ways[i][p]: how many ways segments i... cover old[p...] exactly, saturating at 2 (none, one, many).
        var ways = [[Int]](repeating: [Int](repeating: 0, count: total + 1), count: segments.count + 1)
        ways[segments.count][total] = 1
        for index in stride(from: segments.count - 1, through: 0, by: -1) {
            for position in 0...total {
                var count = 0
                for length in lengths(index, position) { count = min(2, count + ways[index + 1][position + length]) }
                ways[index][position] = count
            }
        }
        var found: [[Int]] = []
        if ways[0][0] == 1 {
            var current: [Int] = []
            var position = 0
            for index in 0..<segments.count {
                guard let length = lengths(index, position).first(where: { ways[index + 1][position + $0] > 0 }) else { break }
                current.append(length)
                position += length
            }
            found = [current]
        } else if ways[0][0] > 1 {
            found = [[], []]
        }
        if found.count == 1 { return found[0] }
        if !found.isEmpty { return nil }
        if segments.count == 1 { return [old.count] }
        if segments.count == old.count { return [Int](repeating: 1, count: segments.count) }
        return nil
    }

    /// The rescorer rebuilds its text from word timings and can drop the punctuation attached to a word it replaced
    /// ("next to fluid audio." came back as "FluidAudio"). Each changed span is cut into saved terms and the original
    /// words are matched to them; a term takes the opening punctuation of its first original word and the closing
    /// punctuation of its last, and punctuation on words inside it is dropped. A span that can't be matched
    /// unambiguously keeps its original words, so punctuation never lands inside a name.
    static func restoringPunctuation(original: String, boosted: String, known: [KnownTerm] = []) -> String {
        let old = original.split(whereSeparator: \.isWhitespace).map(String.init)
        let new = boosted.split(whereSeparator: \.isWhitespace).map(String.init)
        let oldNormalized = old.map(normalizedWord)
        var result: [String] = []
        for run in align(old, new) {
            switch run {
            case let .same(_, n):
                result.append(new[n])
            case let .changed(oldRange, newRange):
                guard !oldRange.isEmpty, !newRange.isEmpty else {
                    result.append(contentsOf: newRange.map { new[$0] })
                    continue
                }
                let segments = segment(new, range: newRange, known: known)
                guard let counts = partition(segments, over: Array(oldNormalized[oldRange])) else {
                    result.append(contentsOf: oldRange.map { old[$0] })
                    continue
                }
                var position = oldRange.lowerBound
                for (piece, count) in zip(segments, counts) {
                    var words = piece.range.map { new[$0] }
                    let first = old[position], last = old[position + count - 1]
                    position += count
                    let head = first.prefix { !$0.isLetter && !$0.isNumber }
                    if !head.isEmpty, isWordChar(words[0].first) {
                        words[0] = String(head) + words[0]
                    }
                    let tail = last.reversed().prefix { !$0.isLetter && !$0.isNumber }
                    if !tail.isEmpty, isWordChar(words[words.count - 1].last) {
                        words[words.count - 1] += String(tail.reversed())
                    }
                    result.append(contentsOf: words)
                }
            }
        }
        return result.joined(separator: " ")
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

/// FluidAudio's boosting code logs terms and replacements below warning level (and its "no CTC tokens" warning names
/// the term), and its logger defaults to debug with console mirroring. Editor code names must not reach any log, so
/// the library's logger keeps errors and faults only.
enum DependencyLogging {
    static let minimumLevel = AppLogger.Level.error

    static func keepTermsOutOfLogs() {
        if AppLogger.minimumLevel < minimumLevel { AppLogger.minimumLevel = minimumLevel }
    }
}
