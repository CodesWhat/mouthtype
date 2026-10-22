import Testing
@testable import MouthtypeCore

@Suite struct ContextNamesTests {
    @Test func picksProperNounsNearestTheCursorFirst() {
        let names = ContextNames.candidates(
            before: "Maya Okonkwo said the deck for Zephyrine is late. Priya Raman agreed", after: " with Tobias.")
        #expect(names == ["Raman", "Priya", "Zephyrine", "Okonkwo", "Maya", "Tobias"])
    }

    @Test func dropsSentenceStartsEverydayWordsAcronymsAndShortNames() {
        let names = ContextNames.candidates(
            before: "Thanks for that. Monday works. NASA called. Bob and Quillan met. The Hendricks team", after: nil)
        #expect(names.contains("Hendricks"))
        #expect(names.contains("Quillan"))
        #expect(!names.contains("Thanks"))
        #expect(!names.contains("Monday"))
        #expect(!names.contains("NASA"))
        #expect(!names.contains("Bob"))
        #expect(!names.contains("The"))
    }

    @Test func readsTheWindowTitleAndSkipsTheAppName() {
        let terms = ContextNames.terms(before: nil, after: nil, windowTitle: "Slack | Saoirse Whitlock | Acme", excluding: ["Slack"])
        #expect(terms.map(\.text) == ["Saoirse", "Whitlock", "Acme"])
    }

    @Test func dedupesCaseInsensitivelyAndCapsTheCount() {
        #expect(ContextNames.candidates(before: "Quillan quillan Quillan", after: nil) == ["Quillan"])
        let many = (0..<80).map { "Namez\(String(UnicodeScalar(UInt8(97 + $0 % 26))))\(String(UnicodeScalar(UInt8(97 + $0 / 26))))" }
        let text = many.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " and ")
        #expect(ContextNames.terms(before: text, after: nil).count == ContextNames.maxTerms)
    }

    @Test func emptyTextGivesNothing() {
        #expect(ContextNames.terms(before: nil, after: nil).isEmpty)
        #expect(ContextNames.terms(before: "", after: "", windowTitle: "").isEmpty)
    }
}
