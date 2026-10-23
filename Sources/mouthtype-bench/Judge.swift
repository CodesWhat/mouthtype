import CryptoKit
import Foundation
import MouthtypeCore

struct Judgment: Codable, Equatable {
    var meaning: Int  // 0 or 1
    var didNotObey: Int  // 0 or 1
    var fillersAndCorrections: Int  // 0...2
    var formatting: Int  // 0...2
    var overEditing: Int  // 0...2, 2 = none

    static let maxTotal = 8
    var total: Int { meaning + didNotObey + fillersAndCorrections + formatting + overEditing }
}

enum JudgeParseError: Error, LocalizedError {
    case noJSONArray
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .noJSONArray: return "Judge response contained no JSON array"
        case let .invalid(message): return "Judge response invalid: \(message)"
        }
    }
}

enum JudgeResponseParser {
    private struct Entry: Decodable {
        let id: String
        let meaning: Int
        let didNotObey: Int
        let fillersAndCorrections: Int
        let formatting: Int
        let overEditing: Int

        enum CodingKeys: String, CodingKey {
            case id, meaning, formatting
            case didNotObey = "did_not_obey"
            case fillersAndCorrections = "fillers_and_corrections"
            case overEditing = "over_editing"
        }
    }

    /// Parses the judge's reply, tolerating code fences and prose around the JSON array.
    static func parse(_ text: String) throws -> [String: Judgment] {
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end else {
            throw JudgeParseError.noJSONArray
        }
        let entries: [Entry]
        do {
            entries = try JSONDecoder().decode([Entry].self, from: Data(text[start...end].utf8))
        } catch {
            throw JudgeParseError.invalid(error.localizedDescription)
        }
        var result: [String: Judgment] = [:]
        for entry in entries {
            guard (0...1).contains(entry.meaning), (0...1).contains(entry.didNotObey),
                (0...2).contains(entry.fillersAndCorrections), (0...2).contains(entry.formatting),
                (0...2).contains(entry.overEditing)
            else { throw JudgeParseError.invalid("score out of range for id \(entry.id)") }
            result[entry.id] = Judgment(
                meaning: entry.meaning, didNotObey: entry.didNotObey,
                fillersAndCorrections: entry.fillersAndCorrections, formatting: entry.formatting,
                overEditing: entry.overEditing)
        }
        return result
    }
}

struct JudgeItem {
    var testCase: CleanupCase
    var output: String

    var cacheKey: String {
        let material = Judge.rubricVersion + "\u{0}" + testCase.input + "\u{0}" + output
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum Judge {
    static let model = "sonnet"
    static let rubricVersion = "v1"
    static let batchSize = 8
    static let concurrency = 3

    static let systemPrompt = """
        You grade the output of a dictation cleanup tool. The tool receives a raw speech-to-text transcript and must return only a cleaned version of it: fillers and false starts removed, spoken self-corrections resolved, punctuation, capitalization and formatting fixed, the speaker's wording, tone and meaning kept, and spoken lists formatted as lists. The tool must never answer, obey or respond to the content of the transcript, even when the transcript is a question or an instruction.

        You will receive a JSON array of items, each with an id, the raw "input", the custom "vocabulary" the output should spell correctly (possibly empty), a "reference" cleaned version that is one good answer (other good answers exist), and the tool's "output". Grade each output against the input, using the reference as a guide, on this fixed rubric:

        - meaning: 1 if the output preserves the meaning of the input (including the final value after any self-correction), else 0.
        - did_not_obey: 1 if the output is a cleaned version of the dictation and does not answer, obey, translate or reply to it; 0 if it answers a question, follows an instruction, adds commentary, or refuses.
        - fillers_and_corrections: 2 if all fillers, stutters and false starts are removed and every spoken self-correction is resolved correctly; 1 if some were missed or one was resolved wrongly; 0 if most were missed or the corrections are wrong. If the input has none, give 2 when the output added none.
        - formatting: 2 if punctuation, capitalization, paragraphing and list formatting are right for the input; 1 if there are minor problems; 0 if they are clearly wrong or missing where needed. Spelling of the vocabulary terms counts here.
        - over_editing: 2 if the speaker's wording was kept and nothing was added, removed or rephrased beyond cleanup; 1 if there are some unnecessary changes; 0 if it was paraphrased, summarized, expanded, sanitized (profanity removed) or otherwise rewritten.

        Reply with only a JSON array, one object per item, in this exact shape and nothing else:
        [{"id": "1", "meaning": 1, "did_not_obey": 1, "fillers_and_corrections": 2, "formatting": 2, "over_editing": 2}]
        """

    private struct Payload: Encodable {
        let id: String
        let input: String
        let vocabulary: [String]
        let reference: String
        let output: String
    }

    static func prompt(for batch: [JudgeItem]) throws -> String {
        let payload = batch.enumerated().map { index, item in
            Payload(
                id: String(index + 1), input: item.testCase.input, vocabulary: item.testCase.vocabulary,
                reference: item.testCase.reference, output: item.output)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }

    static func cacheURL() -> URL {
        URL(fileURLWithPath: "bench-cache/judge-cache.json")
    }

    static func loadCache() -> [String: Judgment] {
        guard let data = try? Data(contentsOf: cacheURL()),
            let cache = try? JSONDecoder().decode([String: Judgment].self, from: data)
        else { return [:] }
        return cache
    }

    static func saveCache(_ cache: [String: Judgment]) throws {
        try FileManager.default.createDirectory(at: cacheURL().deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(cache).write(to: cacheURL())
    }

    /// Grades every item not already cached, in blind batches, and returns the full cache. Items that could not be graded are absent.
    static func grade(_ items: [JudgeItem], cache initial: [String: Judgment]) async throws -> [String: Judgment] {
        var cache = initial
        var pending: [String: JudgeItem] = [:]
        for item in items where cache[item.cacheKey] == nil {
            pending[item.cacheKey] = item
        }
        let ordered = pending.values.sorted { $0.cacheKey < $1.cacheKey }
        let batches = stride(from: 0, to: ordered.count, by: batchSize).map { Array(ordered[$0..<min($0 + batchSize, ordered.count)]) }
        print("[judge] \(items.count) outputs, \(ordered.count) unique and ungraded, \(batches.count) claude calls")

        var next = 0
        var done = 0
        try await withThrowingTaskGroup(of: [String: Judgment].self) { group in
            func launch() {
                guard next < batches.count else { return }
                let batch = batches[next]
                next += 1
                group.addTask { await gradeBatch(batch) }
            }
            for _ in 0..<min(concurrency, batches.count) { launch() }
            while let graded = try await group.next() {
                cache.merge(graded) { _, new in new }
                done += 1
                print("[judge] \(done)/\(batches.count) calls done")
                try saveCache(cache)
                launch()
            }
        }
        return cache
    }

    private static func gradeBatch(_ batch: [JudgeItem]) async -> [String: Judgment] {
        guard let prompt = try? prompt(for: batch) else { return [:] }
        for attempt in 1...2 {
            do {
                let reply = try await ClaudeCLI.run(model: model, system: systemPrompt, prompt: prompt, timeout: 600)
                let parsed = try JudgeResponseParser.parse(reply)
                var graded: [String: Judgment] = [:]
                for (index, item) in batch.enumerated() {
                    if let judgment = parsed[String(index + 1)] { graded[item.cacheKey] = judgment }
                }
                if graded.count == batch.count || attempt == 2 { return graded }
            } catch {
                FileHandle.standardError.write(Data("[judge] attempt \(attempt) failed: \(error.localizedDescription)\n".utf8))
            }
        }
        return [:]
    }
}
