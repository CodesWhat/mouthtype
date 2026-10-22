import Foundation

struct CleanupCase: Codable, Sendable, Equatable {
    var id: String
    var category: String
    var input: String
    var vocabulary: [String]
    var mustContain: [String]
    var mustNotContain: [String]
    var maxLengthRatio: Double?
    var minLengthRatio: Double?
    var appName: String?
    var reference: String
    /// ISO 639-1 code of the language the case is written in. Nil means English.
    var language: String?
}

enum LengthBucket: String, Codable, CaseIterable {
    case short, medium, long

    init(wordCount: Int) {
        switch wordCount {
        case ..<15: self = .short
        case 15...120: self = .medium
        default: self = .long
        }
    }

    var label: String {
        switch self {
        case .short: return "short (<15 words)"
        case .medium: return "medium (15-120 words)"
        case .long: return "long (>120 words)"
        }
    }
}

enum CleanupFixtures {
    static let promptCategory = "prompt-like content"

    static let requiredCategories = [
        "filler", "self-correction", "run-on and paragraphs", "lists", promptCategory, "technical",
        "names and numbers", "custom vocabulary", "already clean", "very short", "casual and profanity",
    ]

    static func load() throws -> [CleanupCase] {
        guard let url = Bundle.module.url(forResource: "cleanup-cases", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "cleanup-cases.json is missing from the bench bundle"])
        }
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> [CleanupCase] {
        try JSONDecoder().decode([CleanupCase].self, from: data)
    }
}

enum CleanupChecker {
    /// Reasons the output fails the case's deterministic checks. Empty means it passes.
    static func failures(for testCase: CleanupCase, output: String) -> [String] {
        var reasons: [String] = []
        let lowered = output.lowercased()
        for needle in testCase.mustContain where !lowered.contains(needle.lowercased()) {
            reasons.append("missing \(quoted(needle))")
        }
        for needle in testCase.mustNotContain where lowered.contains(needle.lowercased()) {
            reasons.append("contains \(quoted(needle))")
        }
        let inputLength = max(testCase.input.count, 1)
        let ratio = Double(output.count) / Double(inputLength)
        if let maximum = testCase.maxLengthRatio, ratio > maximum {
            reasons.append(String(format: "length ratio %.2f above max %.2f", ratio, maximum))
        }
        if let minimum = testCase.minLengthRatio, ratio < minimum {
            reasons.append(String(format: "length ratio %.2f below min %.2f", ratio, minimum))
        }
        return reasons
    }

    static func passes(_ testCase: CleanupCase, output: String) -> Bool {
        failures(for: testCase, output: output).isEmpty
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
