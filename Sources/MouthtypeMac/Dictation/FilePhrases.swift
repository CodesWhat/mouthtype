import Foundation
import MouthtypeCore
import os

final class FilePhrases: Sendable {
    enum Failure: LocalizedError {
        case invalid(String)
        case changed

        var errorDescription: String? {
            switch self {
            case .invalid(let message): message
            case .changed: "This phrase changed outside the editor. Reload the library before saving or deleting it."
            }
        }
    }

    let url: URL
    private let lastGood = OSAllocatedUnfairLock(initialState: [Snippet]())

    init(url: URL = FilePhrases.defaultURL()) { self.url = url }

    static func defaultURL() -> URL {
        TranscriptStore.defaultURL().deletingLastPathComponent().appendingPathComponent("phrases.json")
    }

    func all() throws -> [Snippet] {
        try lastGood.withLock { current in
            let entries = try read()
            current = entries
            return entries
        }
    }

    func snippets() -> [Snippet] {
        do { return try all() }
        catch { return lastGood.withLock { $0 } }
    }

    func save(original: Snippet?, phrase: Snippet) throws {
        try lastGood.withLock { current in
            var entries = try read()
            let phrase = try Self.validate([phrase])[0]
            if let original {
                guard let index = entries.firstIndex(of: original) else { throw Failure.changed }
                entries[index] = phrase
            } else {
                entries.append(phrase)
            }
            entries = try Self.validate(entries)
            try write(entries)
            current = entries
        }
    }

    func remove(_ phrase: Snippet) throws {
        try lastGood.withLock { current in
            var entries = try read()
            guard let index = entries.firstIndex(of: phrase) else { throw Failure.changed }
            entries.remove(at: index)
            try write(entries)
            current = entries
        }
    }

    static func triggerKey(_ text: String) -> String {
        PhraseKey.normalized(text)
    }

    private static func validate(_ entries: [Snippet]) throws -> [Snippet] {
        var seen = Set<String>()
        return try entries.map { entry in
            let trigger = entry.trigger.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !trigger.isEmpty else { throw Failure.invalid("Enter a phrase to say.") }
            guard !entry.expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure.invalid("Enter the text to insert.")
            }
            guard trigger.count <= 128 else { throw Failure.invalid("Keep the spoken phrase under 129 characters.") }
            guard entry.expansion.count <= 16_000 else { throw Failure.invalid("Keep the replacement under 16,001 characters.") }
            guard seen.insert(triggerKey(trigger)).inserted else {
                throw Failure.invalid("A phrase with this trigger already exists.")
            }
            return Snippet(trigger: trigger, expansion: entry.expansion)
        }
    }

    private func read() throws -> [Snippet] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard data.count <= 1_048_576 else { throw Failure.invalid("The phrase library is larger than 1 MB.") }
        let entries: [Snippet]
        do { entries = try JSONDecoder().decode([Snippet].self, from: data) }
        catch { throw Failure.invalid("The phrase library could not be read. Fix phrases.json and reload it.") }
        return try Self.validate(entries)
    }

    private func write(_ entries: [Snippet]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(entries)
        data.append(0x0A)
        guard data.count <= 1_048_576 else { throw Failure.invalid("The phrase library is larger than 1 MB.") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
