import Foundation

/// The pages in the Mouthtype window's sidebar. Settings (the gear row) is not a page: it opens the modal, see `SettingsModalPage`.
enum SettingsPage: String, CaseIterable, Identifiable {
    case home, stats, dictionary, transforms, style, appearance
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .home: "house"
        case .stats: "chart.bar"
        case .dictionary: "book.closed"
        case .transforms: "wand.and.stars"
        case .style: "textformat"
        case .appearance: "capsule"
        }
    }
    /// The page `offset` rows away, stopping at the first and last pages.
    func moved(by offset: Int) -> SettingsPage {
        let pages = Self.allCases
        let index = pages.firstIndex(of: self) ?? 0
        return pages[min(max(index + offset, 0), pages.count - 1)]
    }
    /// Arrow keys step from the focused sidebar row when there is one, else from the selected page.
    static func arrowTarget(focused: SettingsPage?, selected: SettingsPage, offset: Int) -> SettingsPage {
        (focused ?? selected).moved(by: offset)
    }
    var headline: String {
        switch self {
        case .home: "Your recent takes."
        case .stats: "Your numbers."
        case .dictionary: "Names, spelled your way."
        case .transforms: "Say this, get that."
        case .style: "Your words. Your way."
        case .appearance: "Clean by default. Personal by choice."
        }
    }
    var summary: String {
        switch self {
        case .home: "Everything you dictated lately, newest first. Copy it or recover it."
        case .stats: "Words, speed, streaks and time saved, worked out on this Mac from your log."
        case .dictionary: "Keep names and terms spelled the way you want."
        case .transforms: "A short phrase you say, and the exact text Mouthtype types instead. Plus what it can do to text you\u{2019}ve selected."
        case .style: "A finish that feels right, without changing what you mean."
        case .appearance: "The same Mouthtype underneath. A different little machine when you want one."
        }
    }
}

/// The pages inside the Settings modal. Advanced only shows while the footer switch is on.
enum SettingsModalPage: String, CaseIterable, Identifiable {
    case general, mac, health, advanced
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// Line glyphs for now. The handoff leaves pixel versions of these four as a follow-up.
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .mac: "laptopcomputer"
        case .health: "heart.text.square"
        case .advanced: "slider.horizontal.3"
        }
    }
    var headline: String { title }
    var summary: String {
        switch self {
        case .general: "Set your shortcut, pick a microphone, and carry on."
        case .mac: "How Mouthtype starts and stays up to date."
        case .health: "Model progress, permissions and input. Repairs in one place."
        case .advanced: "The set-once options. Off the main path on purpose."
        }
    }
    /// The nav in order, with Advanced only when its switch is on.
    static func visible(advanced: Bool) -> [SettingsModalPage] { allCases.filter { $0 != .advanced || advanced } }
}

/// Somewhere a menu item or `mouthtype://open` can send the window.
enum SettingsDestination: Equatable {
    case page(SettingsPage)
    /// The Settings modal on one of its pages.
    case settings(SettingsModalPage)
    /// The Transcribe Audio File window. It is not a page, so the Mouthtype window stays where it is.
    case transcribeFile
}
