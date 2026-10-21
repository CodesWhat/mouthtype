import Foundation

/// An unsaved spelling or phrase draft, written to disk when a signal quits the app (a prompt can't be answered there)
/// and offered back through the recovery card at the next launch.
struct DraftRecovery {
    struct Draft: Codable, Equatable {
        enum Kind: String, Codable { case spelling, phrase }
        /// Files from before the schema was versioned have no `version` and read as 0.
        static let currentVersion = 1
        var version = Draft.currentVersion
        var kind: Kind
        var heardForms: [String] = []
        var heardInput = ""
        var written = ""
        var starred = false
        var trigger = ""
        var expansion = ""

        init(
            kind: Kind, heardForms: [String] = [], heardInput: String = "", written: String = "", starred: Bool = false,
            trigger: String = "", expansion: String = ""
        ) {
            self.kind = kind
            self.heardForms = heardForms
            self.heardInput = heardInput
            self.written = written
            self.starred = starred
            self.trigger = trigger
            self.expansion = expansion
        }

        /// Every field but `kind` is optional on disk, so a file an older build wrote still reads.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
            kind = try c.decode(Kind.self, forKey: .kind)
            heardForms = try c.decodeIfPresent([String].self, forKey: .heardForms) ?? []
            heardInput = try c.decodeIfPresent(String.self, forKey: .heardInput) ?? ""
            written = try c.decodeIfPresent(String.self, forKey: .written) ?? ""
            starred = try c.decodeIfPresent(Bool.self, forKey: .starred) ?? false
            trigger = try c.decodeIfPresent(String.self, forKey: .trigger) ?? ""
            expansion = try c.decodeIfPresent(String.self, forKey: .expansion) ?? ""
        }

        var isEmpty: Bool {
            heardForms.allSatisfy { $0.isEmpty } && heardInput.isEmpty && written.isEmpty && trigger.isEmpty && expansion.isEmpty
        }

        /// The draft as plain text for the recovered card.
        var text: String {
            switch kind {
            case .phrase:
                return "Phrase \"\(trigger)\"\n\(expansion)"
            case .spelling:
                var lines = ["Spelling \"\(written)\""]
                let heard = (heardForms + [heardInput]).filter { !$0.isEmpty }
                if !heard.isEmpty { lines.append("Heard as: " + heard.joined(separator: ", ")) }
                return lines.joined(separator: "\n")
            }
        }
    }

    /// What one launch found in the drafts directory.
    struct Pending {
        /// Readable drafts, oldest first, with the file each came from.
        var drafts: [(draft: Draft, url: URL)] = []
        /// Files moved to `corrupt/` because they didn't decode.
        var setAside: [URL] = []
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

    /// The readable drafts. A file that doesn't decode is moved into `corrupt/` and logged; a file from a newer build is
    /// left alone; a blank draft has nothing to recover and is removed. Never throws.
    func pending() -> Pending {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var found = Pending()
        for url in files {
            guard let data = try? Data(contentsOf: url), let draft = try? JSONDecoder().decode(Draft.self, from: data) else {
                if let moved = setAside(url) { found.setAside.append(moved) }
                continue
            }
            if draft.version > Draft.currentVersion {
                Log.app.info("draft \(url.lastPathComponent, privacy: .public) is from a newer version, left in place")
                continue
            }
            if draft.isEmpty {
                remove(url)
                continue
            }
            found.drafts.append((draft, url))
        }
        return found
    }

    func remove(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) } catch {
            Log.app.error("couldn't remove draft \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func setAside(_ url: URL) -> URL? {
        let fm = FileManager.default
        let folder = directory.appendingPathComponent("corrupt", isDirectory: true)
        let target = folder.appendingPathComponent(url.lastPathComponent)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: url, to: target)
            Log.app.error("draft \(url.lastPathComponent, privacy: .public) is unreadable, moved to corrupt/")
            return target
        } catch {
            Log.app.error("draft \(url.lastPathComponent, privacy: .public) is unreadable and couldn't be moved: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// Offers the drafts a signal quit left behind through the same card CrashRecovery uses: Recover shows the text with
/// Copy, Discard drops it. The editors are never touched, which is what cut the first restore (it dirtied an editor
/// whose sheet was closed and deleted the file before anyone saw it). Files go only once the user answered the card.
@MainActor
final class DraftOffer {
    private let recovery: DraftRecovery
    private let cards: any DictationCards
    private var pending: [(draft: DraftRecovery.Draft, url: URL)] = []
    private var checked = false

    init(recovery: DraftRecovery, cards: any DictationCards) {
        self.recovery = recovery
        self.cards = cards
    }

    /// Looks once per launch. Returns how many drafts were offered.
    @discardableResult
    func offerIfNeeded() -> Int {
        guard !checked else { return 0 }
        checked = true
        let found = recovery.pending()
        pending = found.drafts
        guard !pending.isEmpty else { return 0 }
        let count = pending.count
        let noun = count == 1 ? "draft" : "drafts"
        var card = DeliveryCard.recoverOffer(seconds: 1, ago: 0, older: 0)
        card.header = "Recover an unsaved \(noun)?\n\(count) \(noun) from when Mouthtype was quit"
        cards.present(card, actions: [
            .recover: { [weak self] in self?.recover() },
            .discard: { [weak self] in self?.discard() },
        ])
        return count
    }

    private func recover() {
        let items = pending
        guard !items.isEmpty else { return }
        pending = []
        cards.present(
            DeliveryCard(
                kind: .recovered, header: "Recovered \(items.count == 1 ? "a draft" : "\(items.count) drafts")",
                transcript: items.map(\.draft.text).joined(separator: "\n\n"), actions: [.copy], countdown: nil
            ),
            actions: [:]
        )
        items.forEach { recovery.remove($0.url) }
    }

    private func discard() {
        let items = pending
        pending = []
        items.forEach { recovery.remove($0.url) }
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
