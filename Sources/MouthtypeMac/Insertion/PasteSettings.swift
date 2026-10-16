import Foundation

enum PasteSettings {
    private static let key = "chunkedPasteApps"
    struct Terminal: Sendable {
        let bundleID: String
        let name: String
    }
    static let supportedTerminals = [
        Terminal(bundleID: "com.apple.Terminal", name: "Terminal"),
        Terminal(bundleID: "com.googlecode.iterm2", name: "iTerm2"),
        Terminal(bundleID: "com.mitchellh.ghostty", name: "Ghostty"),
        Terminal(bundleID: "net.kovidgoyal.kitty", name: "kitty"),
        Terminal(bundleID: "com.github.wez.wezterm", name: "WezTerm"),
    ]
    private static let terminals = Set(supportedTerminals.map(\.bundleID))

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
