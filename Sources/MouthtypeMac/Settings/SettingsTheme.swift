import AppKit
import SwiftUI

/// Colours and type for the Settings window. The lime accent replaces the system blue for tint, switches and selection.
enum SettingsTheme {
    /// Tint for switches, buttons, pickers and selection: the accent-mark green in light (#4A6A12, 3:1 or better on white), lime in dark.
    static let controlNS = DesignPalette.NS.accentMark
    static let control = Color(nsColor: controlNS)

    static let windowSize = NSSize(width: 900, height: 620)
    static let minimumSize = NSSize(width: 860, height: 600)
    static let sidebarWidth: CGFloat = 212
    static let headerHeight: CGFloat = 46
}

/// Every point size the Settings window uses. Nothing may go below `minimum`.
enum SettingsFont {
    static let minimum: CGFloat = 10
    static let sansName = FontRegistry.sansNames[0]
    static let serifName = FontRegistry.serifName
    static let monoName = FontRegistry.monoName

    static let wordmark: CGFloat = 28
    static let title: CGFloat = 22
    static let headerDescription: CGFloat = 12.5
    static let body: CGFloat = 13
    static let detail: CGFloat = 11.5
    static let eyebrow: CGFloat = 10
    static let footer: CGFloat = 10

    static let all: [CGFloat] = [wordmark, title, headerDescription, body, detail, eyebrow, footer]

    static func sans(_ size: CGFloat) -> Font { .custom(sansName, size: max(size, minimum)) }
    static func serif(_ size: CGFloat) -> Font { .custom(serifName, size: max(size, minimum)) }
    static func mono(_ size: CGFloat) -> Font { .custom(monoName, size: max(size, minimum)) }
}
