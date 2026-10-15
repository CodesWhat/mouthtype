import Foundation

enum PasteSettings {
    private static let key = "chunkedPasteApps"
    static let chordKey = "pasteChordsByApp"
    private static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "com.github.wez.wezterm",
    ]

    static func chord(for bundleID: String?, defaults: UserDefaults = .standard) -> PasteChord {
        guard let bundleID, let saved = defaults.dictionary(forKey: chordKey)?[bundleID] as? String,
              let chord = PasteChord(rawValue: saved) else { return .commandV }
        return chord
    }

    static func setChord(_ chord: PasteChord, bundleID: String, defaults: UserDefaults = .standard) {
        guard !bundleID.isEmpty else { return }
        var entries = defaults.dictionary(forKey: chordKey) ?? [:]
        if chord == .commandV { entries.removeValue(forKey: bundleID) }
        else { entries[bundleID] = chord.rawValue }
        defaults.set(entries, forKey: chordKey)
    }

    static func supportsChunking(_ bundleID: String?) -> Bool {
        bundleID.map { terminals.contains($0) } ?? false
    }

    static func chunksEnabled(_ bundleID: String?, defaults: UserDefaults = .standard) -> Bool {
        guard let bundleID, supportsChunking(bundleID) else { return false }
        return (defaults.stringArray(forKey: key) ?? []).contains(bundleID)
    }

    static func setChunks(_ enabled: Bool, bundleID: String, defaults: UserDefaults = .standard) {
        guard supportsChunking(bundleID) else { return }
        var apps = Set(defaults.stringArray(forKey: key) ?? [])
        if enabled { apps.insert(bundleID) } else { apps.remove(bundleID) }
        defaults.set(apps.sorted(), forKey: key)
    }
}
