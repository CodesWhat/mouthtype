import Foundation
import Testing
@testable import MouthtypeCore

@Suite struct SpellingSuggesterTests {
    private func take(_ id: String, raw: String, final: String? = nil, boost: [String] = []) -> SuggestionTake {
        SuggestionTake(id: id, rawText: raw, finalText: final ?? raw, boostTermsApplied: boost, app: "Orca")
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
        let takes = [
            take("a", raw: "Shaban took a minute", boost: ["Siobhan"]),
            take("b", raw: "then Shaban called back"),
            take("c", raw: "Shabon took a minute"),
            take("d", raw: "ask Chavon about it"),
        ] + filler(5)
        let out = SpellingSuggester.suggest(takes: takes, rules: rules)
        let s = try #require(out.first { $0.kind == .misheardVariant && $0.written == "Siobhan" })
        #expect(Set(s.heardForms) == ["shaban", "shabon", "chavon"])
        #expect(s.heardForms.first == "shaban")
        #expect(s.count == 4)
        #expect(s.confidence >= 0.8)
        #expect(s.evidence.contains { $0.takeID == "a" && $0.fragment.contains("Shaban") })
        #expect(out.first?.written == "Siobhan")
    }

    @Test func singleSightingIsLowerConfidenceThanRepeated() throws {
        let one = SpellingSuggester.suggest(takes: [take("a", raw: "ask Chavon about it")], rules: rules)
        let two = SpellingSuggester.suggest(takes: [take("a", raw: "ask Chavon about it"), take("b", raw: "Chavon agreed")], rules: rules)
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
            take("a", raw: "Shaban took a minute"), take("b", raw: "Shaban called"), take("c", raw: "Shabon too"),
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
        var takes: [SuggestionTake] = []
        let vocab = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet", "kilo", "lima", "mike", "november", "oscar", "papa", "quebec", "romeo", "sierra", "tango", "uniform", "victor", "whiskey", "xray", "yankee", "zulu"]
        for i in 0..<1000 {
            let words = (0..<45).map { vocab[($0 * 7 + i * 3 + $0 / 3) % vocab.count] + (($0 + i) % 11 == 0 ? "\($0 % 5)x" : "") }
            var raw = words.joined(separator: " ")
            if i % 50 == 0 { raw += " Shaban and dry doc and priya" }
            takes.append(take("t\(i)", raw: raw, final: raw.capitalized))
        }
        let r = rules + (0..<60).map { DictionaryRule(heard: "heard\($0)", written: "Written\($0)") }
        let start = Date()
        let out = SpellingSuggester.suggest(takes: takes, rules: r)
        let elapsed = Date().timeIntervalSince(start)
        print("SpellingSuggester 1000 takes: \(Int(elapsed * 1000)) ms")
        #expect(elapsed < 1.0)
        #expect(out.contains { $0.written == "Siobhan" })
    }

    @Test func phoneticKeysFoldTheNameVariants() {
        let keys = Set(["siobhan", "shaban", "shabon", "chavon"].map(PhoneticKey.classKey))
        #expect(keys.count == 1)
        #expect(PhoneticKey.classKey("priya") == PhoneticKey.classKey("praya"))
        #expect(PhoneticKey.classKey("win") != PhoneticKey.classKey("siobhan"))
    }
}
