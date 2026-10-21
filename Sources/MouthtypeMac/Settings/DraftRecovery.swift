import Foundation

/// An unsaved spelling or phrase draft, written to disk when a signal quits the app (a prompt can't be answered there)
/// and left there for the user to recover by hand.
struct DraftRecovery {
    struct Draft: Codable, Equatable {
        enum Kind: String, Codable { case spelling, phrase }
        var kind: Kind
        var heardForms: [String] = []
        var heardInput = ""
        var written = ""
        var starred = false
        var trigger = ""
        var expansion = ""
    }

    let directory: URL

    static var standard: DraftRecovery {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return DraftRecovery(directory: support.appendingPathComponent("Mouthtype/drafts", isDirectory: true))
    }

    /// `drafts/<kind>-<timestamp>.json`. The timestamp keeps an older, unrecovered draft from being overwritten.
    @discardableResult
    func save(_ draft: Draft, at date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = String(Int(date.timeIntervalSince1970 * 1000))
        let url = directory.appendingPathComponent("\(draft.kind.rawValue)-\(stamp).json")
        try JSONEncoder().encode(draft).write(to: url, options: .atomic)
        return url
    }
}

@MainActor
extension DraftRecovery {
    /// Writes whichever editors hold unsaved edits. Returns what was written.
    @discardableResult
    func saveDrafts(spellings: SpellingEditor?, phrases: PhraseEditor?) -> [URL] {
        let drafts = [spellings?.draftSnapshot(), phrases?.draftSnapshot()].compactMap { $0 }
        return drafts.compactMap { try? save($0) }
    }
}
