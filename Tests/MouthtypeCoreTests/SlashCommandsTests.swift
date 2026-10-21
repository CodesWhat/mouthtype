import Foundation
import Testing
@testable import MouthtypeCore

@Suite struct SlashCommandsTests {
    private func run(_ text: String, protected: [String] = []) -> String {
        SlashCommands(protectedPhrases: protected).apply(text).text
    }

    private func pipeline(_ text: String, coding: Bool, dictionary: [DictionaryRule] = [], options: TextPipelineOptions = .all) -> String {
        TextPipeline().run(TextPipelineInput(text: text, dictionary: dictionary, options: options, codingTarget: coding)).text
    }

    @Test(arguments: [
        TextCase("slash research", "/research"),
        TextCase("Slash Research", "/research"),
        TextCase("SLASH RESEARCH", "/research"),
        TextCase("forward slash research", "/research"),
        TextCase("Do we want to do a slash research?", "Do we want to do a /research?"),
        TextCase("run slash review now", "run /review now"),
        TextCase("ok. slash compact", "ok. /compact"),
        TextCase("ok, slash compact, then go", "ok, /compact, then go"),
        TextCase("slash research.", "/research"),
        TextCase("Slash research.", "/research"),
        TextCase("Slash research?", "/research"),
        TextCase("slash research!  ", "/research  "),
        TextCase("do slash research.", "do /research."),
        TextCase("slash research. then go", "/research. then go"),
        TextCase("slash code dash review", "/code-review"),
        TextCase("slash code hyphen review", "/code-review"),
        TextCase("slash pr underscore comments", "/pr_comments"),
        TextCase("slash x dash b underscore c", "/x-b_c"),
        TextCase("slash code dash", "/code dash"),
        TextCase("slash research and slash review", "/research and /review"),
        TextCase("slash research then dash", "/research then dash"),
    ])
    func convertsSpokenSlashCommands(_ item: TextCase) {
        #expect(run(item.input) == item.expected)
    }

    @Test(arguments: [
        "slash", "go to the slash", "slash 2", "slash 2fa", "and slash or", "a slash of paint",
        "slash\nresearch", "/research", "run /research now", "slash /research", "slash src/app.swift",
        "use `slash research` literally", "slashing prices", "Press the slash key", "A forward slash separates paths", "the slash character", "type a slash symbol",
        "a back slash fixes it", "a forward slash separates paths", "the forward slash key", "double slash comments", "trailing slash redirects",
        "slash the budget", "press slash key", "this slash mark", "slash, research",
    ])
    func leavesEverythingElseAlone(_ input: String) {
        #expect(run(input) == input)
    }

    @Test func protectedPhrasesAreLeftAlone() {
        #expect(run("say slash research", protected: ["slash research"]) == "say slash research")
        #expect(run("say slash research", protected: ["Slash Research"]) == "say slash research")
        #expect(run("say slash research and slash review", protected: ["slash research"]) == "say slash research and /review")
    }

    @Test func editsReplayAgainstTheInput() {
        let input = "😀 café slash code dash review now"
        let result = SlashCommands().apply(input)
        #expect(result.text == "😀 café /code-review now")
        #expect(result.edits.count == 1 && result.edits[0].stage == SlashCommands.stageName)
        #expect(TextTestSupport.replay(result.edits, on: input) == TextTestSupport.stripWhitespace(result.text))
    }

    @Test func pipelineOnlyRunsItForACodingTarget() {
        #expect(pipeline("slash research", coding: true) == "/research")
        #expect(pipeline("Do we want to do a slash research?", coding: true) == "Do we want to do a /research?")
        #expect(pipeline("Do we want to do a slash research?", coding: false) == "Do we want to do a slash research?")
        #expect(pipeline("and slash or", coding: false) == "And slash or")
        let off = TextPipelineOptions(slashCommands: false)
        #expect(pipeline("slash research", coding: true, options: off) == "Slash research")
    }

    @Test func nonCodingTargetsNeverConvert() {
        for text in ["and slash or", "Slash research.", "slash code dash review", "slash newline"] {
            let out = pipeline(text, coding: false)
            #expect(!out.contains("/"), Comment(rawValue: text))
        }
        #expect(pipeline("Slash research.", coding: false) == "Slash research.")
    }

    @Test func generatedNamesSurviveLaterStages() {
        #expect(pipeline("slash newline", coding: true) == "/newline")
        #expect(pipeline("slash new line", coding: true) == "/new line")
        #expect(pipeline("run slash newline now", coding: true) == "Run /newline now")
        #expect(pipeline("slash new dash line", coding: true) == "/new-line")
        #expect(pipeline("slash new underscore paragraph", coding: true) == "/new_paragraph")
        #expect(pipeline("slash code dash review", coding: true) == "/code-review")
        #expect(pipeline("slash research dash comma", coding: true) == "/research-comma")
        #expect(pipeline("slash period", coding: true) == "/period")
    }

    @Test func wrappedNamesSurviveLaterStages() {
        #expect(pipeline("Run (slash newline) now", coding: true) == "Run (/newline) now")
        #expect(pipeline("Run [slash newline] now", coding: true) == "Run [/newline] now")
        #expect(pipeline("Run \"slash newline\" now", coding: true) == "Run \"/newline\" now")
        #expect(pipeline("Run \u{201C}slash newline\u{201D} now", coding: true) == "Run \u{201C}/newline\u{201D} now")
        #expect(pipeline("Run 'slash newline' now", coding: true) == "Run '/newline' now")
        #expect(pipeline("Run (slash new dash line) now", coding: true) == "Run (/new-line) now")
        // An already typed command inside backticks is left as it is.
        #expect(pipeline("Run `/newline` now", coding: true) == "Run `/newline` now")
    }

    @Test func pipelineRunsItBeforeSpokenCommandsAndNumbers() {
        // Spoken commands would otherwise turn "dash" into " - " and break the join.
        #expect(pipeline("slash code dash review", coding: true) == "/code-review")
        #expect(pipeline("slash pr underscore comments", coding: true) == "/pr_comments")
        #expect(pipeline("slash code hyphen review", coding: true) == "/code-review")
        // Spoken commands and numbers still run on the rest of the text.
        #expect(pipeline("slash research new line step two", coding: true).contains("/research"))
        #expect(pipeline("slash two", coding: true) == "/two")
        #expect(pipeline("slash research and twenty five", coding: true) == "/research and 25")
        // Without the stage, "dash" is a spoken command, which is why it runs first.
        #expect(pipeline("code dash review", coding: true) == "Code - review")
    }

    @Test func dictionaryRulesProtectTheirPhrases() {
        let rule = DictionaryRule(heard: "slash research", written: "SlashResearch")
        #expect(pipeline("run slash research", coding: true, dictionary: [rule]) == "Run SlashResearch")
    }

    @Test func offByDefaultInNoneAndWithoutATarget() {
        #expect(TextPipelineOptions.none.slashCommands == false)
        #expect(TextPipelineInput(text: "x").codingTarget == false)
    }
}
