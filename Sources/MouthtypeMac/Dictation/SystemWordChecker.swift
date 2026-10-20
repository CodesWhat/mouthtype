import AppKit

/// "Is this an ordinary English word" backed by the system spell checker, for the suggester's known-word guard.
/// NSSpellChecker is main-thread territory and the suggester runs detached, so each new word hops to the main queue
/// once and the answer is cached. The caller must not be the main thread blocked on the suggester.
final class SystemWordChecker: @unchecked Sendable {
    static let shared = SystemWordChecker()

    private let lock = NSLock()
    private var cache: [String: Bool] = [:]

    func isKnown(_ word: String) -> Bool {
        lock.lock()
        if let hit = cache[word] { lock.unlock(); return hit }
        lock.unlock()
        let known: Bool = Thread.isMainThread ? Self.check(word) : DispatchQueue.main.sync { Self.check(word) }
        lock.lock()
        cache[word] = known
        lock.unlock()
        return known
    }

    private static func check(_ word: String) -> Bool {
        let checker = NSSpellChecker.shared
        let range = checker.checkSpelling(of: word, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        // Words the user taught macOS (Learn Spelling) pass the spell check but are names to us, not ordinary English.
        return range.location == NSNotFound && !checker.hasLearnedWord(word)
    }
}
