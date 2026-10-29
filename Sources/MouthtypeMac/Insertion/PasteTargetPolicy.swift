import Foundation

/// Whether the focused element is certainly not somewhere text can go. Pure, so it is tested.
///
/// Refuses only on a role that cannot hold text. Web areas, groups, windows, scroll areas, unknown roles and a missing
/// element all paste anyway: browsers and Electron apps report the container, not the field inside it.
enum PasteTargetPolicy {
    static func supportsReadBack(bundleID: String?) -> Bool {
        // Terminal exposes the screen, which can stay unchanged after a foreground program consumes input.
        bundleID != "com.apple.Terminal"
    }

    static func unchangedProvesFailure(bundleID: String?) -> Bool {
        // Orca can consume the paste while its Accessibility field stays unchanged.
        bundleID != "com.stablyai.orca" && bundleID != "com.apple.Terminal"
    }

    /// Terminals whose pasted text can't be read back: the field is empty or a screen grid a program redraws.
    /// An opted-in terminal gets its Return without a confirmation.
    static let unconfirmedSendBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.stablyai.orca", "com.googlecode.iterm2", "com.mitchellh.ghostty", "com.github.wez.wezterm",
        "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "org.alacritty", "co.zeit.hyper",
    ]

    /// False where a paste can never be confirmed, so a Return there can't wait for a verdict.
    static func confirmsPaste(bundleID: String?) -> Bool {
        guard let bundleID else { return true }
        return !unconfirmedSendBundleIDs.contains(bundleID)
    }

    static let notEditableRoles: Set<String> = [
        "AXButton", "AXMenuItem", "AXMenuBarItem", "AXMenuButton", "AXMenu", "AXMenuBar", "AXCheckBox", "AXRadioButton",
        "AXImage", "AXSlider", "AXPopUpButton",
    ]

    /// `textSettable` matters only for static text: whether its value or selection can be set, nil when unread.
    static func refuses(role: String?, textSettable: Bool?) -> Bool {
        guard let role else { return false }
        if role == "AXStaticText" { return textSettable == false }
        return notEditableRoles.contains(role)
    }
}
