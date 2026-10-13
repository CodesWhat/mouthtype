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

    var rules: [DictionaryRule] { (dictionary ?? []).map { DictionaryRule(heard: $0.heard, written: $0.written) } }

    /// Why the output fails the checks, or nil when it passes.
    func failure(for output: String) -> String? {
        let flat = output.replacingOccurrences(of: "\n", with: " ")
        if let exact, !exact.contains(where: { $0.lowercased() == flat.lowercased() }) {
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
}

enum SmartRunner {
    /// The app's order: the deterministic pipeline, then the model, then the dictionary and the style again.
    static func run(
        _ raw: String, rules: [DictionaryRule] = [], level: CleanupLevel, style: StyleOptions = .formal,
        smart: SmartCleanup
    ) async -> SmartRun {
        let det = TextPipeline().run(TextPipelineInput(
            text: raw, dictionary: rules, options: TextPipelineOptions(style: style)))
        let result = await smart.run(SmartCleanupRequest(text: det.text, level: level, style: style, dictionary: rules))
        return SmartRun(raw: raw, deterministic: det.text, result: result, edits: det.edits)
    }
}
