import Foundation
import MouthtypeCore

/// Where an import file came from. Each source turns its file into the same candidate rows, so the preview, the
/// duplicate and conflict checks and the confirm step are shared and nothing is ever overwritten.
enum SpellingImportSource: Equatable, Sendable {
    case mouthtype, wispr, voiceInk

    var sheetEyebrow: String {
        switch self {
        case .mouthtype: "Import CSV"
        case .wispr: "Import from Wispr Flow"
        case .voiceInk: "Import from VoiceInk"
        }
    }

    var summaryLine: String {
        switch self {
        case .mouthtype: "A heard,written pair per row, or a single name column. Include a header row. Existing spellings stay as they are."
        case .wispr: "A Wispr Flow dictionary CSV: one word per row, or misspelling,correction. No header row. Existing spellings stay as they are."
        case .voiceInk: "A VoiceInk dictionary export. Vocabulary becomes names and each replacement source becomes a heard form. Existing spellings stay as they are."
        }
    }

    var emptyProblem: String {
        switch self {
        case .mouthtype: "The CSV has no spellings to import."
        case .wispr, .voiceInk: "The file has no spellings to import."
        }
    }

    var choosePrompt: String {
        switch self {
        case .mouthtype: "Choose a UTF-8 CSV to preview. Nothing is imported until you confirm."
        case .wispr: "Choose a Wispr Flow dictionary CSV to preview. Nothing is imported until you confirm."
        case .voiceInk: "Choose a VoiceInk dictionary JSON to preview. Nothing is imported until you confirm."
        }
    }

    /// One row of an import file after its source's own parsing, before the shared checks.
    enum Candidate {
        case pair(line: Int, heard: String, written: String)
        case bad(line: Int, heard: String, message: String)
    }

    func candidates(from data: Data) throws -> [Candidate] {
        switch self {
        case .mouthtype: try Self.mouthtypeCandidates(data)
        case .wispr: try Self.wisprCandidates(data)
        case .voiceInk: try Self.voiceInkCandidates(data)
        }
    }

    private static func mouthtypeCandidates(_ data: Data) throws -> [Candidate] {
        let records = try SpellingCSV.records(from: data)
        let header = records.first?.fields.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? []
        let namesOnly = header == ["name"]
        guard namesOnly || (header.count == 2 && Set(header) == ["heard", "written"]) else {
            throw SpellingCSV.Invalid(message: "Use a name column, or heard,written columns with a header row.")
        }
        let heardColumn = namesOnly ? 0 : header.firstIndex(of: "heard")!
        let writtenColumn = namesOnly ? 0 : header.firstIndex(of: "written")!
        return records.dropFirst().map { record in
            guard record.fields.count == header.count else {
                return .bad(line: record.line, heard: record.fields.first ?? "", message: "Expected \(header.count) column\(header.count == 1 ? "" : "s").")
            }
            return .pair(line: record.line, heard: record.fields[heardColumn], written: record.fields[writtenColumn])
        }
    }

    /// Wispr Flow's dictionary CSV has no header: one column is a vocabulary word, two are misspelling then correction.
    /// Empty fields are dropped, as Wispr does, so `word,` is one word.
    private static func wisprCandidates(_ data: Data) throws -> [Candidate] {
        try SpellingCSV.records(from: data).compactMap { record in
            let fields = record.fields.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            switch fields.count {
            case 0: return nil
            case 1: return .pair(line: record.line, heard: fields[0], written: fields[0])
            case 2: return .pair(line: record.line, heard: fields[0], written: fields[1])
            default: return .bad(line: record.line, heard: fields[0], message: "Expected one or two columns.")
            }
        }
    }

    private struct VoiceInkArchive: Decodable {
        struct Term: Decodable { let term: String }
        struct Replacement: Decodable {
            let sources: [String]
            let replacement: String
        }
        let format: String?
        let vocabulary: [Term]?
        let replacements: [Replacement]?
    }

    /// VoiceInk's own export (`format` "voiceink.dictionary"): `vocabulary[].term` and `replacements[].sources` to `replacement`.
    private static func voiceInkCandidates(_ data: Data) throws -> [Candidate] {
        guard data.count <= SpellingCSV.maximumBytes else { throw SpellingCSV.Invalid(message: "Choose a file of 1 MiB or smaller.") }
        guard let archive = try? JSONDecoder().decode(VoiceInkArchive.self, from: data), archive.format == "voiceink.dictionary" else {
            throw SpellingCSV.Invalid(message: "This file isn't a VoiceInk dictionary export.")
        }
        var candidates: [Candidate] = []
        for entry in archive.vocabulary ?? [] {
            candidates.append(.pair(line: candidates.count + 1, heard: entry.term, written: entry.term))
        }
        for entry in archive.replacements ?? [] {
            for source in entry.sources {
                candidates.append(.pair(line: candidates.count + 1, heard: source, written: entry.replacement))
            }
        }
        guard candidates.count <= SpellingCSV.maximumRows else { throw SpellingCSV.Invalid(message: "Import up to 5,000 spellings at a time.") }
        return candidates
    }
}

extension SpellingCSV {
    /// Writes a CSV the importer reads back unchanged: a quoted field when it holds a comma, quote, line break or edge whitespace.
    static func encode(header: [String], rows: [[String]]) -> String {
        func field(_ value: String) -> String {
            let edge = value.first?.isWhitespace == true || value.last?.isWhitespace == true
            guard value.isEmpty || edge || value.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return value }
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return ([header] + rows).map { $0.map(field).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    /// The Dictionary as `heard,written`, the same headers Import CSV reads. Starred state is not part of the CSV.
    static func export(_ rules: [DictionaryRule]) -> String {
        encode(header: ["heard", "written"], rows: rules.map { [$0.heard, $0.written] })
    }

    /// Phrases as `trigger,expansion`.
    static func export(_ snippets: [Snippet]) -> String {
        encode(header: ["trigger", "expansion"], rows: snippets.map { [$0.trigger, $0.expansion] })
    }
}
