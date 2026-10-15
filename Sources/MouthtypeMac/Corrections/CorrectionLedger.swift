import Foundation
import MouthtypeCore

/// What Mouthtype remembers about spelling questions, kept in a small JSON file the user can delete: when each pair
/// was last offered, how often it was turned down, and which dictionary rules Mouthtype added itself (only those are
/// ever offered for removal). A pair is offered at most once an hour and never again after three declines.
@MainActor
final class CorrectionLedger {
    static let cooldown: TimeInterval = 60 * 60
    static let maxDeclines = 3
    static let fileName = "corrections.json"

    private struct PairState: Codable, Equatable {
        var declines = 0
        var lastOffered: Double = 0
    }

    private struct File: Codable {
        var pairs: [String: PairState] = [:]
        var learned: [DictionaryRule] = []
    }

    static func defaultURL() -> URL {
        TranscriptStore.defaultURL().deletingLastPathComponent().appendingPathComponent(fileName)
    }

    let url: URL
    private let now: @MainActor () -> Date
    private var file = File()

    init(url: URL = CorrectionLedger.defaultURL(), now: @escaping @MainActor () -> Date = { Date() }) {
        self.url = url
        self.now = now
        if let data = try? Data(contentsOf: url), let loaded = try? JSONDecoder().decode(File.self, from: data) {
            file = loaded
        }
    }

    private func key(_ kind: CorrectionKind, _ heard: String, _ corrected: String) -> String {
        "\(kind.rawValue)|\(heard.lowercased())|\(corrected.lowercased())"
    }

    func canOffer(_ kind: CorrectionKind, heard: String, corrected: String) -> Bool {
        guard let state = file.pairs[key(kind, heard, corrected)] else { return true }
        if state.declines >= Self.maxDeclines { return false }
        return now().timeIntervalSince1970 - state.lastOffered >= Self.cooldown
    }

    func recordOffer(_ kind: CorrectionKind, heard: String, corrected: String) {
        file.pairs[key(kind, heard, corrected), default: PairState()].lastOffered = now().timeIntervalSince1970
        save()
    }

    func recordDecline(_ kind: CorrectionKind, heard: String, corrected: String) {
        file.pairs[key(kind, heard, corrected), default: PairState()].declines += 1
        save()
    }

    /// The pair was saved, so it has no declines to hold against it and its rule counts as learned.
    func recordLearned(heard: String, written: String) {
        file.pairs[key(.remember, heard, written)] = nil
        file.learned.removeAll { $0.heard.lowercased() == heard.lowercased() }
        file.learned.append(DictionaryRule(heard: heard, written: written))
        save()
    }

    func recordForgotten(heard: String) {
        file.learned.removeAll { $0.heard.lowercased() == heard.lowercased() }
        save()
    }

    /// The rules Mouthtype added that the dictionary still has unchanged.
    func learned(in dictionary: [DictionaryRule]) -> [DictionaryRule] {
        file.learned.filter { rule in
            dictionary.contains { $0.heard.lowercased() == rule.heard.lowercased() && $0.written == rule.written }
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(file).write(to: url, options: .atomic)
        } catch {
            Log.corrections.error("ledger not saved: \(String(describing: error), privacy: .public)")
        }
    }
}
