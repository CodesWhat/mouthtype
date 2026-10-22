import Foundation
import MouthtypeCore

/// An acceptance case for the model pass. `exact` and the two substring lists are the automatic checks; `target`
/// is the wording the owner asked for, for reading.
struct SmartCase: Codable, Sendable, Equatable {
    struct Rule: Codable, Sendable, Equatable {
        var heard: String
        var written: String
    }

    var id: String
    var input: String
    var target: String
    var dictionary: [Rule]?
    var exact: [String]?
    var mustContain: [String]?
    var mustNotContain: [String]?
    var before: String?
    var after: String?
    var appName: String?
    var caseSensitive: Bool?
    /// ISO 639-1 code of the language the case is written in. Nil means English.
    var language: String?

    var rules: [DictionaryRule] { (dictionary ?? []).map { DictionaryRule(heard: $0.heard, written: $0.written) } }

    /// Why the output fails the checks, or nil when it passes.
    func failure(for output: String) -> String? {
        let flat = output.replacingOccurrences(of: "\n", with: " ")
        if let exact, !exact.contains(where: { caseSensitive == true ? $0 == flat : $0.lowercased() == flat.lowercased() }) {
            return "not one of the accepted outputs"
        }
        if let missing = mustContain?.first(where: { !flat.lowercased().contains($0.lowercased()) }) {
            return "missing \"\(missing)\""
        }
        if let found = mustNotContain?.first(where: { flat.lowercased().contains($0.lowercased()) }) {
            return "contains \"\(found)\""
        }
        return nil
    }
}

enum SmartFixtures {
    static func load() throws -> [SmartCase] {
        guard let url = Bundle.module.url(forResource: "smart-cases", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "smart-cases.json is missing from the bench bundle"])
        }
        return try JSONDecoder().decode([SmartCase].self, from: Data(contentsOf: url))
    }
}

struct SmartRun: Sendable {
    var raw: String
    var deterministic: String
    var result: SmartCleanupResult
    var edits: [EditOp]
    var deterministicMilliseconds: Double
    var totalCleanupMilliseconds: Double
}

struct SmartDeliveryRecord: Codable {
    var id: String
    var cleanerID: String
    var level: String
    var input: String
    var deterministic: String
    var delivered: String
    var outcome: String
    var milliseconds: Int
    var deterministicMilliseconds: Double
    var totalCleanupMilliseconds: Double
    var rejection: String?
    var failure: String?
    var proposed: String?
}

actor ObservedCleaner: TextCleaner {
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let usesNativeControls: Bool
    private let base: any TextCleaner
    private let styling: S1MiniControls.Styling?
    private let structure: S1MiniControls.Structure?
    private var attempt = 0
    private(set) var proposed: String?

    init(_ base: any TextCleaner, styling: S1MiniControls.Styling? = nil, structure: S1MiniControls.Structure? = nil) {
        self.base = base
        self.styling = styling
        self.structure = structure
        id = base.id
        displayName = base.displayName
        usesNativeControls = base.usesNativeControls
    }

    func prepare() async throws { try await base.prepare() }
    func reset() { attempt += 1; proposed = nil }
    func clean(_ transcript: String, context: CleanupContext) async throws -> String {
        let generation = attempt
        var context = context
        if usesNativeControls {
            if let styling { context.s1Controls.styling = styling }
            if let structure { context.s1Controls.structure = structure }
        }
        let output = try await base.clean(transcript, context: context)
        if generation == attempt { proposed = output }
        return output
    }
}

enum SmartRunner {
    /// The app's order: the deterministic pipeline, then the model, then the dictionary and the style again.
    static func run(
        _ raw: String, rules: [DictionaryRule] = [], level: CleanupLevel, style: StyleOptions = .formal,
        smart: SmartCleanup, selfCorrection: Bool = true, context: InsertionContext? = nil, appName: String? = nil,
        language: DictationLanguage? = nil
    ) async -> SmartRun {
        let clock = ContinuousClock()
        let start = clock.now
        let det = TextPipeline().run(
            TextPipelineInput(
                text: raw, dictionary: rules.filter { !level.needsModel || !$0.isJoinedSpelling }, context: context, options: TextPipelineOptions(selfCorrection: selfCorrection, style: style),
                language: language))
        let deterministicTime = (clock.now - start).seconds * 1000
        let result = await smart.run(SmartCleanupRequest(text: det.text, level: level, style: style, dictionary: rules, context: context, appName: appName, language: language))
        return SmartRun(
            raw: raw, deterministic: det.text, result: result, edits: det.edits,
            deterministicMilliseconds: deterministicTime, totalCleanupMilliseconds: (clock.now - start).seconds * 1000)
    }
}
