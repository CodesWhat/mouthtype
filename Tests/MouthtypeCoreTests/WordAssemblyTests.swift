import Foundation
import Testing
@testable import MouthtypeCore

@Suite struct WordAssemblyTests {
    private func unit(_ text: String, _ start: Double, _ end: Double, _ confidence: Float = 0.9) -> SubwordUnit {
        SubwordUnit(text: text, start: start, end: end, confidence: confidence)
    }

    @Test func emptyInputGivesNoWords() {
        #expect(WordAssembly.assemble([]).isEmpty)
    }

    @Test func singleUnit() {
        let words = WordAssembly.assemble([unit("\u{2581}hello", 0.1, 0.4, 0.8)])
        #expect(words == [WordTiming(word: "hello", start: 0.1, end: 0.4, confidence: 0.8)])
    }

    @Test func subwordUnitsMergeIntoOneWord() {
        let words = WordAssembly.assemble([
            unit("\u{2581}dict", 0.0, 0.2), unit("ation", 0.2, 0.5), unit("\u{2581}works", 0.6, 0.9),
        ])
        #expect(words.map(\.word) == ["dictation", "works"])
        #expect(words[0].start == 0.0)
        #expect(words[0].end == 0.5)
        #expect(words[1].start == 0.6)
    }

    @Test func leadingSpaceMarksBoundary() {
        let words = WordAssembly.assemble([unit(" good", 0, 0.2), unit("ness", 0.2, 0.4), unit(" me", 0.5, 0.6)])
        #expect(words.map(\.word) == ["goodness", "me"])
    }

    @Test func unmarkedFirstUnitStartsAWord() {
        let words = WordAssembly.assemble([unit("hi", 0, 0.1), unit("\u{2581}there", 0.2, 0.4)])
        #expect(words.map(\.word) == ["hi", "there"])
    }

    @Test func punctuationAttachesToPrecedingWord() {
        let words = WordAssembly.assemble([
            unit("\u{2581}Hello", 0, 0.3), unit(",", 0.3, 0.35), unit("\u{2581}world", 0.5, 0.8),
            unit("\u{2581}.", 0.8, 0.85), unit("?!", 0.85, 0.9),
        ])
        #expect(words.map(\.word) == ["Hello,", "world.?!"])
        #expect(words[0].end == 0.35)
    }

    @Test func openingPunctuationDoesNotAttachBackward() {
        let words = WordAssembly.assemble([unit("\u{2581}say", 0, 0.2), unit("\u{2581}(", 0.3, 0.35), unit("hi", 0.35, 0.5)])
        #expect(words.map(\.word) == ["say", "(hi"])
    }

    @Test func confidenceIsMinimumOfUnits() {
        let words = WordAssembly.assemble([
            unit("\u{2581}ab", 0, 0.1, 0.9), unit("cd", 0.1, 0.2, 0.4), unit("ef", 0.2, 0.3, 0.7),
        ])
        #expect(words.count == 1)
        #expect(words[0].confidence == 0.4)
    }

    @Test func specialUnitsAreSkipped() {
        let words = WordAssembly.assemble([
            unit("<blank>", 0, 0.1), unit("\u{2581}ok", 0.1, 0.2), unit("", 0.2, 0.3), unit("<pad>", 0.3, 0.4),
        ])
        #expect(words.map(\.word) == ["ok"])
    }

    @Test func joinedWordsReproduceTextModuloWhitespace() {
        let text = "Hello, world. It's a test of dictation!"
        let units = [
            unit("\u{2581}Hello", 0, 0.3), unit(",", 0.3, 0.35), unit("\u{2581}world", 0.4, 0.7), unit(".", 0.7, 0.75),
            unit("\u{2581}It", 0.8, 0.9), unit("'", 0.9, 0.92), unit("s", 0.92, 0.95), unit("\u{2581}a", 1.0, 1.05),
            unit("\u{2581}test", 1.1, 1.3), unit("\u{2581}of", 1.4, 1.5), unit("\u{2581}dict", 1.6, 1.8),
            unit("ation", 1.8, 2.0), unit("!", 2.0, 2.05),
        ]
        let joined = WordAssembly.assemble(units).map(\.word).joined()
        #expect(joined == text.filter { !$0.isWhitespace })
    }
}
