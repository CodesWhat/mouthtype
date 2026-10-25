import Foundation
import Testing

@testable import MouthtypeCore

@Suite struct LanguageGatingTests {
    private struct Entry: Decodable {
        let id: String
        let language: String
        let raw: String
    }

    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/multilingual")

    private static func collisions() -> [(id: String, language: DictationLanguage, raw: String)] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [(String, DictationLanguage, String)] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let entries = try? JSONDecoder().decode([Entry].self, from: data)
            else { continue }
            for e in entries where e.id.contains("-collision-") {
                if let language = DictationLanguage(code: e.language) { out.append((e.id, language, e.raw)) }
            }
        }
        return out
    }

    /// Each English-only stage on its own, with an English control it rewrites.
    private static let stages: [(name: String, options: TextPipelineOptions, control: String)] = [
        ("fillers", TextPipelineOptions.none.only { $0.fillers = true }, "um I think so"),
        ("spokenCommands", TextPipelineOptions.none.only { $0.spokenCommands = true }, "hello comma world"),
        ("numbers", TextPipelineOptions.none.only { $0.numbers = true }, "I have twenty three apples"),
        ("selfCorrection", TextPipelineOptions.none.only { $0.selfCorrection = true }, "meet at two actually three"),
        ("countedLists", TextPipelineOptions.none.only { $0.countedLists = true }, "first apples second pears third plums"),
        ("profanity", TextPipelineOptions.none.only { $0.profanity = true }, "this is fucking great"),
    ]

    @Test func collisionFixturesLoad() {
        #expect(Self.collisions().count >= 8)
    }

    @Test(arguments: stages.map(\.name))
    func englishOnlyStageDoesNothingOutsideEnglish(_ name: String) throws {
        let stage = try #require(Self.stages.first { $0.name == name })
        for c in Self.collisions() where c.language != .english {
            let input = TextPipelineInput(text: c.raw, options: stage.options, language: c.language)
            let result = TextPipeline().run(input)
            #expect(result.text == c.raw, "\(name) changed \(c.id)")
            #expect(result.edits.isEmpty, "\(name) logged edits on \(c.id)")
        }
    }

    @Test(arguments: stages.map(\.name))
    func englishControlStillChanges(_ name: String) throws {
        let stage = try #require(Self.stages.first { $0.name == name })
        for language in [nil, DictationLanguage.english] {
            let result = TextPipeline().run(TextPipelineInput(text: stage.control, options: stage.options, language: language))
            #expect(result.text != stage.control, "\(name) no longer changes the English control")
            #expect(!result.edits.isEmpty)
        }
    }

    @Test func collisionStringsSurviveTheFullPipeline() {
        for c in Self.collisions() where c.language != .english {
            let result = TextPipeline().run(TextPipelineInput(text: c.raw, language: c.language))
            #expect(result.text == c.raw, "\(c.id)")
        }
    }

    @Test func collisionStringsWereDamagedWithoutTheGate() {
        // Guards the fixtures: these are the strings that 0.5.0 rewrote.
        let damaged = ["Er kommt um drei.", "Ten dom jest duży.", "Han er her."]
        for raw in damaged {
            let result = TextPipeline().run(TextPipelineInput(text: raw))
            #expect(result.text != raw, Comment(rawValue: raw))
        }
    }

    @Test func restrictedLeavesEnglishAndNilAlone() {
        #expect(TextPipelineOptions.all.restricted(to: nil) == .all)
        #expect(TextPipelineOptions.all.restricted(to: .english) == .all)
        #expect(TextPipelineOptions.all.restricted(to: .german) != .all)
    }

    @Test func restrictedKeepsLanguageNeutralStages() {
        let r = TextPipelineOptions.all.restricted(to: .german)
        #expect(r.dictionary && r.snippets && r.notation && r.blend && r.whitespace)
        #expect(!r.fillers && !r.slashCommands && !r.spokenCommands && !r.selfCorrection)
        #expect(!r.countedLists && !r.numbers && !r.profanity)
    }

    @Test func dictionaryAndSnippetsStillRunOutsideEnglish() {
        let input = TextPipelineInput(
            text: "Wir treffen Herr Müller in Łódź.",
            dictionary: [DictionaryRule(heard: "Herr Müller", written: "Hr. Müller")],
            snippets: [],
            language: .german
        )
        #expect(TextPipeline().run(input).text == "Wir treffen Hr. Müller in Łódź.")
    }

    @Test func technicalNotationStillRunsOutsideEnglish() {
        let input = TextPipelineInput(text: "Es ist U S B", options: .all, language: .german)
        #expect(TextPipeline().run(input).text.contains("USB"))
    }

    // MARK: Blend

    @Test func germanNounStaysCapitalizedMidSentence() {
        let context = InsertionContext(before: "Wir haben einen ", after: nil)
        let german = TextPipeline().run(TextPipelineInput(text: "Hund gekauft", context: context, language: .german))
        #expect(german.text == "Hund gekauft")
        let english = TextPipeline().run(TextPipelineInput(text: "Hund gekauft", context: context))
        #expect(english.text == "hund gekauft")
    }

    @Test func otherLanguagesStillLowercaseMidSentence() {
        let context = InsertionContext(before: "Hemos comprado ", after: nil)
        let out = TextPipeline().run(TextPipelineInput(text: "Perro nuevo", context: context, language: .spanish))
        #expect(out.text == "perro nuevo")
    }

    @Test func spanishQuestionMarkSentenceStartCapitalizes() {
        let context = InsertionContext(before: "¿", after: nil)
        let out = BlendStage(context: context, language: .spanish).apply("cómo estás")
        #expect(out.text == "cómo estás")
    }

    // MARK: Language type

    @Test func codesParse() {
        #expect(DictationLanguage(code: "de-AT") == .german)
        #expect(DictationLanguage(code: "pt_BR") == .portuguese)
        #expect(DictationLanguage(code: "zh") == nil)
        #expect(DictationLanguage.allCases.count == 28)
        #expect(DictationLanguage.isEnglish(nil))
        #expect(!DictationLanguage.isEnglish(.polish))
    }
}

extension TextPipelineOptions {
    fileprivate func only(_ configure: (inout TextPipelineOptions) -> Void) -> TextPipelineOptions {
        var out = TextPipelineOptions.none
        configure(&out)
        return out
    }
}
