import AppKit
import MouthtypeCore

/// The stats line and the last few dictations, newest first. Choosing one copies its text.
@MainActor
final class HistoryMenuSection: NSObject, MenuSection {
    static let recentCount = 5
    static let titleLimit = 50

    private let store: TranscriptStore?
    private let now: @MainActor () -> Date
    private let statsItem = NSMenuItem()
    private let unavailableItem = NSMenuItem(title: "History unavailable", action: nil, keyEquivalent: "")
    private var recentItems: [NSMenuItem] = []

    var items: [NSMenuItem] {
        guard store != nil else { return [unavailableItem] }
        return [statsItem] + recentItems
    }

    init(store: TranscriptStore?, now: @escaping @MainActor () -> Date = { Date() }) {
        self.store = store
        self.now = now
        super.init()
        statsItem.isEnabled = false
        unavailableItem.isEnabled = false
        refresh()
    }

    func refresh() {
        guard let store else { return }
        statsItem.title = Self.statsLine((try? store.stats(now: now())) ?? nil)
        // Rows with no text left (a secure discard) have nothing to copy.
        let records = ((try? store.recent(limit: Self.recentCount * 4)) ?? [])
            .filter { !($0.finalText ?? "").isEmpty }
            .prefix(Self.recentCount)
        recentItems = records.compactMap { record in
            guard let text = record.finalText else { return nil }
            let item = NSMenuItem(title: Self.shortened(text), action: #selector(copyRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = text
            item.toolTip = text
            return item
        }
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func statsLine(_ stats: StatsSummary?) -> String {
        guard let stats, stats.wordsToday > 0 || stats.recentWPM > 0 || stats.currentStreakDays > 0 else {
            return "No dictations yet"
        }
        var parts = ["\(stats.wordsToday) \(stats.wordsToday == 1 ? "word" : "words") today"]
        if stats.recentWPM >= 0.5 { parts.append("\(Int(stats.recentWPM.rounded())) WPM") }
        if stats.currentStreakDays > 0 {
            parts.append("\(stats.currentStreakDays) day streak")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// One line of at most `limit` characters: whitespace runs collapse, and a longer text keeps the words that fit,
    /// cut at a word boundary with no ellipsis (the full text is the item's tooltip). A first word longer than
    /// `limit` is cut at the limit, since it has no boundary to cut at.
    static func shortened(_ text: String, limit: Int = titleLimit) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }
        let head = flat.prefix(limit)
        let atBoundary = flat[head.endIndex].isWhitespace
        guard !atBoundary, let space = head.lastIndex(of: " ") else {
            return String(head).trimmingCharacters(in: .whitespaces)
        }
        return String(head[..<space])
    }
}
