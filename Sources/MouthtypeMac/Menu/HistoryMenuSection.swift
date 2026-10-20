import AppKit
import MouthtypeCore

/// The stats line and the last few takes, newest first. Choosing one copies its text.
@MainActor
final class HistoryMenuSection: NSObject, MenuSection {
    static let recentCount = 5
    static let titleLimit = 50

    private let store: TranscriptStore?
    private let now: @MainActor () -> Date
    private let statsItem = NSMenuItem()
    private let parent = NSMenuItem(title: "Recent Takes", action: nil, keyEquivalent: "")
    private let onError: @MainActor (String?) -> Void
    private let copy: @MainActor (String) -> Void
    private var recentItems: [NSMenuItem] = []

    var items: [NSMenuItem] { recentItems.isEmpty ? [] : [parent] }

    init(store: TranscriptStore?, now: @escaping @MainActor () -> Date = { Date() },
         onError: @escaping @MainActor (String?) -> Void = { _ in },
         copy: @escaping @MainActor (String) -> Void = { SystemClipboard().write($0) }) {
        self.store = store
        self.now = now
        self.onError = onError
        self.copy = copy
        super.init()
        statsItem.isEnabled = false
        refresh()
    }

    func refresh() {
        guard let store else { onError("Recent takes are unavailable."); return }
        do {
            statsItem.title = Self.statsLine(try store.stats(now: now()))
            let records = try store.recent(limit: Self.recentCount * 4)
                .filter { $0.isSecure != true && !($0.finalText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .prefix(Self.recentCount)
            recentItems = records.compactMap { record in
                guard let text = record.finalText else { return nil }
                let item = NSMenuItem(title: Self.shortened(text), action: #selector(copyRecent(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = text
                item.toolTip = text
                return item
            }
            onError(nil)
        } catch { recentItems = []; onError(error.localizedDescription) }
        parent.submenu?.removeAllItems()
        let submenu = NSMenu(title: "Recent Takes")
        submenu.addItem(statsItem)
        recentItems.forEach(submenu.addItem)
        parent.submenu = submenu
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        copy(text)
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
