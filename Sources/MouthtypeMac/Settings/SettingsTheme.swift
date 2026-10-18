import AppKit
import SwiftUI

/// Brand colours and type for the Settings window. Brand green replaces the system blue for tint, toggles and selection.
enum SettingsTheme {
    static let lightControl = NSColor(srgbRed: 0x31 / 255, green: 0x5B / 255, blue: 0x54 / 255, alpha: 1)
    static let darkControl = NSColor(srgbRed: 0x4F / 255, green: 0x8F / 255, blue: 0x82 / 255, alpha: 1)
    static let darkSymbol = NSColor(srgbRed: 0x8F / 255, green: 0xC1 / 255, blue: 0xB5 / 255, alpha: 1)

    /// Tint for toggles, buttons, pickers and selection: #315B54 in light, #4F8F82 in dark.
    static let controlNS = NSColor(name: nil) { $0.isDark ? darkControl : lightControl }
    /// Tint for icons and glyphs: #315B54 in light, #8FC1B5 in dark.
    static let symbolNS = NSColor(name: nil) { $0.isDark ? darkSymbol : lightControl }
    static let control = Color(nsColor: controlNS)
    static let symbol = Color(nsColor: symbolNS)

    static let windowSize = NSSize(width: 900, height: 620)
    static let minimumSize = NSSize(width: 860, height: 600)
    static let sidebarWidth: CGFloat = 210
    static let headerHeight: CGFloat = 46
    static let rowMinHeight: CGFloat = 36
    static let rowLabelWidth: CGFloat = 220
}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
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

/// One row of a grouped form: title and optional detail on the left, controls on the right. Text wraps, never truncates.
/// The label column keeps at least `rowLabelWidth`; when the controls don't fit beside it they wrap below the label.
/// Callers keep buttons and popups at their intrinsic size with `.fixedSize()`; nothing is elided, the row grows or wraps instead.
struct SettingsRow<Controls: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var controls: () -> Controls

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(SettingsFont.sans(SettingsFont.body)).fixedSize(horizontal: false, vertical: true)
            if let detail, !detail.isEmpty {
                Text(detail).font(SettingsFont.sans(SettingsFont.detail)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var controlRow: some View { HStack(spacing: 8) { controls() } }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 14) {
                label.frame(minWidth: SettingsTheme.rowLabelWidth, idealWidth: SettingsTheme.rowLabelWidth, maxWidth: .infinity, alignment: .leading)
                controlRow.layoutPriority(1)
            }
            VStack(alignment: .leading, spacing: 6) {
                label.frame(maxWidth: .infinity, alignment: .leading)
                controlRow
            }
        }
        .frame(minHeight: SettingsTheme.rowMinHeight - 8)
    }
}

/// Plain secondary text row inside a group (notes, warnings), wrapping at any width.
struct SettingsNote: View {
    let text: String
    var tone: Color = .secondary

    var body: some View {
        Text(text).font(SettingsFont.sans(SettingsFont.detail)).foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An inset group: a JetBrains Mono eyebrow over a rounded card of rows split by inset hairlines. This is the Tahoe
/// `Form(.grouped)` look built directly, because the system form pads every row to about 54 pt and spaces groups out
/// until General no longer fits in 900×620 without scrolling.
struct SettingsGroup<Content: View>: View {
    let eyebrow: String
    var footer: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow).font(SettingsFont.mono(SettingsFont.eyebrow)).tracking(1).foregroundStyle(.secondary)
                .padding(.horizontal, 12).accessibilityAddTraits(.isHeader)
            Group(subviews: content()) { rows in
                VStack(spacing: 0) {
                    ForEach(rows.indices, id: \.self) { index in
                        if index > 0 { Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5).padding(.leading, 12) }
                        rows[index].padding(.horizontal, 12).padding(.vertical, 4)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            if let footer {
                Text(footer).font(SettingsFont.sans(SettingsFont.detail)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12)
            }
        }
    }
}

/// The scrolling page body: groups stacked 12 pt apart under the header bar.
struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) { content() }
                .padding(.horizontal, 24).padding(.top, 6).padding(.bottom, 16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
