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
    func dictionary() -> [DictionaryRule] { rules }
    func snippets() -> [Snippet] { [] }
}

@MainActor
@Suite struct SmartCleanupPipelineTests {
    private let raw = "um let's do coffee at two actually three"
    private let det = "Let's do coffee at two actually three"

    private func pipeline(
        _ cleaner: ScriptedCleaner, level: CleanupLevel = .light, budgetMs: Int = 2000, rules: [DictionaryRule] = [],
        style: StyleOptions = .formal, ready: Bool = true
    ) -> (DictationPipeline, StubSmart) {
        let smart = StubSmart(SmartCleanup(cleaner: cleaner, budget: { _ in .milliseconds(budgetMs) }))
        if !ready { smart.info = nil }
        var pipeline = DictationPipeline(store: nil, archive: nil, engine: StubEngine(), clock: SystemDictationClock())
        var chosen = CleanupSettings()
        chosen.level = level
        chosen.style = style
        let settings = chosen
        pipeline.settings = { settings }
        pipeline.vocabulary = Rules(rules: rules)
        pipeline.smart = smart
        return (pipeline, smart)
    }

    private func clean(_ pipeline: DictationPipeline, text: String? = nil) async -> CleanedDictation {
        let transcribed = TranscribedDictation(text: text ?? raw, rawText: text ?? raw, asrDoneMs: 0, words: [])
        return await pipeline.clean(transcribed, inputs: pipeline.cleanupInputs(), context: nil, clipboard: nil)
    }

    @Test func theModelRunsOnTheDeterministicTextAndTheRecordSaysSo() async throws {
        let cleaner = ScriptedCleaner { text, _ in
            #expect(text == "Let's do coffee at two actually three")
            return "Let's do coffee at 3."
        }
        let (pipeline, _) = pipeline(cleaner)
        let cleaned = await clean(pipeline)
        #expect(cleaned.text == "Let's do coffee at 3.")
        #expect(cleaned.deterministicText == det)
        let record = cleaned.cleanup
        #expect(record.cleanerID == "superwhisper-s1-mini" && record.cleanerRev == "rev1" && record.level == "light")
        #expect(record.outcome == "ok" && record.ms != nil && record.promptSha?.count == 12 && record.style == "formal")
        let llm = cleaned.edits.filter { $0.stage == "llm" }
        #expect(llm.count == 1 && llm.first?.fromText == det && llm.first?.toText == "Let's do coffee at 3.")
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

    @Test func shortInputSkipsTheModel() async {
        let cleaner = ScriptedCleaner(returning: "x")
        let (pipeline, _) = pipeline(cleaner)
        let cleaned = await clean(pipeline, text: "see you soon")
        #expect(cleaned.text == "See you soon" && cleaned.cleanup.outcome == "skipped" && cleaner.calls == 0)
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

    @Test func mediumIsRecordedAsMedium() async {
        let cleaner = ScriptedCleaner(returning: "Let's do coffee at 3.")
        let (pipeline, _) = pipeline(cleaner, level: .medium)
        let cleaned = await clean(pipeline)
        #expect(cleaned.cleanup.level == "medium" && cleaned.cleanup.outcome == "ok")
    }
}
