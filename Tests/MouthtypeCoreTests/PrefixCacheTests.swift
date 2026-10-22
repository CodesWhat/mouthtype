import MLXLMCommon
import Testing
@testable import MouthtypeCore

@Suite struct PrefixCacheTests {
    private func entry(_ tokens: [Int]) -> PrefixCaches.Entry { .init(tokens: tokens, cache: []) }

    @Test func commonPrefixStopsAtTheFirstDifference() {
        #expect(MLXCleaner.commonPrefixLength([1, 2, 3, 4], [1, 2, 9, 4]) == 2)
        #expect(MLXCleaner.commonPrefixLength([1, 2], [1, 2, 3]) == 2)
        #expect(MLXCleaner.commonPrefixLength([], [1]) == 0)
    }

    @Test func theLongestMatchingPrefixIsReused() {
        let caches = PrefixCaches()
        caches.insert(entry([1, 2]))
        caches.insert(entry([1, 2, 3, 4]))
        caches.insert(entry([7, 8, 9]))
        #expect(caches.longestPrefix(of: [1, 2, 3, 4, 5, 6], upTo: 5)?.tokens == [1, 2, 3, 4])
        #expect(caches.longestPrefix(of: [1, 2, 9, 9], upTo: 3)?.tokens == [1, 2])
        #expect(caches.longestPrefix(of: [5, 5, 5], upTo: 2) == nil)
    }

    @Test func aCacheThatWouldLeaveNothingToPrefillIsSkipped() {
        let caches = PrefixCaches()
        caches.insert(entry([1, 2, 3]))
        #expect(caches.longestPrefix(of: [1, 2, 3], upTo: 2) == nil)
    }

    @Test func theOldestEntryIsDroppedPastCapacity() {
        let caches = PrefixCaches()
        for i in 0...PrefixCaches.capacity { caches.insert(entry([i, 100])) }
        #expect(caches.longestPrefix(of: [0, 100, 1], upTo: 2) == nil)
        #expect(caches.longestPrefix(of: [PrefixCaches.capacity, 100, 1], upTo: 2) != nil)
    }

    @Test func clearingForgetsEverything() {
        let caches = PrefixCaches()
        caches.insert(entry([1, 2]))
        caches.clear()
        #expect(caches.longestPrefix(of: [1, 2, 3], upTo: 2) == nil)
    }

    @Test func theSystemPromptIsTheStablePrefixOfEveryTake() {
        let context = CleanupContext(vocabulary: ["Mouthtype"], appName: "Notes")
        let system = CleanupPrompt.system(for: context)
        var withReference = context
        withReference.before = "Talking to Priya about Quokka"
        // Nearby text only appends to the system prompt, so a cached start of the plain prompt still matches.
        #expect(CleanupPrompt.system(for: withReference).hasPrefix(system))
        #expect(CleanupPrompt.user("one", context: context).hasSuffix("<transcript>\none\n</transcript>"))
    }
}
