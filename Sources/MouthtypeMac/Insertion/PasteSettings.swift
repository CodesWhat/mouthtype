import Foundation

enum PasteSettings {
    private static let key = "chunkedPasteApps"
    private static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "com.github.wez.wezterm",
    ]

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
