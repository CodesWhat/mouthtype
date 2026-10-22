import Testing
@testable import MouthtypeCore

/// The shared all-hits matcher must give exactly what one PhraseMatcher per protected phrase gave.
@Suite struct ProfanitySharedMatcherTests {
    private struct SeededRandom: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            var x = state
            x ^= x >> 33
            x = x &* 0xff51afd7ed558ccd
            x ^= x >> 33
            return x
        }
    }

    private static let vocabulary = [
        "fuck", "fucking", "shit", "damn", "damn it", "dammit", "goddamn", "hell", "the", "what", "oh", "my", "project",
        "great", "car", "it", "you", "off", "a", "an", "asshole", "idiot", "good", "is", "this", "I", "forgot", "Oh",
        "bullshit", "crap", "holy", "cow", "the fuck", "so",
    ]
    private static let punctuation = ["", "", "", ",", ".", "!", "?", "...", ";"]
    private static let phrasePool = [
        "oh my", "my damn project", "damn project", "oh my damn", "the hell", "a a", "a a a", "fuck it", "Oh My",
        "OH MY", "my damn", "holy cow", "what the", "it   is", "project great", "shit", "damn", "x", "",
    ]

    private func randomText(_ rng: inout SeededRandom) -> String {
        var out = ""
        for _ in 0..<Int.random(in: 1...24, using: &rng) {
            out += Self.vocabulary.randomElement(using: &rng)!
            out += Self.punctuation.randomElement(using: &rng)!
            out += [" ", " ", " ", "  ", "\n"].randomElement(using: &rng)!
        }
        return out
    }

    @Test func matchesPerPhraseReferenceOnRandomInputs() {
        var rng = SeededRandom(state: 0x5eed)
        for round in 0..<600 {
            let phrases = (0..<Int.random(in: 0...6, using: &rng)).map { _ in Self.phrasePool.randomElement(using: &rng)! }
            let words = Set((0..<Int.random(in: 0...2, using: &rng)).map { _ in Self.vocabulary.randomElement(using: &rng)! })
            let text = randomText(&rng)
            let new = ProfanityRemover(protectedWords: words, protectedPhrases: phrases).apply(text)
            let old = ReferenceProfanityRemover(protectedWords: words, protectedPhrases: phrases).apply(text)
            #expect(new.text == old.text, "round \(round) text \(text.debugDescription) phrases \(phrases) words \(words)")
            #expect(new.edits.map(\.position) == old.edits.map(\.position), "round \(round)")
            #expect(new.edits.map(\.fromText) == old.edits.map(\.fromText), "round \(round)")
            #expect(new.edits.map(\.toText) == old.edits.map(\.toText), "round \(round)")
        }
    }

    @Test func overlappingPhrasesKeepCover() {
        let remover = ProfanityRemover(protectedPhrases: ["oh my", "my damn project"])
        #expect(remover.apply("Oh my damn project is great.").text == "Oh my damn project is great.")
    }

    @Test func edits_are_logged_as_profanity() {
        let out = ProfanityRemover().apply("Fuck, I forgot.")
        #expect(!out.edits.isEmpty)
        #expect(out.edits.allSatisfy { $0.stage == "profanity" })
    }
}
