import Foundation
import Testing
@testable import MouthtypeCore

/// Deterministic PRNG so the perf corpus is diverse but identical on every run.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

@Suite struct SpellingSuggesterTests {
    private func take(_ id: String, raw: String, final: String? = nil, boost: [String] = []) -> SuggestionTake {
        SuggestionTake(id: id, rawText: raw, finalText: final ?? raw, boostTermsApplied: boost, app: "Orca")
    }

    @Test func suggestsFromEnglishTakesOnly() throws {
        func lang(_ id: String, _ raw: String, _ language: DictationLanguage?) -> SuggestionTake {
            SuggestionTake(id: id, rawText: raw, finalText: raw, boostTermsApplied: ["Siobhan"], app: "Orca", language: language)
        }
        let german = [lang("g1", "ask Chavon about it", .german), lang("g2", "Chavon agreed", .german)]
        #expect(SpellingSuggester.suggest(takes: german, rules: rules).allSatisfy { $0.kind == .removeHazard })
        let russian = [lang("r1", "ask Chavon about it", .russian), lang("r2", "Chavon agreed", .russian)]
        #expect(SpellingSuggester.suggest(takes: russian, rules: rules).allSatisfy { $0.kind == .removeHazard })
        for language in [nil, DictationLanguage.english] {
            let english = [lang("e1", "ask Chavon about it", language), lang("e2", "Chavon agreed", language)]
            #expect(SpellingSuggester.suggest(takes: english, rules: rules).contains { $0.written == "Siobhan" })
        }
        let mixed = german + [lang("e1", "ask Chavon about it", nil), lang("e2", "Chavon agreed", .english)]
        let out = SpellingSuggester.suggest(takes: mixed, rules: rules)
        let s = try #require(out.first { $0.written == "Siobhan" })
        #expect(s.evidence.allSatisfy { $0.takeID.hasPrefix("e") })
    }

    private let rules = [
        DictionaryRule(heard: "shivon", written: "Siobhan"),
        DictionaryRule(heard: "praya", written: "Priya"),
        DictionaryRule(heard: "dry dock", written: "Drydock"),
        DictionaryRule(heard: "win", written: "Nguyen"),
        DictionaryRule(heard: "mouthtype", written: "Mouthtype"),
        DictionaryRule(heard: "codex", written: "Codex"),
        DictionaryRule(heard: "wispr flow", written: "Wispr Flow"),
        DictionaryRule(heard: "codeswhat", written: "CodesWhat"),
    ]

    private func filler(_ n: Int) -> [SuggestionTake] {
        (0..<n).map { take("f\($0)", raw: "we shipped the build number \($0) after lunch and everything went fine") }
    }

    @Test func misheardVariantsOfASavedNameGroupUnderIt() throws {
        let takes =
            [
                take("a", raw: "Shaban took a minute", boost: ["Siobhan"]),
                take("b", raw: "then Shaban called back"),
                take("c", raw: "Shabon took a minute"),
                take("d", raw: "Shabon agreed"),
                take("e", raw: "ask Chavon about it"),
            ] + filler(5)
        let out = SpellingSuggester.suggest(takes: takes, rules: rules)
        let s = try #require(out.first { $0.kind == .misheardVariant && $0.written == "Siobhan" })
        // Chavon is a single folded-key sighting, so it stays out.
        #expect(Set(s.heardForms) == ["shaban", "shabon"])
        #expect(s.heardForms.first == "shaban" || s.heardForms.first == "shabon")
        #expect(s.count == 4)
        #expect(s.confidence >= 0.8)
        #expect(s.evidence.contains { $0.takeID == "a" && $0.fragment.contains("Shaban") })
        #expect(out.first?.written == "Siobhan")
    }

    @Test func singleSightingIsLowerConfidenceThanRepeated() throws {
        let one = SpellingSuggester.suggest(takes: [take("a", raw: "ask Chavon about it", boost: ["Siobhan"])], rules: rules)
        let two = SpellingSuggester.suggest(takes: [take("a", raw: "ask Chavon about it", boost: ["Siobhan"]), take("b", raw: "Chavon agreed", boost: ["Siobhan"])], rules: rules)
        let c1 = try #require(one.first { $0.written == "Siobhan" }).confidence
        let c2 = try #require(two.first { $0.written == "Siobhan" }).confidence
        #expect(c1 < 0.6)
        #expect(c2 >= 0.7)
    }

    @Test func lowercaseSavedNameIsACasingSuggestion() throws {
        let takes = [take("a", raw: "email priya about the invoice", final: "Email priya about the invoice")]
        let s = try #require(SpellingSuggester.suggest(takes: takes, rules: rules).first { $0.kind == .casing })
        #expect(s.written == "Priya")
        #expect(s.heardForms == ["priya"])
        #expect(!SpellingSuggester.suggest(takes: takes, rules: rules).contains { $0.kind == .misheardVariant && $0.written == "Priya" })
    }

    @Test func brandCasingIsLearnedFromFinals() throws {
        let takes = [
            take("a", raw: "i read feedly every day", final: "I read Feedly every day"),
            take("b", raw: "moved off feedly last week", final: "Moved off Feedly last week"),
            take("c", raw: "the feedly export is broken", final: "The feedly export is broken"),
        ]
        let s = try #require(SpellingSuggester.suggest(takes: takes, rules: []).first { $0.kind == .casing })
        #expect(s.written == "Feedly")
        #expect(s.heardForms == ["feedly"])
        #expect(s.count >= 3)
    }

    private func titled(_ word: String) -> [SuggestionTake] {
        let cap = word.prefix(1).uppercased() + word.dropFirst()
        return [
            take("a", raw: "i read \(word) every day", final: "I read \(cap) every day"),
            take("b", raw: "moved off \(word) last week", final: "Moved off \(cap) last week"),
            take("c", raw: "the \(word) export is broken", final: "The \(cap) export is broken"),
        ]
    }

    @Test func ordinaryEnglishWordsAreNotSuggestedAsCapitalised() {
        let english: @Sendable (String) -> Bool = { ["candy", "press", "peer", "lure"].contains($0) }
        for word in ["candy", "press", "peer", "lure"] {
            #expect(SpellingSuggester.suggest(takes: titled(word), rules: [], isKnownWord: english).isEmpty, "\(word)")
        }
    }

    @Test func unknownWordsStillGetTitleCase() throws {
        let english: @Sendable (String) -> Bool = { ["candy", "press"].contains($0) }
        for word in ["feedly", "tailscale"] {
            let s = try #require(SpellingSuggester.suggest(takes: titled(word), rules: [], isKnownWord: english).first { $0.kind == .casing })
            #expect(s.heardForms == [word])
        }
    }

    @Test func innerCapitalBrandIsAllowedEvenWhenLowercaseIsAWord() throws {
        let takes = [
            take("a", raw: "push it to github", final: "Push it to GitHub"),
            take("b", raw: "open github now", final: "Open GitHub now"),
        ]
        let s = try #require(SpellingSuggester.suggest(takes: takes, rules: [], isKnownWord: { _ in true }).first { $0.kind == .casing })
        #expect(s.written == "GitHub")
    }

    @Test func savedCapitalisedFormIsAllowedEvenWhenLowercaseIsAWord() throws {
        let takes = [take("a", raw: "email priya about the invoice", final: "Email priya about the invoice")]
        let s = try #require(SpellingSuggester.suggest(takes: takes, rules: rules, isKnownWord: { _ in true }).first { $0.kind == .casing })
        #expect(s.written == "Priya")
    }

    @Test func knownWordsAreNotSuggestedAsHeardForms() {
        let takes = [take("a", raw: "ask Shaban about it", boost: ["Siobhan"]), take("b", raw: "then Shaban called")]
        #expect(SpellingSuggester.suggest(takes: takes, rules: rules).contains { $0.written == "Siobhan" })
        #expect(!SpellingSuggester.suggest(takes: takes, rules: rules, isKnownWord: { $0 == "shaban" }).contains { $0.written == "Siobhan" })
    }

    @Test func sentenceStartCapitalisationAloneIsNotABrand() {
        let takes = [
            take("a", raw: "later we left", final: "Later we left"),
            take("b", raw: "later we met", final: "Later we met"),
        ]
        #expect(SpellingSuggester.suggest(takes: takes, rules: []).isEmpty)
    }

    @Test func splitCompoundsJoinIntoTheSavedForm() throws {
        let takes = [
            take("a", raw: "Dry Doc and Sockguard share a repo"),
            take("b", raw: "we should have the codes what footer"),
            take("c", raw: "a whisper flow replacement"),
        ]
        let out = SpellingSuggester.suggest(takes: takes, rules: rules)
        let drydock = try #require(out.first { $0.kind == .joinedCompound && $0.written == "Drydock" })
        #expect(drydock.heardForms == ["dry doc"])
        let codes = try #require(out.first { $0.kind == .joinedCompound && $0.written == "CodesWhat" })
        #expect(codes.heardForms == ["codes what"])
        let wispr = try #require(out.first { $0.kind == .joinedCompound && $0.written == "Wispr Flow" })
        #expect(wispr.heardForms == ["whisper flow"])
    }

    @Test func frequentBrandTokenInFinalsIsACompoundTarget() throws {
        let takes = [
            take("a", raw: "open git hub now", final: "Open GitHub now"),
            take("b", raw: "push to git hub", final: "Push to GitHub"),
        ]
        let s = try #require(SpellingSuggester.suggest(takes: takes, rules: []).first { $0.kind == .joinedCompound })
        #expect(s.written == "GitHub")
        #expect(s.heardForms == ["git hub"])
    }

    @Test func ordinaryWordHeardFormIsAHazard() throws {
        let takes = [take("a", raw: "i hope we win the contract")]
        let s = try #require(SpellingSuggester.suggest(takes: takes, rules: rules).first { $0.kind == .removeHazard })
        #expect(s.heardForms == ["win"])
        #expect(s.written == "Nguyen")
        #expect(s.count == 1)
        #expect(s.evidence.first?.takeID == "a")
    }

    @Test func starredOrdinaryRuleIsNotAHazard() {
        let starred = [DictionaryRule(heard: "win", written: "Nguyen", starred: true)]
        #expect(SpellingSuggester.suggest(takes: [take("a", raw: "we win")], rules: starred).isEmpty)
    }

    @Test func unusedRuleIsAHazardOnlyInALongHistory() throws {
        let r = [DictionaryRule(heard: "shivon", written: "Siobhan")]
        #expect(SpellingSuggester.suggest(takes: filler(20), rules: r).isEmpty)
        let long = SpellingSuggester.suggest(takes: filler(150), rules: r)
        let s = try #require(long.first)
        #expect(s.kind == .removeHazard)
        #expect(s.confidence <= 0.3)
        // casing-only rules are harmless and stay quiet
        let casing = [DictionaryRule(heard: "mouthtype", written: "Mouthtype")]
        #expect(SpellingSuggester.suggest(takes: filler(150), rules: casing).isEmpty)
    }

    @Test func neverSuggestsOrdinaryWordsOrSavedForms() {
        let r = [DictionaryRule(heard: "shivon", written: "Siobhan"), DictionaryRule(heard: "shaban", written: "Siobhan")]
        let takes = [
            take("a", raw: "Shaban took a minute"), take("b", raw: "Shaban again"),
            take("c", raw: "let us win this season"), take("d", raw: "the sea son changed"),
        ]
        let out = SpellingSuggester.suggest(takes: takes, rules: r)
        for s in out where s.kind != .removeHazard {
            #expect(!s.heardForms.contains("shaban"))
            for form in s.heardForms { #expect(!OrdinaryWords.isOrdinary(form) || form.contains(" "), "\(form)") }
        }
        #expect(!out.contains { $0.heardForms.contains("win") })
    }

    @Test func ordinaryWordIsNotACasingSuggestion() {
        let r = [DictionaryRule(heard: "will", written: "Will")]
        #expect(SpellingSuggester.suggest(takes: [take("a", raw: "i will go", final: "I will go")], rules: r).isEmpty)
    }

    @Test func correctionsBecomeSuggestions() throws {
        let c = [CorrectionProposal(heard: "sock gard", corrected: "Sockguard")]
        let s = try #require(SpellingSuggester.suggest(takes: [], rules: [], corrections: c).first)
        #expect(s.written == "Sockguard")
        #expect(s.heardForms == ["sock gard"])
        #expect(s.evidence.first?.takeID == "correction")
    }

    @Test func ranksByConfidenceThenCount() {
        let takes = [
            take("a", raw: "Shaban took a minute", boost: ["Siobhan"]), take("b", raw: "Shaban called"), take("c", raw: "Shabon too"),
            take("d", raw: "email priya", final: "Email priya"),
            take("e", raw: "we win again"),
        ]
        let out = SpellingSuggester.suggest(takes: takes, rules: rules)
        #expect(out.count >= 3)
        #expect(out.map(\.confidence) == out.map(\.confidence).sorted(by: >))
        #expect(out.first?.written == "Siobhan")
    }

    @Test func outputIsCappedAndLimitIsHonoured() {
        var r: [DictionaryRule] = []
        var takes: [SuggestionTake] = []
        for i in 0..<40 {
            let name = "Zorvex\(String(UnicodeScalar(UInt8(97 + i % 26))))\(String(UnicodeScalar(UInt8(97 + i / 26))))"
            r.append(DictionaryRule(heard: "x\(i)", written: name))
            takes.append(take("t\(i)", raw: "ask \(name.lowercased()) now", final: "Ask \(name) now"))
        }
        #expect(SpellingSuggester.suggest(takes: takes, rules: r).count <= 20)
        #expect(SpellingSuggester.suggest(takes: takes, rules: r, limit: 5).count <= 5)
    }

    @Test func emptyInputsGiveNothing() {
        #expect(SpellingSuggester.suggest(takes: [], rules: []).isEmpty)
        #expect(SpellingSuggester.suggest(takes: [take("a", raw: "", final: "")], rules: [DictionaryRule(heard: "shivon", written: "Siobhan")]).isEmpty)
    }

    @Test func thousandTakesStayFast() {
        let brands = [
            "Drydock", "Sockguard", "Portwing", "Mouthtype", "Wispr Flow", "CodesWhat", "Siobhan", "Priya", "Nguyen", "Kubernetes", "Tailscale", "Postgres", "Grafana", "Terraform", "Cloudflare",
            "Anthropic", "Figma", "Linear", "Notion", "Vercel", "Supabase", "Stripe", "Datadog", "Sentry", "Raycast", "Obsidian", "Homebrew", "Xcode", "Swiftly", "Cursor", "Ghostty", "Warp", "Zed",
            "Docker", "Compose", "Nginx", "Traefik", "Caddy", "Prometheus", "Loki", "Tempo", "Mimir", "Alloy", "Vector", "Fluentd", "Kibana", "Elastic", "Mongo", "Redis", "Valkey", "Kafka", "Pulsar",
            "Temporal", "Dagster", "Airflow", "Metabase", "Superset", "Retool", "Zapier",
        ]
        let r = brands.enumerated().map { DictionaryRule(heard: "heard\($0.offset)", written: $0.element) }
        let syllables = ["ka", "lo", "mi", "ra", "te", "vu", "no", "pi", "sa", "du", "fe", "gro", "bli", "tre", "sho", "quan", "zel", "man", "dor", "win"]
        var rng = SplitMix64(seed: 0x4D6F757468)
        var takes: [SuggestionTake] = []
        for i in 0..<1000 {
            let words = (0..<45).map { _ -> String in
                (0..<Int.random(in: 1...3, using: &rng)).map { _ in syllables.randomElement(using: &rng)! }.joined()
            }
            var raw = words.joined(separator: " ")
            if i % 50 == 0 { raw += " Shaban and dry doc and priya" }
            takes.append(take("t\(i)", raw: raw))
        }
        #expect(Set(takes.map(\.rawText)).count == 1000)
        let start = Date()
        let out = SpellingSuggester.suggest(takes: takes, rules: r, limit: 100)
        let elapsed = Date().timeIntervalSince(start)
        print("SpellingSuggester 1000 takes, \(r.count) rules: \(Int(elapsed * 1000)) ms")
        if TextTestSupport.timingAssertsEnabled { #expect(elapsed < 2.0) }
        #expect(out.contains { $0.written == "Siobhan" })
        #expect(out.contains { $0.written == "Drydock" })
    }

    @Test func savedHyphenRuleIsCountedAndNotSuggestedForRemoval() {
        let r = [DictionaryRule(heard: "git-hub", written: "GitHub")]
        let takes = (0..<120).map { take("t\($0)", raw: "open git-hub for build \($0) please") }
        let out = SpellingSuggester.suggest(takes: takes, rules: r)
        #expect(!out.contains { $0.kind == .removeHazard })
        // Without any raw match the same history does recommend removal.
        let unused = SpellingSuggester.suggest(takes: filler(120), rules: r)
        #expect(unused.contains { $0.kind == .removeHazard })
    }

    @Test func boundaryApostrophesBreakCompounds() {
        let takes = [take("a", raw: "a 'dry' doc called"), take("b", raw: "the 'dry' doc again")]
        let out = SpellingSuggester.suggest(takes: takes, rules: rules)
        #expect(!out.contains { $0.kind == .joinedCompound && $0.written == "Drydock" })
    }

    @Test func boundedDistanceAgreesWithFullDistance() {
        var rng = SplitMix64(seed: 7)
        let alphabet = Array("abc")
        func word() -> String { String((0..<Int.random(in: 0...6, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }) }
        for _ in 0..<2000 {
            let a = word(), b = word()
            let full = PhoneticKey.distance(a, b)
            for limit in 1...3 {
                let got = SpellingSuggester.boundedDistanceForTesting(a, b, limit: limit)
                #expect(got == (full <= limit ? full : nil), "\(a) \(b) \(limit)")
            }
        }
    }

    @Test func lookAlikeNamesStayLowConfidence() throws {
        let chopin = (0..<3).map { take("c\($0)", raw: "we played Chopin on the radio \($0)") }
        let low = SpellingSuggester.suggest(takes: chopin, rules: rules).filter { $0.written == "Siobhan" }
        #expect(low.allSatisfy { $0.confidence <= 0.5 })
        let names = [take("a", raw: "ask Shaban about it"), take("b", raw: "Chavon agreed"), take("c", raw: "then Shaban left"), take("d", raw: "so Chavon called")]
        let weak = try #require(SpellingSuggester.suggest(takes: names, rules: rules).first { $0.written == "Siobhan" })
        #expect(weak.confidence <= 0.5)
        let corrected = SpellingSuggester.suggest(takes: names, rules: rules, corrections: [CorrectionProposal(heard: "Shaban", corrected: "Siobhan")])
        #expect(try #require(corrected.first { $0.written == "Siobhan" }).confidence >= 0.8)
    }

    @Test func ordinaryPhrasesNeverJoinFuzzily() {
        let r = [DictionaryRule(heard: "new york", written: "NewYork")]
        let out = SpellingSuggester.suggest(takes: [take("a", raw: "a new work plan"), take("b", raw: "the new work item")], rules: r)
        #expect(!out.contains { $0.kind == .joinedCompound })
    }

    @Test func compoundsDoNotCrossPunctuationOrSentences() {
        let takes = [take("a", raw: "Let it dry. Doc called back."), take("b", raw: "we let it dry, doc called")]
        let out = SpellingSuggester.suggest(takes: takes, rules: rules)
        #expect(!out.contains { $0.kind == .joinedCompound && $0.written == "Drydock" })
    }

    @Test func evidenceKeepsOriginalPunctuation() throws {
        let takes = [take("a", raw: "Sure, Dry Doc, and Sockguard share a repo"), take("b", raw: "the dry doc, again")]
        let s = try #require(SpellingSuggester.suggest(takes: takes, rules: rules).first { $0.written == "Drydock" })
        #expect(s.evidence.contains { $0.fragment.contains("Sure, Dry Doc, and") })
    }

    @Test func compoundTargetSpellingIsDeterministic() throws {
        for order in [["GitHub", "Github"], ["Github", "GitHub"]] {
            let takes = zip(["a", "b"], order).map { id, form in take(id, raw: "open git hub now", final: "Open \(form) now") }
            for _ in 0..<5 {
                let s = try #require(SpellingSuggester.suggest(takes: takes, rules: []).first { $0.kind == .joinedCompound })
                #expect(s.written == "GitHub")
            }
        }
    }

    @Test func unchangedOutputIsOneSightingNotTwo() throws {
        let takes = [take("a", raw: "email priya about it", final: "email priya about it")]
        let s = try #require(SpellingSuggester.suggest(takes: takes, rules: rules).first { $0.kind == .casing })
        #expect(s.count == 1)
        #expect(s.confidence < 0.7)
    }

    @Test func phoneticKeysFoldTheNameVariants() {
        let keys = Set(["siobhan", "shaban", "shabon", "chavon"].map(PhoneticKey.classKey))
        #expect(keys.count == 1)
        #expect(PhoneticKey.classKey("priya") == PhoneticKey.classKey("praya"))
        #expect(PhoneticKey.classKey("win") != PhoneticKey.classKey("siobhan"))
    }

    @Test func cancelledRunReturnsEarlyWithNothing() async {
        let takes = [take("a", raw: "Shaban took a minute"), take("b", raw: "then Shaban called back")] + filler(300)
        let expected = SpellingSuggester.suggest(takes: takes, rules: rules)
        #expect(!expected.isEmpty)
        let task = Task { () -> [SpellingSuggestion] in
            while !Task.isCancelled { await Task.yield() }
            return SpellingSuggester.suggest(takes: takes, rules: rules)
        }
        task.cancel()
        #expect(await task.value.isEmpty)
    }

}
