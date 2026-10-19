import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

/// A cleaner that answers from a closure and counts its calls.
final class ScriptedCleaner: TextCleaner, @unchecked Sendable {
    let id = "scripted"
    let displayName = "Scripted"
    private let lock = NSLock()
    private var _calls = 0
    private let respond: @Sendable (String, CleanupContext) async throws -> String

    init(_ respond: @escaping @Sendable (String, CleanupContext) async throws -> String) { self.respond = respond }
    convenience init(returning output: String) { self.init { _, _ in output } }

    var calls: Int { lock.withLock { _calls } }

    func prepare() async throws {}

    func clean(_ transcript: String, context: CleanupContext) async throws -> String {
        lock.withLock { _calls += 1 }
        return try await respond(transcript, context)
    }
}

@MainActor
private final class StubEngine: DictationEngine {
    var readiness: EngineReadiness { .ready }
    func transcribe(samples: [Float]) async throws -> Transcription {
        Transcription(text: "", processingSeconds: 0, engineID: "stub")
    }
}

/// The host's role for the pipeline: readiness decided by the test, the model pass a real `SmartCleanup`.
private final class StubSmart: SmartCleaning, @unchecked Sendable {
    let service: SmartCleanup
    var info: SmartCleanerInfo? = SmartCleanerInfo(id: "superwhisper-s1-mini", revision: "rev1")
    private(set) var recordings = 0

    init(_ service: SmartCleanup) { self.service = service }

    func readiness(waitingUpTo limit: Duration) async -> SmartCleanerInfo? { info }
    func run(_ request: SmartCleanupRequest) async -> SmartCleanupResult { await service.run(request) }
    func recordingStarted() { recordings += 1 }
}

private struct Rules: VocabularyProviding {
    var rules: [DictionaryRule] = []
    var phrases: [Snippet] = []
    func dictionary() -> [DictionaryRule] { rules }
    func snippets() -> [Snippet] { phrases }
}

private final class CleanupDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [String] = []
    func record(_ message: String) { lock.withLock { captured.append(message) } }
    var messages: [String] { lock.withLock { captured } }
}

private struct CleanupDiagnosticFixtureError: Error, CustomStringConvertible {
    var description: String
}

@MainActor
@Suite struct SmartCleanupPipelineTests {
    private let raw = "um let's grab coffee at two"
    private let det = "Let's grab coffee at two"

    private func pipeline(
        _ cleaner: ScriptedCleaner, level: CleanupLevel = .light, budgetMs: Int = 2000, rules: [DictionaryRule] = [],
        style: StyleOptions = .formal, ready: Bool = true, snippets: [Snippet] = []
    ) -> (DictationPipeline, StubSmart) {
        let smart = StubSmart(SmartCleanup(cleaner: cleaner, budget: { _ in .milliseconds(budgetMs) }))
        if !ready { smart.info = nil }
        var pipeline = DictationPipeline(store: nil, archive: nil, engine: StubEngine(), clock: SystemDictationClock())
        var chosen = CleanupSettings()
        chosen.level = level
        chosen.style = style
        let settings = chosen
        pipeline.settings = { settings }
        pipeline.vocabulary = Rules(rules: rules, phrases: snippets)
        pipeline.smart = smart
        return (pipeline, smart)
    }

    private func clean(_ pipeline: DictationPipeline, text: String? = nil, context: InsertionContext? = nil, appName: String? = nil, clipboard: String? = nil) async -> CleanedDictation {
        let transcribed = TranscribedDictation(text: text ?? raw, rawText: text ?? raw, asrDoneMs: 0, words: [])
        return await pipeline.clean(transcribed, inputs: pipeline.cleanupInputs(), context: context, clipboard: clipboard, appName: appName)
    }

    @Test(arguments: [CleanupLevel.basic, .light, .medium])
    func appToneChangesOnlyPresentationAndPreservesCleanupSelection(level: CleanupLevel) async throws {
        var (pipeline, _) = pipeline(ScriptedCleaner { text, _ in text }, level: level)
        var styles = AppCleanupStyles()
        try styles.set(bundleID: "org.example.chat", appName: "Chat", style: StylePreset.casual.options)
        let configured = styles
        pipeline.appStyles = { configured }
        let style = pipeline.cleanupStyle(forBundleID: "org.example.chat")
        let inputs = pipeline.cleanupInputs(style: style)
        #expect(inputs.settings.level == level)
        #expect(inputs.settings.fillers && inputs.settings.numbers && inputs.settings.spokenCommands)
        let result = await pipeline.clean(
            TranscribedDictation(text: "See Maya Friday.", rawText: "See Maya Friday.", asrDoneMs: 0, words: []),
            inputs: inputs, context: nil, clipboard: nil
        )
        #expect(result.text == "See Maya Friday")
        #expect(result.cleanup.style == "casual")
        #expect(pipeline.cleanupInputs().settings.style == .formal)
    }

    @Test(arguments: [CleanupLevel.basic, .light, .medium], StylePreset.allCases)
    func savedReplacementTextSurvivesEveryCleanupLevelAndTone(level: CleanupLevel, style: StylePreset) async {
        let expansion = "  Best regards,\n\tScott  "
        let cleaner = ScriptedCleaner { text, _ in
            #expect(!text.contains("Best regards") && !text.contains("Scott"))
            return text
        }
        let (pipeline, _) = pipeline(cleaner, level: level, style: style.options,
            snippets: [Snippet(trigger: "my signature", expansion: expansion)])
        let result = await clean(pipeline, text: "my signature")
        #expect(result.text == expansion)
        #expect(result.edits.contains { $0.stage == "snippet" && $0.fromText?.lowercased() == "my signature" && $0.toText == expansion.trimmingCharacters(in: CharacterSet(charactersIn: " \t")) })
    }

    @Test func aConfiguredEmailExpandsWithinASentenceAfterTheModel() async {
        let cleaner = ScriptedCleaner(returning: "Send this to my JSQ email please.")
        let (pipeline, _) = pipeline(cleaner,
            snippets: [Snippet(trigger: "my JSQ email", expansion: "configured@example.com")])
        #expect(await clean(pipeline, text: "send this to my JSQ email please").text == "Send this to configured@example.com please.")
    }

    @Test func aTriggerThatDeterministicCleanupWouldRemoveStillExpands() async {
        let (pipeline, _) = pipeline(ScriptedCleaner { text, _ in text }, level: .basic,
            snippets: [Snippet(trigger: "um my email", expansion: "configured@example.com")])
        #expect(await clean(pipeline, text: "um my email").text == "configured@example.com")
    }

    @Test func aModelCannotActivateAnUnspokenTrigger() async {
        let (pipeline, _) = pipeline(ScriptedCleaner(returning: "Write a friendly note with my work email."),
            snippets: [Snippet(trigger: "my work email", expansion: "configured@example.com")])
        let result = await clean(pipeline, text: "write a friendly note")
        #expect(result.text == "Write a friendly note")
        #expect(result.cleanup.outcome == "guard-rejected")
    }

    @Test func variablesUseTheCapturedDateAndClipboardWithoutModelEdits() async {
        let (pipeline, _) = pipeline(ScriptedCleaner { text, _ in text },
            snippets: [Snippet(trigger: "my note", expansion: "{DATE}\n{CLIPBOARD}")])
        var inputs = pipeline.cleanupInputs()
        inputs.now = Date(timeIntervalSince1970: 1_791_763_200)
        #expect(inputs.needsClipboard)
        let result = await pipeline.clean(TranscribedDictation(text: "my note", rawText: "my note", asrDoneMs: 0, words: []),
            inputs: inputs, context: nil, clipboard: "  unchanged {date}\nsecond line  ")
        let date = SnippetExpander.defaultDateFormatter(inputs.now)
        #expect(result.text == date + "\n  unchanged {date}\nsecond line  ")
    }

    @Test func modelCannotRemoveOrChangeASpokenTrigger() async {
        let (pipeline, _) = pipeline(ScriptedCleaner(returning: "Use my personal email please."),
            snippets: [Snippet(trigger: "my work email", expansion: "work@example.com"),
                       Snippet(trigger: "my personal email", expansion: "private@example.com")])
        let result = await clean(pipeline, text: "use my work email please")
        #expect(result.text == "Use work@example.com please")
        #expect(result.cleanup.outcome == "guard-rejected")
    }

    @Test func unavailableModelStillExpandsButOffDoesNot() async {
        let phrase = Snippet(trigger: "my email", expansion: "configured@example.com")
        let (basic, _) = pipeline(ScriptedCleaner(returning: "never"), ready: false, snippets: [phrase])
        #expect(await clean(basic, text: "my email").text == phrase.expansion)
        let (off, _) = pipeline(ScriptedCleaner(returning: "never"), level: .off, snippets: [phrase])
        #expect(await clean(off, text: "my email").text == "my email")
    }

    @Test func capturedVocabularyIsUsedEvenAfterTheFileChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FilePhrases(url: directory.appendingPathComponent("phrases.json"))
        let phrase = Snippet(trigger: "my email", expansion: "first@example.com")
        try store.save(original: nil, phrase: phrase)
        var (pipeline, _) = pipeline(ScriptedCleaner { text, _ in text })
        pipeline.vocabulary = SavedVocabulary(words: FileVocabulary(url: directory.appendingPathComponent("dictionary.json")), phrases: store)
        let captured = pipeline.cleanupInputs()
        try store.save(original: phrase, phrase: Snippet(trigger: phrase.trigger, expansion: "second@example.com"))
        let result = await pipeline.clean(TranscribedDictation(text: "my email", rawText: "my email", asrDoneMs: 0, words: []),
                                          inputs: captured, context: nil, clipboard: nil)
        #expect(result.text == "first@example.com")
        #expect(pipeline.cleanupInputs().snippets.first?.expansion == "second@example.com")
    }

    @Test func joiningDictionaryEntriesWaitForContextInsteadOfRewritingPhysicalObjects() async {
        let cleaner = ScriptedCleaner { text, _ in text }
        let rules = [DictionaryRule(heard: "dry dock", written: "Drydock"), DictionaryRule(heard: "drydock", written: "Drydock")]
        let (pipeline, _) = pipeline(cleaner, rules: rules)
        let result = await clean(pipeline, text: "the boat is in dry dock")
        #expect(result.text == "The boat is in dry dock")
    }

    @Test func cursorAndAppContextReachTheCleanupModel() async {
        let cleaner = ScriptedCleaner { _, context in
            #expect(context.before == "Recipient: Mary\n")
            #expect(context.after == nil)
            #expect(context.appName == "Mail")
            return "Send this to Mary."
        }
        let (pipeline, _) = pipeline(cleaner)
        let result = await clean(pipeline, text: "send this to merry", context: InsertionContext(before: "Recipient: Mary\n"), appName: "Mail")
        #expect(result.text == "Send this to Mary." && result.cleanup.outcome == "ok")
    }

    @Test func theModelRunsOnTheDeterministicTextAndTheRecordSaysSo() async throws {
        let cleaner = ScriptedCleaner { text, _ in
            #expect(text == "Let's grab coffee at two")
            return "Let's grab coffee at 2."
        }
        let (pipeline, _) = pipeline(cleaner)
        let cleaned = await clean(pipeline)
        #expect(cleaned.text == "Let's grab coffee at 2.")
        #expect(cleaned.deterministicText == det)
        let record = cleaned.cleanup
        #expect(record.cleanerID == "superwhisper-s1-mini" && record.cleanerRev == "rev1" && record.level == "light")
        #expect(record.outcome == "ok" && record.ms != nil && record.promptSha?.count == 12 && record.style == "formal")
        let llm = cleaned.edits.filter { $0.stage == "llm" }
        #expect(llm.count == 1 && llm.first?.fromText == det && llm.first?.toText == "Let's grab coffee at 2.")
        #expect(cleaned.edits.contains { $0.stage == "filler" })
    }

    @Test func theDictionaryAndStyleRunAgainOnTheModelsText() async {
        let rules = [DictionaryRule(heard: "mouth type", written: "Mouthtype")]
        let cleaner = ScriptedCleaner(returning: "The mouth type build is green today.\nShip it please now.")
        let (pipeline, _) = pipeline(cleaner, rules: rules, style: StylePreset.veryCasual.options)
        let cleaned = await clean(pipeline, text: "the mouthtype build is green today ship it please now")
        #expect(cleaned.text == "the Mouthtype build is green today.\nship it please now")
        #expect(cleaned.edits.last { $0.stage == "dictionary" } != nil)
    }

    @Test func aSlowModelDeliversTheDeterministicTextAndRecordsTimeout() async {
        let cleaner = ScriptedCleaner { _, _ in
            try await Task.sleep(for: .seconds(5))
            return "never"
        }
        let (pipeline, _) = pipeline(cleaner, budgetMs: 40)
        let cleaned = await clean(pipeline)
        #expect(cleaned.text == det && cleaned.cleanup.outcome == "timeout" && cleaned.cleanup.level == "light")
        #expect(cleaned.deterministicText == nil && !cleaned.edits.contains { $0.stage == "llm" })
    }

    @Test func aRejectedOutputDeliversTheDeterministicTextAndRecordsIt() async {
        let cleaner = ScriptedCleaner(returning: "Paris.")
        let (pipeline, _) = pipeline(cleaner)
        let cleaned = await clean(pipeline, text: "what's the capital of France")
        #expect(cleaned.text == "What's the capital of France" && cleaned.cleanup.outcome == "guard-rejected")
        #expect(!cleaned.edits.contains { $0.stage == "llm" })
    }

    @Test(arguments: [false, true])
    func publicDiagnosticsExcludeRejectedTextAndModelErrorDetails(modelFails: Bool) async {
        let privatePath = "/Users/example/Private-Person/model-fixture"
        let cleaner = ScriptedCleaner { _, _ in
            if modelFails { throw CleanupDiagnosticFixtureError(description: privatePath) }
            return "Send this to john@example.com."
        }
        var (pipeline, _) = pipeline(cleaner)
        let diagnostics = CleanupDiagnostics()
        pipeline.smartDiagnostic = { diagnostics.record($0) }
        let result = await clean(pipeline, text: "send this to jon@example.com",
                                 context: InsertionContext(before: "Customer: Fixture Person\n"))
        let outcome = modelFails ? "failed" : "guard-rejected"
        #expect(result.cleanup.outcome == outcome && result.text.contains("jon@example.com"))
        #expect(diagnostics.messages.count == 1)
        #expect(diagnostics.messages.contains { $0.contains(outcome) && $0.contains("ms=") })
        for content in ["jon@example.com", "john@example.com", "Fixture Person", privatePath] {
            #expect(diagnostics.messages.allSatisfy { !$0.contains(content) })
        }
    }

    @Test func shortInputReachesTheModel() async {
        let cleaner = ScriptedCleaner(returning: "See you soon.")
        let (pipeline, _) = pipeline(cleaner)
        let cleaned = await clean(pipeline, text: "see you soon")
        #expect(cleaned.text == "See you soon." && cleaned.cleanup.outcome == "ok" && cleaner.calls == 1)
        #expect(cleaned.cleanup.cleanerID == "superwhisper-s1-mini")
    }

    @Test(arguments: [CleanupLevel.basic, .off])
    func basicAndOffNeverCallTheModel(level: CleanupLevel) async {
        let cleaner = ScriptedCleaner(returning: "x")
        let (pipeline, _) = pipeline(cleaner, level: level)
        let cleaned = await clean(pipeline)
        #expect(cleaner.calls == 0 && cleaned.cleanup.cleanerID == "deterministic" && cleaned.cleanup.level == level.rawValue)
        #expect(cleaned.text == (level == .off ? raw : det))
    }

    @Test func aModelThatIsNotReadyRunsAsBasic() async {
        let cleaner = ScriptedCleaner(returning: "x")
        let (pipeline, _) = pipeline(cleaner, ready: false)
        let cleaned = await clean(pipeline)
        #expect(cleaner.calls == 0 && cleaned.text == det && cleaned.cleanup.level == "basic" && cleaned.cleanup.outcome == "ok")
    }

    @Test(arguments: [CleanupLevel.light, .medium], [false, true])
    func unavailableModelMatchesBasicWithJoinedSpellingsAndPhrases(level: CleanupLevel, overlappingPhrase: Bool) async {
        let cleaner = ScriptedCleaner(returning: "must not run")
        let rules = [DictionaryRule(heard: "mouth type", written: "Mouthtype")]
        let snippets = overlappingPhrase ? [Snippet(trigger: "mouth type", expansion: "{clipboard} {date}")] : []
        let (pipeline, _) = pipeline(cleaner, level: level, rules: rules, ready: false, snippets: snippets)
        var inputs = pipeline.cleanupInputs()
        inputs.now = Date(timeIntervalSince1970: 1_791_763_200)
        var basicInputs = inputs
        basicInputs.settings.level = .basic
        let transcribed = TranscribedDictation(text: "the mouth type build is green", rawText: "the mouth type build is green", asrDoneMs: 0, words: [])
        let basic = await pipeline.clean(transcribed, inputs: basicInputs, context: nil, clipboard: "unchanged {date}")
        let fallback = await pipeline.clean(transcribed, inputs: inputs, context: nil, clipboard: "unchanged {date}")
        #expect(fallback.text == basic.text)
        #expect(fallback.edits == basic.edits)
        #expect(fallback.cleanup.level == "basic" && fallback.cleanup.cleanerID == "deterministic")
        #expect(fallback.cleanup.outcome == "ok")
        #expect(cleaner.calls == 0)
        if overlappingPhrase {
            #expect(fallback.text.contains("unchanged {date}"))
            #expect(fallback.edits.contains { $0.stage == "snippet" })
        } else {
            #expect(fallback.text.contains("Mouthtype"))
            #expect(fallback.edits.contains { $0.stage == "dictionary" })
        }
    }

    @Test func mediumIsRecordedAsMedium() async {
        let cleaner = ScriptedCleaner(returning: "Let's grab coffee at 2.")
        let (pipeline, _) = pipeline(cleaner, level: .medium)
        let cleaned = await clean(pipeline)
        #expect(cleaned.cleanup.level == "medium" && cleaned.cleanup.outcome == "ok")
    }

    private func ruleInputs(_ pipeline: DictationPipeline, bundleID: String, level: CleanupLevel?) throws -> CleanupInputs {
        var styles = AppCleanupStyles()
        try styles.set(bundleID: bundleID, appName: "App", style: nil, level: level)
        let configured = styles
        var pipeline = pipeline
        pipeline.appStyles = { configured }
        return pipeline.cleanupInputs(level: pipeline.appStyles().resolveLevel(bundleID: bundleID))
    }

    @Test func aRuleSetToOffSkipsTheModelWhileTheGlobalLevelStaysOn() async throws {
        let cleaner = ScriptedCleaner(returning: "x")
        let (pipeline, _) = pipeline(cleaner, level: .light)
        let inputs = try ruleInputs(pipeline, bundleID: "com.apple.Terminal", level: .off)
        let transcribed = TranscribedDictation(text: raw, rawText: raw, asrDoneMs: 0, words: [])
        let cleaned = await pipeline.clean(transcribed, inputs: inputs, context: nil, clipboard: nil)
        #expect(cleaner.calls == 0 && cleaned.text == raw)
        #expect(cleaned.cleanup.level == "off" && cleaned.cleanup.outcome == "skipped")
        #expect(pipeline.cleanupInputs().settings.level == .light)
    }

    @Test func aRuleCanTurnTheModelOnWhileTheGlobalLevelIsOff() async throws {
        let cleaner = ScriptedCleaner(returning: "Let's grab coffee at 2.")
        let (pipeline, _) = pipeline(cleaner, level: .off)
        let inputs = try ruleInputs(pipeline, bundleID: "com.apple.Notes", level: .medium)
        let transcribed = TranscribedDictation(text: raw, rawText: raw, asrDoneMs: 0, words: [])
        let cleaned = await pipeline.clean(transcribed, inputs: inputs, context: nil, clipboard: nil)
        #expect(cleaner.calls == 1 && cleaned.cleanup.level == "medium" && cleaned.cleanup.outcome == "ok")
    }

    @Test func aRuleLevelWhoseModelIsMissingFallsBackToBasicLikeTheGlobalSetting() async throws {
        let cleaner = ScriptedCleaner(returning: "x")
        let (pipeline, _) = pipeline(cleaner, level: .basic, ready: false)
        let inputs = try ruleInputs(pipeline, bundleID: "com.apple.Notes", level: .light)
        let transcribed = TranscribedDictation(text: raw, rawText: raw, asrDoneMs: 0, words: [])
        let cleaned = await pipeline.clean(transcribed, inputs: inputs, context: nil, clipboard: nil)
        #expect(cleaner.calls == 0 && cleaned.text == det)
        #expect(cleaned.cleanup.level == "basic" && cleaned.cleanup.cleanerID == "deterministic" && cleaned.cleanup.outcome == "ok")
    }

    @Test func noRuleLevelKeepsTheGlobalLevel() throws {
        let (pipeline, _) = pipeline(ScriptedCleaner(returning: "x"), level: .medium)
        var styles = AppCleanupStyles()
        try styles.set(bundleID: "com.apple.Notes", appName: "Notes", style: StylePreset.casual.options)
        #expect(styles.resolveLevel(bundleID: "com.apple.Notes") == nil)
        #expect(pipeline.cleanupInputs(level: styles.resolveLevel(bundleID: "com.apple.Notes")).settings.level == .medium)
    }

    // MARK: Formal tone drops swearing

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var inputs: [String] = []
        func record(_ text: String) { lock.withLock { inputs.append(text) } }
        var all: [String] { lock.withLock { inputs } }
    }

    @Test(arguments: [CleanupLevel.basic, .light, .medium])
    func formalKeepsTheWordsOfASavedSpellingBeforeTheModel(level: CleanupLevel) async {
        let seen = Seen()
        let cleaner = ScriptedCleaner { text, _ in seen.record(text); return text }
        let rules = [DictionaryRule(heard: "brain fuck", written: "Brainfuck")]
        let (pipeline, _) = pipeline(cleaner, level: level, rules: rules)
        let cleaned = await clean(pipeline, text: "Deploy brain fuck.")
        #expect(cleaned.text.lowercased().replacingOccurrences(of: " ", with: "") == "deploybrainfuck.")
        #expect(cleaned.text.contains("Brainfuck") || cleaned.text.contains("brain fuck"))
        for input in seen.all { #expect(input.contains("brain fuck") || input.contains("Brainfuck")) }
    }

    @Test(arguments: [CleanupLevel.basic, .light, .medium])
    func formalKeepsASnippetTriggerAndStillDropsOtherSwearing(level: CleanupLevel) async {
        let cleaner = ScriptedCleaner { text, _ in text }
        let (pipeline, _) = pipeline(cleaner, level: level, snippets: [Snippet(trigger: "holy shit", expansion: "Oh dear")])
        let cleaned = await clean(pipeline, text: "holy shit this is fucking broken")
        #expect(cleaned.text == "Oh dear this is broken")
    }

    @Test(arguments: [CleanupLevel.basic, .light, .medium])
    func aTriggerTheCleanupWouldBreakStillExpandsAndSwearingStillGoes(level: CleanupLevel) async {
        let cleaner = ScriptedCleaner { text, _ in text }
        let (pipeline, _) = pipeline(cleaner, level: level, snippets: [Snippet(trigger: "um holy shit", expansion: "Oh dear")])
        let cleaned = await clean(pipeline, text: "um holy shit this is fucking broken")
        #expect(cleaned.text == "Oh dear this is broken")
    }

    @Test func aRejectedModelOutputStillLeavesNoSwearing() async {
        let (pipeline, _) = pipeline(ScriptedCleaner(returning: "Paris."))
        let cleaned = await clean(pipeline, text: "what's the capital of fucking France")
        #expect(cleaned.text == "What's the capital of France" && cleaned.cleanup.outcome == "guard-rejected")
    }

    @Test func aModelThatBringsSwearingBackLosesItAgain() async {
        let cleaner = ScriptedCleaner(returning: "What's the capital of fucking France?")
        let (pipeline, _) = pipeline(cleaner)
        let cleaned = await clean(pipeline, text: "what's the capital of France")
        #expect(cleaned.text == "What's the capital of France?" && cleaned.cleanup.outcome == "ok")
    }

    @Test func aModelReplacementForANounSurvives() async {
        let cleaner = ScriptedCleaner(returning: "Please do not be a jerk to Alice about the late delivery today.")
        let (pipeline, _) = pipeline(cleaner)
        let cleaned = await clean(pipeline, text: "please do not be an asshole to Alice about the late delivery today")
        #expect(cleaned.text == "Please do not be a jerk to Alice about the late delivery today.")
    }

    @Test(arguments: [CleanupLevel.basic, .light])
    func capitalisationRepairLeavesSavedSpellingsAndIdentifiersAlone(level: CleanupLevel) async {
        let rules = [DictionaryRule(heard: "npm", written: "npm")]
        let (pipeline, _) = pipeline(ScriptedCleaner { text, _ in text }, level: level, rules: rules)
        #expect(await clean(pipeline, text: "Fuck, npm is broken.").text == "npm is broken.")
        // The sentence-start blend stage treats a bare file name as it does without the swearing; the swear pass adds nothing.
        let plain = await clean(pipeline, text: "foo.py is missing.")
        let out = await clean(pipeline, text: "Fuck, foo.py is missing.")
        #expect(out.text == plain.text)
        #expect(!out.edits.contains { $0.stage == "filler" && $0.toText == "Foo" })
    }

    @Test(arguments: [CleanupLevel.basic, .light])
    func punctuationAroundARemovedExclamationGoesWithIt(level: CleanupLevel) async {
        let (pipeline, _) = pipeline(ScriptedCleaner { text, _ in text }, level: level)
        #expect(await clean(pipeline, text: "Shit... I forgot the keys today.").text == "I forgot the keys today.")
        #expect(await clean(pipeline, text: "Fuck!!").text == "")
        #expect(await clean(pipeline, text: "Fuck;").text == "")
    }

    @Test func theTimeoutTakeKeepsSavedSpellingsWhileDroppingSwearing() async {
        let rules = [DictionaryRule(heard: "en pee em", written: "npm")]
        var (pipeline, _) = pipeline(ScriptedCleaner { text, _ in text }, level: .basic, rules: rules)
        pipeline.cleanupBudget = -1
        let cleaned = await clean(pipeline, text: "um hello. Fuck, npm failed.")
        #expect(cleaned.cleanup.outcome == "timeout")
        #expect(cleaned.text == "um hello. npm failed.")
    }

    @Test func theBasicFallbackKeepsSavedSpellingsWhileDroppingSwearing() async {
        let rules = [DictionaryRule(heard: "en pee em", written: "npm"), DictionaryRule(heard: "mouth type", written: "Mouthtype")]
        let (pipeline, _) = pipeline(ScriptedCleaner { text, _ in text }, level: .light, rules: rules, ready: false)
        let cleaned = await clean(pipeline, text: "um hello. Fuck, npm failed.")
        #expect(cleaned.text.hasSuffix("npm failed."))
        #expect(!cleaned.text.contains("Npm") && !cleaned.text.lowercased().contains("fuck"))
    }
}
