import Testing
@testable import MouthtypeCore

@Suite struct TextMetricsTests {
    @Test func identicalTextHasZeroWER() {
        #expect(TextMetrics.wer(reference: "the quick brown fox", hypothesis: "the quick brown fox") == 0)
    }

    @Test func allWrongHasWERofOne() {
        #expect(TextMetrics.wer(reference: "one two three", hypothesis: "four five six") == 1)
    }

    @Test func substitution() {
        #expect(TextMetrics.wer(reference: "the cat sat", hypothesis: "the dog sat") == 1.0 / 3.0)
    }

    @Test func deletion() {
        #expect(TextMetrics.wer(reference: "the cat sat down", hypothesis: "the cat sat") == 0.25)
    }

    @Test func insertion() {
        #expect(TextMetrics.wer(reference: "the cat sat", hypothesis: "the big cat sat") == 1.0 / 3.0)
    }

    @Test func mixedEdits() {
        // substitute b->x, delete c, insert e: 3 edits over 4 reference words
        #expect(TextMetrics.wer(reference: "a b c d", hypothesis: "a x d e") == 0.75)
    }

    @Test func werCanExceedOne() {
        #expect(TextMetrics.wer(reference: "hi", hypothesis: "hi there my friend") == 3)
    }

    @Test func emptyReference() {
        #expect(TextMetrics.wer(reference: "", hypothesis: "") == 0)
        #expect(TextMetrics.wer(reference: "", hypothesis: "something") == 1)
        #expect(TextMetrics.wer(reference: "   ", hypothesis: "") == 0)
    }

    @Test func emptyHypothesisDeletesEverything() {
        #expect(TextMetrics.wer(reference: "one two", hypothesis: "") == 1)
    }

    @Test func caseAndPunctuationAreNormalized() {
        #expect(TextMetrics.wer(reference: "Hello, World! It's fine.", hypothesis: "hello world it's FINE") == 0)
    }

    @Test func curlyApostropheMatchesStraight() {
        #expect(TextMetrics.wer(reference: "don\u{2019}t stop", hypothesis: "don't stop") == 0)
    }

    @Test func apostrophesStayInsideWordsOnly() {
        #expect(TextMetrics.normalizedWords("'quoted' don't 'tis") == ["quoted", "don't", "tis"])
    }

    @Test func whitespaceIsCollapsed() {
        #expect(TextMetrics.normalizedWords("  a \n\t b   c ") == ["a", "b", "c"])
    }

    @Test func hyphenSplitsWordsOnBothSides() {
        #expect(TextMetrics.wer(reference: "well-known fact", hypothesis: "well known fact") == 0)
    }

    @Test func errorCountsExposeRawTotals() {
        let counts = TextMetrics.errorCounts(reference: "a b c d", hypothesis: "a x c")
        #expect(counts.edits == 2)
        #expect(counts.referenceWords == 4)
    }

    @Test func wordCount() {
        #expect(TextMetrics.wordCount("one two  three\nfour") == 4)
        #expect(TextMetrics.wordCount("") == 0)
        #expect(TextMetrics.wordCount("   ") == 0)
    }

    @Test func wordsPerMinute() {
        #expect(TextMetrics.wordsPerMinute(wordCount: 150, durationSeconds: 60) == 150)
        #expect(TextMetrics.wordsPerMinute(wordCount: 30, durationSeconds: 12) == 150)
        #expect(TextMetrics.wordsPerMinute(text: "one two three four", durationSeconds: 30) == 8)
    }

    @Test func wordsPerMinuteWithZeroOrNegativeDuration() {
        #expect(TextMetrics.wordsPerMinute(wordCount: 10, durationSeconds: 0) == 0)
        #expect(TextMetrics.wordsPerMinute(wordCount: 10, durationSeconds: -1) == 0)
    }
}
