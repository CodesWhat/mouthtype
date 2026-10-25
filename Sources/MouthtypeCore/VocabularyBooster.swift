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
    typealias Prepare =
        @Sendable (VocabularyBias, @escaping @Sendable (VocabularyBoostStatus) -> Void) async throws
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
            // Already building (started early, e.g. at key-down): the budget still applies, but only to what is left of the build.
            if new != nil, let settleWithin, let building {
                _ = await Self.withTimeout(settleWithin) { await building.value }
                return
            }
            guard new != nil, session == nil, building == nil, let failedAt,
                ContinuousClock.now - failedAt >= retryAfter
            else { return }
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
    /// The common prefix is matched directly. When no word repeats across the rest, the common suffix is matched too
    /// and the middle goes through a Myers diff, which is near linear when the rescorer changed a few words. Repeated
    /// shared words make the tie-break between equal-length alignments matter, so those go through the full table
    /// with its original forward traversal. A middle with too many edits also falls back to the full table.
    static func align(_ old: [String], _ new: [String]) -> [Run] {
        var head = 0
        while head < old.count, head < new.count, old[head] == new[head] { head += 1 }
        if hasRepeatedSharedWord(old[head...], new[head...]) {
            return (0..<head).map { .same(old: $0, new: $0) } + alignTable(old, head..<old.count, new, head..<new.count)
        }
        var tail = 0
        while tail < old.count - head, tail < new.count - head,
            old[old.count - 1 - tail] == new[new.count - 1 - tail]
        { tail += 1 }
        let oldEnd = old.count - tail, newEnd = new.count - tail
        var runs: [Run] = (0..<head).map { .same(old: $0, new: $0) }
        runs += alignMiddle(old, head..<oldEnd, new, head..<newEnd)
        runs += (0..<tail).map { .same(old: oldEnd + $0, new: newEnd + $0) }
        return runs
    }

    private static func hasRepeatedSharedWord(_ old: ArraySlice<String>, _ new: ArraySlice<String>) -> Bool {
        var oldCounts: [String: Int] = [:]
        for word in old { oldCounts[word, default: 0] += 1 }
        var newCounts: [String: Int] = [:]
        for word in new { newCounts[word, default: 0] += 1 }
        return oldCounts.contains { word, count in
            guard let other = newCounts[word] else { return false }
            return count > 1 || other > 1
        }
    }

    /// Edit-distance cap for the Myers pass. Past it the trace storage grows quadratically, so the table takes over.
    private static let myersEditCap = 512

    /// Matched (old, new) index pairs of a minimal alignment, or nil when it needs more than `myersEditCap` edits.
    private static func myersMatches(_ old: [String], _ oldRange: Range<Int>, _ new: [String], _ newRange: Range<Int>) -> [(Int, Int)]? {
        let (o, n) = (oldRange.lowerBound, newRange.lowerBound)
        let rows = oldRange.count, cols = newRange.count
        let cap = min(myersEditCap, rows + cols)
        let offset = cap + 1
        var v = [Int](repeating: 0, count: 2 * cap + 3)
        var trace: [[Int]] = []
        var found = -1
        search: for d in 0...cap {
            trace.append(v)
            for k in stride(from: -d, through: d, by: 2) {
                var x = (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) ? v[offset + k + 1] : v[offset + k - 1] + 1
                var y = x - k
                while x < rows, y < cols, old[o + x] == new[n + y] { x += 1; y += 1 }
                v[offset + k] = x
                if x >= rows, y >= cols { found = d; break search }
            }
        }
        guard found >= 0 else { return nil }
        var matches: [(Int, Int)] = []
        var x = rows, y = cols
        for d in stride(from: found, through: 1, by: -1) {
            let vd = trace[d]
            let k = x - y
            let prevK = (k == -d || (k != d && vd[offset + k - 1] < vd[offset + k + 1])) ? k + 1 : k - 1
            let prevX = vd[offset + prevK], prevY = prevX - prevK
            while x > prevX, y > prevY { matches.append((o + x - 1, n + y - 1)); x -= 1; y -= 1 }
            x = prevX
            y = prevY
        }
        while x > 0, y > 0 { matches.append((o + x - 1, n + y - 1)); x -= 1; y -= 1 }
        matches.reverse()
        return matches
    }

    private static func alignMiddle(_ old: [String], _ oldRange: Range<Int>, _ new: [String], _ newRange: Range<Int>) -> [Run] {
        let rows = oldRange.count, cols = newRange.count
        guard rows > 0 || cols > 0 else { return [] }
        if let matches = myersMatches(old, oldRange, new, newRange) {
            var runs: [Run] = []
            var r = oldRange.lowerBound, c = newRange.lowerBound
            for (mo, mn) in matches {
                if mo > r || mn > c { runs.append(.changed(old: r..<mo, new: c..<mn)) }
                runs.append(.same(old: mo, new: mn))
                (r, c) = (mo + 1, mn + 1)
            }
            if r < oldRange.upperBound || c < newRange.upperBound {
                runs.append(.changed(old: r..<oldRange.upperBound, new: c..<newRange.upperBound))
            }
            return runs
        }
        return alignTable(old, oldRange, new, newRange)
    }

    private static func alignTable(_ old: [String], _ oldRange: Range<Int>, _ new: [String], _ newRange: Range<Int>) -> [Run] {
        let rows = oldRange.count, cols = newRange.count
        guard rows > 0 || cols > 0 else { return [] }
        let (o, n) = (oldRange.lowerBound, newRange.lowerBound)
        var table = [[Int]](repeating: [Int](repeating: 0, count: cols + 1), count: rows + 1)
        for r in stride(from: rows - 1, through: 0, by: -1) {
            for c in stride(from: cols - 1, through: 0, by: -1) {
                table[r][c] = old[o + r] == new[n + c] ? table[r + 1][c + 1] + 1 : max(table[r + 1][c], table[r][c + 1])
            }
        }
        var runs: [Run] = []
        var r = 0, c = 0
        while r < rows || c < cols {
            if r < rows, c < cols, old[o + r] == new[n + c] {
                runs.append(.same(old: o + r, new: n + c))
                r += 1
                c += 1
                continue
            }
            let (startOld, startNew) = (r, c)
            while r < rows || c < cols {
                if r < rows, c < cols, old[o + r] == new[n + c] { break }
                if c >= cols || (r < rows && table[r + 1][c] >= table[r][c + 1]) { r += 1 } else { c += 1 }
            }
            runs.append(.changed(old: (o + startOld)..<(o + r), new: (n + startNew)..<(n + c)))
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

    private static func coveringKnownTerms(_ runs: [Run], words: [String], known: [KnownTerm]) -> [Run] {
        guard !known.isEmpty else { return runs }
        let terms = segment(words, range: words.indices, known: known).filter { $0.term != nil && $0.range.count > 1 }
        guard !terms.isEmpty else { return runs }
        func ranges(_ run: Run) -> (old: Range<Int>, new: Range<Int>) {
            switch run {
            case let .same(old, new): return (old..<(old + 1), new..<(new + 1))
            case let .changed(old, new): return (old, new)
            }
        }
        var combined: [Run] = []
        var term = 0
        for run in runs {
            let current = ranges(run)
            let boundary = current.new.lowerBound
            while term < terms.count, terms[term].range.upperBound <= boundary { term += 1 }
            if term < terms.count, terms[term].range.lowerBound < boundary,
                boundary < terms[term].range.upperBound, let previous = combined.last
            {
                let start = ranges(previous)
                combined[combined.count - 1] = .changed(
                    old: start.old.lowerBound..<current.old.upperBound, new: start.new.lowerBound..<current.new.upperBound)
            } else {
                combined.append(run)
            }
        }
        return combined
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
        for run in coveringKnownTerms(align(old, new), words: new, known: known) {
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
                    result.append(
                        WordTiming(
                            word: new[index], start: first.start + step * Double(offset),
                            end: first.start + step * Double(offset + 1), confidence: confidence
                        ))
                }
            }
        }
        return result
    }
}

/// FluidAudio's boosting code logs terms and replacements below warning level, and its logger defaults to debug with
/// console mirroring. Editor code names must not reach any log, so the library's logger keeps warnings and up. The
/// warnings that do name a term are all raised while a session is built (a term that "produced no CTC tokens", a
/// term dropped by sanitizing), so `quietingWarnings` lifts the floor to errors just for that build. That leaves
/// "Vocabulary rescoring failed", which names no term, visible at take time.
enum DependencyLogging {
    static let minimumLevel = AppLogger.Level.warning
    static let buildLevel = AppLogger.Level.error

    private struct Quiet {
        var depth = 0
        var saved = AppLogger.Level.debug
    }
    private static let quiet = Mutex(Quiet())

    static func keepTermsOutOfLogs() {
        if AppLogger.minimumLevel < minimumLevel { AppLogger.minimumLevel = minimumLevel }
    }

    /// Runs `body` with FluidAudio's logger at errors only, then puts the level back. Overlapping calls share one
    /// saved level, restored when the last one finishes.
    static func quietingWarnings<T>(_ body: () async throws -> T) async rethrows -> T {
        quiet.withLock { state in
            if state.depth == 0 { state.saved = AppLogger.minimumLevel }
            state.depth += 1
            if AppLogger.minimumLevel < buildLevel { AppLogger.minimumLevel = buildLevel }
        }
        defer {
            quiet.withLock { state in
                state.depth -= 1
                if state.depth == 0 { AppLogger.minimumLevel = state.saved }
            }
        }
        return try await body()
    }
}
