import Foundation
import Testing
@testable import MouthtypeCore

@Suite("Library matcher cost")
struct LibraryMatcherCostTests {
    static let dictionary: [DictionaryRule] = (0..<2000).map {
        DictionaryRule(heard: "heardword\($0) alias", written: "Written\($0)")
    }
    static let replacements: [DictionaryRule] = (0..<500).map {
        DictionaryRule(heard: "spoken phrase \($0)", written: "replacement text \($0)")
    }
    static let snippets: [Snippet] = (0..<200).map {
        Snippet(trigger: "snippet trigger \($0)", expansion: "expansion body \($0)")
    }
    static let text = "so I was thinking we should ship the new build today and then circle back on the plan tomorrow morning"

    private func takeMillis(_ input: TextPipelineInput, takes: Int) -> Double {
        let pipeline = TextPipeline()
        _ = pipeline.run(input)
        let clock = ContinuousClock()
        var samples: [Double] = []
        for _ in 0..<takes {
            let d = clock.measure { _ = pipeline.run(input) }
            samples.append(Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000)
        }
        return samples.sorted()[samples.count / 2]
    }

    @Test func largeLibraryStaysInsideTheDeterministicBudget() {
        let library = Self.dictionary + Self.replacements
        let input = TextPipelineInput(
            text: Self.text, dictionary: library, snippets: Self.snippets, options: .all, codingTarget: true
        )
        _ = TextPipeline().run(input)
        let r = TextPipeline().run(input)
        print("LIBRARY_MATCHER_COST stages:", r.stageMillis.sorted { $0.value > $1.value }.prefix(8))
        let median = takeMillis(input, takes: 15)
        print("LIBRARY_MATCHER_COST median pipeline ms: \(median)")
        // Debug build, shared machine: a loose regression bound. Rebuilding per take measured ~1050 ms here; cached ~130 ms.
        #expect(median < 500)
    }

    @Test func appendingMatchesABuildFromTheWholeList() {
        let library = ["alpha beta", "Gamma", "delta"]
        let extra = ["alpha", "GAMMA", "epsilon", ""]
        let whole = PhraseMatcher(patterns: library + extra)
        let split = PhraseMatcher(patterns: library).appending(extra)
        let chars = Array("Alpha beta gamma delta alpha epsilon")
        let lower = TextScan.lowered(chars)
        #expect(split.matches(chars, lower: lower) == whole.matches(chars, lower: lower))
        #expect(split.allMatches(chars, lower: lower) == whole.allMatches(chars, lower: lower))
    }

    @Test func sharedMatcherFollowsLibraryEdits() {
        let before = ["zebra stripes", "quokka"]
        let chars = Array("a quokka and a numbat")
        let lower = TextScan.lowered(chars)
        #expect(PhraseMatcher.shared(patterns: before).matches(chars, lower: lower).count == 1)
        #expect(PhraseMatcher.shared(patterns: before).matches(chars, lower: lower).count == 1)
        let edited = before + ["numbat"]
        #expect(PhraseMatcher.shared(patterns: edited).matches(chars, lower: lower).count == 2)
        #expect(PhraseMatcher.shared(patterns: ["unrelated"]).matches(chars, lower: lower).isEmpty)
        #expect(PhraseMatcher.shared(patterns: before).matches(chars, lower: lower).count == 1)
    }

    @Test func wordSetsFollowLibraryEdits() {
        #expect(StyleStage.words(of: ["red fox"]) == ["red", "fox"])
        #expect(StyleStage.words(of: ["red fox"]) == ["red", "fox"])
        #expect(StyleStage.words(of: ["red fox", "lazy dog"]) == ["red", "fox", "lazy", "dog"])
        #expect(BlendStage.firstWords(of: ["red fox"]) == ["red"])
        #expect(BlendStage.firstWords(of: ["red fox", "lazy dog"]) == ["red", "lazy"])
    }

    @Test func notationShieldsFollowLibraryEditsAndNearbyPhrases() {
        let text = "version 1.2.3 of USB c"
        let plain = TechnicalNotation(library: ["usb c"], extra: []).apply(text).text
        let both = TechnicalNotation(protectedPhrases: ["usb c"]).apply(text).text
        #expect(plain == both)
        let withExtra = TechnicalNotation(library: ["usb c"], extra: ["version 1.2.3"]).apply(text).text
        let whole = TechnicalNotation(protectedPhrases: ["usb c", "version 1.2.3"]).apply(text).text
        #expect(withExtra == whole)
        let edited = TechnicalNotation(library: [], extra: []).apply(text).text
        #expect(TechnicalNotation(library: ["usb c"], extra: []).apply(text).text == plain)
        #expect(edited == TechnicalNotation(protectedPhrases: []).apply(text).text)
    }
}
