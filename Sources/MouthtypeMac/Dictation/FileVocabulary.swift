import Foundation
import MouthtypeCore
import os

/// The user's dictionary, shared by saved-spelling editing and learned corrections:
/// `[{"heard": "mouth type", "written": "Mouthtype", "starred": false}]`.
///
/// Loaded when the object is made and again whenever the file's modification date or size changes, checked on every
/// read (one `stat`). A file that doesn't parse leaves the last good rules in place and sets `status` to an error.
final class FileVocabulary: VocabularyProviding, Sendable {
    enum Status: Equatable, Sendable {
        case missing
        case loaded(count: Int)
        case error(String)
    }

    private struct Entry: Decodable {
        var heard: String
        var written: String
        var starred: Bool?
    }

    private struct Snapshot {
        var rules: [DictionaryRule] = []
        var status = Status.missing
        var stamp: Stamp?
    }

    private struct Stamp: Equatable {
        var modified: Date
        var size: Int
    }

    static let fileName = "dictionary.json"

    static func defaultURL() -> URL {
        TranscriptStore.defaultURL().deletingLastPathComponent().appendingPathComponent(fileName)
    }

    /// Two entries to show the shape. The user edits or replaces them.
    static let exampleContents = """
    [
      { "heard": "mouth type", "written": "Mouthtype", "starred": false },
      { "heard": "super whisper", "written": "Superwhisper", "starred": false }
    ]

    """

    let url: URL
    private let snapshot = OSAllocatedUnfairLock(initialState: Snapshot())

    init(url: URL = FileVocabulary.defaultURL()) {
        self.url = url
        reloadIfChanged()
    }

    var status: Status { snapshot.withLock { $0.status } }

    func dictionary() -> [DictionaryRule] {
        reloadIfChanged()
        return snapshot.withLock { $0.rules }
    }

    func snippets() -> [Snippet] { [] }

    /// Reads the file again if it changed since the last read.
    func reloadIfChanged() {
        let stamp = Self.stamp(of: url)
        snapshot.withLock { current in
            guard stamp != current.stamp || (stamp == nil && current.status != .missing) else { return }
            current.stamp = stamp
            guard stamp != nil else {
                current.rules = []
                current.status = .missing
                return
            }
            do {
                let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))
                current.rules = entries.map { DictionaryRule(heard: $0.heard, written: $0.written, starred: $0.starred ?? false) }
                current.status = .loaded(count: current.rules.count)
            } catch {
                current.status = .error(Self.describe(error))
            }
        }
    }

    /// Writes the example file when there is none. Returns the url to open.
    @discardableResult
    func createIfMissing() throws -> URL {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.exampleContents.write(to: url, atomically: true, encoding: .utf8)
        }
        reloadIfChanged()
        return url
    }

    enum WriteError: LocalizedError, Equatable {
        /// The file doesn't parse as a list of entries, so it is left exactly as it is.
        case malformed(String)
        case failed(String)
        case invalid(String)
        case changed

        var errorDescription: String? {
            switch self {
            case let .malformed(message): "The spelling library could not be read: \(message). Fix dictionary.json and reload it."
            case let .failed(message), let .invalid(message): message
            case .changed: "This spelling changed outside the editor. Reload the library before saving or deleting it."
            }
        }
    }

    enum SaveResult: Equatable {
        case added, updated, unchanged
    }

    /// Adds `heard` to `written`, or sets `written` on the rule that already has that `heard` (ignoring case). A new
    /// entry is appended to the file's text so the rest of it stays as the user wrote it; an update rewrites the list
    /// in the file's usual one-line-per-entry shape, keeping order and any extra keys. Creates the file when missing.
    @discardableResult
    func save(heard: String, written: String) throws -> SaveResult {
        guard !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WriteError.invalid("Enter both the heard phrase and the spelling to use.")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            try write("[\n  \(Self.line(heard: heard, written: written, starred: false, extra: [:]))\n]\n")
            return .added
        }
        let (text, entries) = try readEntries()
        if let index = entries.firstIndex(where: { Self.string($0["heard"])?.lowercased() == heard.lowercased() }) {
            guard Self.string(entries[index]["written"]) != written else { return .unchanged }
            var changed = entries
            changed[index]["written"] = written
            try write(Self.render(changed))
            return .updated
        }
        try write(Self.appending(Self.line(heard: heard, written: written, starred: false, extra: [:]), to: text))
        return .added
    }

    /// Takes out the rule with this `heard` (ignoring case). False when there isn't one.
    @discardableResult
    func remove(heard: String) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let (_, entries) = try readEntries()
        let kept = entries.filter { Self.string($0["heard"])?.lowercased() != heard.lowercased() }
        guard kept.count != entries.count else { return false }
        try write(Self.render(kept))
        return true
    }

    static func heardKey(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    static func validationMessage(heard: String, written: String) -> String? {
        if heardKey(heard).isEmpty { return "Enter the word or phrase Mouthtype gets wrong." }
        if written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter the spelling to use." }
        let normalizedHeard = heard.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let normalizedWritten = written.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedHeard.count > 128 || normalizedWritten.count > 128 { return "Keep each phrase and spelling under 129 characters." }
        return nil
    }

    func allRules() throws -> [DictionaryRule] {
        try managedEntries().map(Self.rule)
    }

    func save(original: DictionaryRule?, rule: DictionaryRule) throws {
        let rule = DictionaryRule(heard: rule.heard.split(whereSeparator: \.isWhitespace).joined(separator: " "),
            written: rule.written.trimmingCharacters(in: .whitespacesAndNewlines), starred: rule.starred)
        if let message = Self.validationMessage(heard: rule.heard, written: rule.written) { throw WriteError.invalid(message) }
        var entries = try managedEntries()
        let index: Int?
        if let original {
            guard let found = entries.firstIndex(where: { Self.rule($0) == original }) else { throw WriteError.changed }
            index = found
        } else { index = nil }
        guard !entries.indices.contains(where: { $0 != index && Self.heardKey(Self.rule(entries[$0]).heard) == Self.heardKey(rule.heard) }) else {
            throw WriteError.invalid("A spelling for this heard phrase already exists.")
        }
        if let index {
            entries[index]["heard"] = rule.heard
            entries[index]["written"] = rule.written
            entries[index]["starred"] = rule.starred
        } else {
            entries.append(["heard": rule.heard, "written": rule.written, "starred": rule.starred])
        }
        try write(Self.render(entries))
    }

    func remove(_ rule: DictionaryRule) throws {
        var entries = try managedEntries()
        guard let index = entries.firstIndex(where: { Self.rule($0) == rule }) else { throw WriteError.changed }
        entries.remove(at: index)
        try write(Self.render(entries))
    }

    private func managedEntries() throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let (text, entries) = try readEntries()
        do { _ = try JSONDecoder().decode([Entry].self, from: Data(text.utf8)) }
        catch { throw WriteError.malformed(Self.describe(error)) }
        var seen = Set<String>()
        for entry in entries {
            let rule = Self.rule(entry)
            guard !Self.heardKey(rule.heard).isEmpty, !rule.written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WriteError.malformed("a spelling has a blank heard or written field")
            }
            guard seen.insert(Self.heardKey(rule.heard)).inserted else {
                throw WriteError.malformed("more than one spelling has the same heard phrase")
            }
        }
        return entries
    }

    private static func rule(_ entry: [String: Any]) -> DictionaryRule {
        DictionaryRule(heard: string(entry["heard"]) ?? "", written: string(entry["written"]) ?? "", starred: entry["starred"] as? Bool ?? false)
    }

    private func readEntries() throws -> (text: String, entries: [[String: Any]]) {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw WriteError.failed(error.localizedDescription) }
        let entries: [[String: Any]]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw WriteError.malformed("expected a list of {heard, written} entries")
            }
            entries = parsed
        } catch let error as WriteError {
            throw error
        } catch {
            throw WriteError.malformed("not valid JSON")
        }
        for entry in entries where Self.string(entry["heard"]) == nil || Self.string(entry["written"]) == nil {
            throw WriteError.malformed("expected a list of {heard, written} entries")
        }
        return (String(decoding: data, as: UTF8.self), entries)
    }

    private func write(_ text: String) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            throw WriteError.failed(error.localizedDescription)
        }
        snapshot.withLock { $0.stamp = nil }
        reloadIfChanged()
    }

    private static func string(_ value: Any?) -> String? { value as? String }

    private static func quoted(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return (try? encoder.encode(text)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    private static func line(heard: String, written: String, starred: Bool, extra: [String: Any]) -> String {
        var parts = ["\"heard\": \(quoted(heard))", "\"written\": \(quoted(written))", "\"starred\": \(starred)"]
        for key in extra.keys.sorted() {
            guard let data = try? JSONSerialization.data(withJSONObject: [extra[key] as Any], options: .withoutEscapingSlashes),
                  var value = String(data: data, encoding: .utf8) else { continue }
            value.removeFirst()
            value.removeLast()
            parts.append("\(quoted(key)): \(value)")
        }
        return "{ " + parts.joined(separator: ", ") + " }"
    }

    private static func render(_ entries: [[String: Any]]) -> String {
        guard !entries.isEmpty else { return "[]\n" }
        let lines = entries.map { entry -> String in
            var extra = entry
            for key in ["heard", "written", "starred"] { extra[key] = nil }
            return "  " + line(
                heard: string(entry["heard"]) ?? "", written: string(entry["written"]) ?? "",
                starred: (entry["starred"] as? Bool) ?? false, extra: extra
            )
        }
        return "[\n" + lines.joined(separator: ",\n") + "\n]\n"
    }

    /// `line` added before the closing bracket of `text`, leaving everything else as it was.
    private static func appending(_ line: String, to text: String) -> String {
        guard let close = text.lastIndex(of: "]") else { return render([]) }
        var head = String(text[..<close])
        while let last = head.last, last.isWhitespace { head.removeLast() }
        let tail = text[close...]
        let separator = head.hasSuffix("[") ? "\n  " : ",\n  "
        return head + separator + line + "\n" + tail
    }

    private static func stamp(of url: URL) -> Stamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return Stamp(modified: modified, size: (attributes[.size] as? Int) ?? 0)
    }

    private static func describe(_ error: Error) -> String {
        if let decoding = error as? DecodingError {
            switch decoding {
            case let .dataCorrupted(context): return context.debugDescription
            case let .keyNotFound(key, _): return "missing \"\(key.stringValue)\""
            case .typeMismatch, .valueNotFound: return "expected a list of {heard, written} entries"
            @unknown default: break
            }
        }
        return error.localizedDescription
    }
}
