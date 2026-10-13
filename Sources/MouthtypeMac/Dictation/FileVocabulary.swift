import Foundation
import MouthtypeCore
import os

/// The user's dictionary, read from a JSON file until the dictionary UI exists:
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
