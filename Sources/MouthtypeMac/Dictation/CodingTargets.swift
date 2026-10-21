import Foundation

/// Where spoken slash commands become typed ones: terminals, code editors, agent apps, and the agent sites
/// that run in a browser. Anything else gets the text as spoken.
enum CodingTargets {
    static let bundleIDs: Set<String> = [
        // Terminals
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "com.github.wez.wezterm", "org.alacritty",
        // Editors
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
        "com.apple.dt.Xcode", "com.exafunction.windsurf",
        // Agent apps
        "com.anthropic.claudefordesktop", "com.openai.chat", "com.openai.codex", "com.stablyai.orca",
    ]

    /// Every JetBrains IDE shares this prefix.
    static let bundleIDPrefixes = ["com.jetbrains."]

    static let websiteHosts: Set<String> = ["claude.ai", "chatgpt.com"]

    static func isCodingApp(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleIDs.contains(bundleID) || bundleIDPrefixes.contains { bundleID.hasPrefix($0) }
    }

    static func isCodingWebsite(host: String?, bundleID: String?) -> Bool {
        guard let host = host.flatMap(AppCleanupStyles.normalizedDomain), WebsiteContext.supports(bundleID: bundleID) else { return false }
        return websiteHosts.contains(host) || websiteHosts.contains { host.hasSuffix("." + $0) }
    }

    static func isCodingTarget(bundleID: String?, websiteHost: String? = nil) -> Bool {
        isCodingApp(bundleID: bundleID) || isCodingWebsite(host: websiteHost, bundleID: bundleID)
    }
}
