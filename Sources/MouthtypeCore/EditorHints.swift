import Foundation

/// Code names (file, folder and identifier spellings) to bias recognition toward while dictating in an editor or
/// terminal. Everything here is pure and in memory: nothing is stored or logged, and the terms live for one dictation.
public enum EditorHints {
    /// Most terms one dictation adds.
    public static let maxTerms = 40
    /// Most of those that may come from the cursor window, so the title and files always have room.
    public static let maxCursorTerms = 20
    /// Shorter names are dropped: they sit too close to ordinary words for the boost to be safe.
    public static let minLength = 4
    public static let maxLength = 64
    /// How long the whole gather may take before it settles for what is ready.
    public static let defaultDeadline: Duration = .milliseconds(150)

    // MARK: Window titles

    public enum TitleStyle: Sendable { case vscode, xcode }

    public struct ParsedTitle: Equatable, Sendable {
        public var file: String?
        public var project: String?
    }

    private static let separators = [" \u{2014} ", " \u{2013} ", " - "]
    private static let appNames: Set<String> = [
        "visual studio code", "cursor", "code", "insiders", "vscodium", "windsurf", "xcode",
    ]

    /// `file - folder - Visual Studio Code`, `file — folder — Cursor`, `Project — File.swift` and their variants.
    /// Unknown shapes give nothing rather than a guess.
    public static func parseTitle(_ title: String, style: TitleStyle) -> ParsedTitle {
        var marked = title
        for separator in separators { marked = marked.replacingOccurrences(of: separator, with: "\u{1F}") }
        var parts = marked.split(separator: "\u{1F}", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        while let last = parts.last, appNames.contains(last.lowercased()) { parts.removeLast() }
        if style == .xcode, parts.last?.lowercased() == "edited" { parts.removeLast() }
        parts = parts.map(cleanTitlePart).filter { !$0.isEmpty }
        guard let first = parts.first else { return ParsedTitle() }

        switch style {
        case .vscode:
            if parts.count == 1 { return looksLikeFile(first) ? ParsedTitle(file: first) : ParsedTitle(project: first) }
            return ParsedTitle(file: first, project: parts[1])
        case .xcode:
            if parts.count == 1 { return looksLikeFile(first) ? ParsedTitle(file: first) : ParsedTitle(project: first) }
            return ParsedTitle(file: looksLikeFile(parts[1]) ? parts[1] : nil, project: first)
        }
    }

    private static func cleanTitlePart(_ raw: String) -> String {
        var text = raw
        if let dot = text.first, "\u{25CF}\u{2022}*".contains(dot) { text.removeFirst() }
        for pattern in [#"^\[[^\]]*\]\s*"#, #"\s*\[[^\]]*\]$"#, #"\s*\((Workspace|Untitled)[^)]*\)$"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static func looksLikeFile(_ name: String) -> Bool {
        guard !name.contains(" "), let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...]
        return (1...10).contains(ext.count) && ext.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// Name pieces worth trying as terms from a file name or path: `AppDelegate.swift` gives `AppDelegate`,
    /// `user.service.spec.ts` gives `user`, `service`, `spec`.
    public static func candidates(fromFileName name: String) -> [String] {
        var base = name.split(separator: "/").last.map(String.init) ?? name
        if let dot = base.lastIndex(of: "."), dot != base.startIndex { base = String(base[..<dot]) }
        return base.split(separator: ".").map(String.init)
    }

    // MARK: Identifiers

    /// Compound identifiers (camelCase, PascalCase, snake_case, kebab-case) near the cursor, nearest first. Lowercase
    /// starts are included, unlike `CleanupPrompt.nearbySpellings`.
    public static func identifiers(before: String?, after: String?) -> [String] {
        var seen = Set<String>()
        var found: [String] = []
        func add(_ tokens: [String]) {
            for token in tokens where isCompound(token) && seen.insert(token.lowercased()).inserted { found.append(token) }
        }
        add(tokens(in: before ?? "").reversed())
        add(tokens(in: after ?? ""))
        return found
    }

    private static func tokens(in text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in text {
            if character.isLetter || character.isNumber || character == "_" || character == "-" {
                current.append(character)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "_-")) }.filter { !$0.isEmpty }
    }

    private static func isCompound(_ token: String) -> Bool {
        guard token.contains(where: \.isLetter) else { return false }
        let words = spokenWords(token)
        guard words.count >= 2 else { return false }
        // Hyphenated prose ("well-known") is not code. Kebab case counts only when some word isn't everyday.
        if token.contains("-"), !token.contains("_"), words.allSatisfy(isEveryday) { return false }
        return true
    }

    /// `viewDidLoad` gives `view did load`, `URLSession` gives `url session`, `max_retry-count` gives `max retry count`.
    public static func spokenWords(_ identifier: String) -> [String] {
        var words: [String] = []
        for chunk in identifier.split(whereSeparator: { $0 == "_" || $0 == "-" }) {
            let characters = Array(chunk)
            var current = ""
            for (index, character) in characters.enumerated() {
                if index > 0, character.isUppercase {
                    let previous = characters[index - 1]
                    let next = index + 1 < characters.count ? characters[index + 1] : nil
                    if previous.isLowercase || previous.isNumber || (previous.isUppercase && next?.isLowercase == true) {
                        words.append(current.lowercased())
                        current = ""
                    }
                }
                current.append(character)
            }
            if !current.isEmpty { words.append(current.lowercased()) }
        }
        return words.filter { !$0.isEmpty }
    }

    private static func isEveryday(_ word: String) -> Bool {
        CommonWords.set.contains(word) || OrdinaryWords.isOrdinary(word) || codeWords.contains(word)
    }

    /// Words every codebase uses. They are close to plain speech, so they never become terms or lone aliases.
    private static let codeWords: Set<String> = Set("""
        user users data value values item items name names type types list lists string strings number numbers index key
        keys node nodes text file files path paths size time date result results error errors count flag mode state
        config options option info input output default object objects array arrays model models view views action
        actions event events handler manager service controller request response message messages content body title
        label button page pages image images status code codes line lines table row rows column field fields entry
        entries buffer cache queue stack parent child children source target client server session context format parse
        parser build builder test tests make load save update delete create remove insert append return self this none
        null true false void init main run start stop open close read write send receive set get add copy move find
        search filter sort group merge split join reset clear check valid invalid enable disable enabled disabled
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    // MARK: Terms

    /// One candidate as a boost term, or nil when it is too short, too long, not name-shaped, an everyday word, or a
    /// compound made only of everyday words ("getUser", "itemList"). The rescorer joins adjacent spoken words, so even
    /// without an alias such a term would rewrite plain speech like "get user". A compound with any other word gets
    /// its spoken form as an alias.
    public static func term(_ raw: String) -> VocabularyBias.Term? {
        let text = raw.trimmingCharacters(in: CharacterSet(charactersIn: "_-."))
        guard text.count >= minLength, text.count <= maxLength,
              text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }),
              text.contains(where: \.isLetter) else { return nil }
        let words = spokenWords(text)
        guard !words.isEmpty else { return nil }
        if words.count == 1 {
            return isEveryday(text.lowercased()) ? nil : VocabularyBias.Term(text: text)
        }
        if words.allSatisfy(isEveryday) { return nil }
        return VocabularyBias.Term(text: text, aliases: [words.joined(separator: " ")])
    }

    /// At most `maxTerms`: cursor identifiers first (up to `maxCursorTerms`), then title names, then file names.
    /// Case-insensitive duplicates keep the earlier, higher-ranked one.
    public static func terms(cursor: [String], title: [String], files: [String]) -> [VocabularyBias.Term] {
        var seen = Set<String>()
        var result: [VocabularyBias.Term] = []
        func take(_ candidates: [String], limit: Int) {
            var taken = 0
            for candidate in candidates {
                guard result.count < maxTerms, taken < limit else { return }
                guard let term = term(candidate), seen.insert(term.text.lowercased()).inserted else { continue }
                result.append(term)
                taken += 1
            }
        }
        take(cursor, limit: maxCursorTerms)
        take(title, limit: maxTerms)
        take(files, limit: maxTerms)
        return result
    }

    /// File and folder names from project paths, shallow paths first so top-level names win the cap.
    public static func nameCandidates(fromPaths paths: [String]) -> [String] {
        let ranked = paths.enumerated().sorted {
            let (a, b) = (depth($0.element), depth($1.element))
            return a != b ? a < b : $0.offset < $1.offset
        }
        return ranked.filter { !($0.element.split(separator: "/").last?.hasPrefix(".") ?? true) }
            .flatMap { candidates(fromFileName: $0.element) }
    }

    private static func depth(_ path: String) -> Int { path.reduce(0) { $1 == "/" ? $0 + 1 : $0 } }

    // MARK: Gathering

    /// What one dictation can see. `files` is the slow source and runs under the deadline. `readCursor` reads the
    /// text around the cursor from the focused app. It blocks, so `gather` runs it off the caller's thread and under
    /// the same deadline, and hands it the instant it must be done by so each call it makes can use only what is left.
    public struct Input: Sendable {
        public var cursorBefore: String?
        public var cursorAfter: String?
        public var windowTitle: String?
        public var titleStyle: TitleStyle?
        public var readCursor: (@Sendable (_ until: ContinuousClock.Instant) -> InsertionContext?)?
        public var files: @Sendable () async -> [String]

        public init(
            cursorBefore: String? = nil, cursorAfter: String? = nil, windowTitle: String? = nil,
            titleStyle: TitleStyle? = nil,
            readCursor: (@Sendable (_ until: ContinuousClock.Instant) -> InsertionContext?)? = nil,
            files: @escaping @Sendable () async -> [String] = { [] }
        ) {
            self.cursorBefore = cursorBefore
            self.cursorAfter = cursorAfter
            self.windowTitle = windowTitle
            self.titleStyle = titleStyle
            self.readCursor = readCursor
            self.files = files
        }
    }

    /// The terms for one dictation. The cheap sources are always used; the cursor read and the file source are used
    /// only if they answer inside `deadline`, so a slow `git` or a stuck app costs its own source and nothing else.
    public static func gather(_ input: Input, deadline: Duration = defaultDeadline) async -> [VocabularyBias.Term] {
        let clock = ContinuousClock()
        let limit = clock.now + deadline
        async let read = runBlocking(until: limit) { input.readCursor?(limit) }
        var title: [String] = []
        if let text = input.windowTitle, let style = input.titleStyle {
            let parsed = parseTitle(text, style: style)
            title = (parsed.file.map(candidates(fromFileName:)) ?? []) + (parsed.project.map { [$0] } ?? [])
        }
        let paths = await VocabularyBooster.withTimeout(max(.zero, limit - clock.now)) { await input.files() } ?? []
        let context = await read
        let cursor = identifiers(before: context?.before ?? input.cursorBefore, after: context?.after ?? input.cursorAfter)
        return terms(cursor: cursor, title: title, files: nameCandidates(fromPaths: paths))
    }

    /// Runs blocking `work` on a background queue and returns its result, or nil if it hasn't finished by `limit`.
    /// The work isn't cancelled (a stuck Accessibility call can't be), but nothing waits for it past the limit.
    public static func runBlocking<T: Sendable>(until limit: ContinuousClock.Instant, _ work: @escaping @Sendable () -> T?) async -> T? {
        let remaining = limit - ContinuousClock.now
        guard remaining > .zero else { return nil }
        let once = OneShot<T>()
        return await withCheckedContinuation { continuation in
            once.install(continuation)
            DispatchQueue.global(qos: .userInitiated).async { once.finish(work()) }
            let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) { once.finish(nil) }
        }
    }

    /// Resumes its continuation once, with whichever of the work or the timer gets there first.
    private final class OneShot<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?
        func install(_ continuation: CheckedContinuation<T?, Never>) { lock.withLock { self.continuation = continuation } }
        func finish(_ value: T?) {
            let pending = lock.withLock { () -> CheckedContinuation<T?, Never>? in
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(returning: value)
        }
    }
}
