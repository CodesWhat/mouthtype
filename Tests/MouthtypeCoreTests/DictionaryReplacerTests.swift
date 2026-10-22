// Adapted from Parrot (https://github.com/humanitas-labs/parrot, 0eb4708), MIT License, Copyright (c) 2026 Humanitas Labs.

import Testing
@testable import MouthtypeCore

@Suite struct DictionaryReplacerTests {
    private func apply(_ text: String, _ rules: [(String, String)]) -> String {
        DictionaryReplacer(rules: rules.map { DictionaryRule(heard: $0.0, written: $0.1) }).apply(to: text)
    }

    private func terms(_ text: String, _ terms: [String]) -> String {
        DictionaryReplacer(rules: terms.map { DictionaryRule(heard: $0, written: $0) }).apply(to: text)
    }

    // MARK: Whole words

    @Test func matchesWholeWordsOnly() {
        let rules = [("api", "API")]
        #expect(apply("the api is rapid", rules) == "the API is rapid")
        #expect(apply("rapid apis capital", rules) == "rapid apis capital")
        #expect(apply("my_api api2 api", rules) == "my_api api2 API")
    }

    @Test func punctuationIsABoundary() {
        let rules = [("post hog", "PostHog")]
        #expect(
            apply("Open post hog. Then (post hog), \"post hog\"!", rules)
                == "Open PostHog. Then (PostHog), \"PostHog\"!"
        )
        #expect(apply("post-hog", rules) == "post-hog")
    }

    @Test func accentedLettersAreWordCharacters() {
        let rules = [("api", "API"), ("café", "Café Rouge")]
        #expect(apply("apié éapi api", rules) == "apié éapi API")
        #expect(apply("un café crème, cafés", rules) == "un Café Rouge crème, cafés")
        // Decomposed é: the combining mark belongs to the word.
        #expect(apply("cafe\u{301}", [("cafe", "X")]) == "cafe\u{301}")
    }

    @Test func nonLatinScripts() {
        #expect(terms("я работаю в яндекс, не в яндексе", ["Яндекс"]) == "я работаю в Яндекс, не в яндексе")
        #expect(terms("ΑΘΉΝΑ και αθήνα", ["Αθήνα"]) == "Αθήνα και Αθήνα")
        #expect(apply("東京 と 東京都", [("東京", "Tokyo")]) == "Tokyo と 東京都")
        #expect(apply("in api中 api", [("api", "API")]) == "in api中 API")
    }

    @Test func emojiAreBoundaries() {
        #expect(apply("🎉api🎉", [("api", "API")]) == "🎉API🎉")
    }

    // MARK: Precedence and passes

    @Test func longestMatchWins() {
        let rules = [("post", "POST"), ("post hog", "PostHog")]
        #expect(apply("post hog and post office", rules) == "PostHog and POST office")
        #expect(apply("post hog", rules.reversed()) == "PostHog")
    }

    @Test func longerRuleThatIsNotAWholeWordFallsBackToShorter() {
        #expect(apply("post hog", [("post", "POST"), ("post ho", "X")]) == "POST hog")
    }

    @Test func replacementsDoNotChain() {
        #expect(apply("alpha beta", [("alpha", "beta"), ("beta", "gamma")]) == "beta gamma")
        #expect(apply("js", [("js", "JavaScript"), ("javascript", "JS")]) == "JavaScript")
    }

    @Test func firstRuleWinsAmongDuplicates() {
        #expect(apply("posthog", [("posthog", "PostHog"), ("POSTHOG", "Other")]) == "PostHog")
    }

    @Test func replacementIsInsertedLiterally() {
        #expect(apply("home dir", [("home dir", "$HOME")]) == "$HOME")
        #expect(apply("group", [("group", "$0 \\1 $1 \\")]) == "$0 \\1 $1 \\")
    }

    @Test func sourceIsMatchedLiterally() {
        #expect(apply("c++ and cxx", [("c++", "C++")]) == "C++ and cxx")
        #expect(apply("a.b axb", [("a.b", "A.B")]) == "A.B axb")
    }

    @Test func writtenIsInsertedExactlyAsGiven() {
        #expect(apply("send it to Mouth Type", [("Mouth Type", "Mouthtype")]) == "send it to Mouthtype")
        #expect(apply("i phone", [("i phone", "iPhone")]) == "iPhone")
        #expect(apply("my email", [("my email", " a@b.c ")]) == " a@b.c ")
    }

    // MARK: Terms

    @Test func termsNormalizeCasing() {
        let t = ["PostHog", "WhisperKit"]
        #expect(terms("posthog, POSTHOG and Posthog", t) == "PostHog, PostHog and PostHog")
        #expect(terms("whisperkit is fast", t) == "WhisperKit is fast")
        #expect(terms("posthogs", t) == "posthogs")
    }

    // MARK: Input handling

    @Test func whitespaceInsideSourceMatchesAnyRun() {
        #expect(apply("post  hog", [("post hog", "PostHog")]) == "PostHog")
        #expect(apply("post\nhog", [("post hog", "PostHog")]) == "PostHog")
        #expect(apply("post hog", [("  post   hog ", "PostHog")]) == "PostHog")
    }

    @Test func emptyEntriesAreIgnored() {
        #expect(apply("a b", [("", "X"), ("a", ""), ("  ", "Y")]) == "a b")
        #expect(DictionaryReplacer(rules: []).apply(to: "unchanged") == "unchanged")
        #expect(terms("", ["X"]) == "")
    }

    // MARK: Edit log

    @Test func logsEachReplacement() {
        let out = DictionaryReplacer(rules: [DictionaryRule(heard: "Mouth Type", written: "Mouthtype")])
            .apply("send it to Mouth Type and mouth type again")
        #expect(out.text == "send it to Mouthtype and Mouthtype again")
        #expect(out.edits.count == 2)
        #expect(out.edits[0].stage == "dictionary")
        #expect(out.edits[0].kind == .replace)
        #expect(out.edits[0].fromText == "Mouth Type")
        #expect(out.edits[0].toText == "Mouthtype")
        #expect(out.edits[0].wordDelta == -1)
        #expect(out.edits[0].position == 11)
        #expect(out.edits[1].fromText == "mouth type")
        #expect(out.edits[1].position == 26)
    }

    @Test func aMatchThatChangesNothingIsNotLogged() {
        let out = DictionaryReplacer(rules: [DictionaryRule(heard: "PostHog", written: "PostHog")]).apply("open PostHog")
        #expect(out.text == "open PostHog")
        #expect(out.edits.isEmpty)
    }

    @Test func replayMatchesOutput() {
        let text = "the api and post hog, then api again"
        let rules = [DictionaryRule(heard: "api", written: "API"), DictionaryRule(heard: "post hog", written: "PostHog")]
        let out = DictionaryReplacer(rules: rules).apply(text)
        #expect(TextTestSupport.replay(out.edits, on: text) == TextTestSupport.stripWhitespace(out.text))
    }

    @Test func largeDictionaryStaysFast() {
        let rules = (0..<2000).map { DictionaryRule(heard: "term\($0)", written: "Term\($0)") }
        let text = String(repeating: "alpha term5 beta term1999 gamma ", count: 400)
        let replacer = DictionaryReplacer(rules: rules)
        let clock = ContinuousClock()
        var out = ""
        let elapsed = clock.measure { out = replacer.apply(text).text }
        #expect(out.hasPrefix("alpha Term5 beta Term1999 gamma"))
        if TextTestSupport.timingAssertsEnabled { #expect(elapsed < .seconds(1)) }
    }
}
