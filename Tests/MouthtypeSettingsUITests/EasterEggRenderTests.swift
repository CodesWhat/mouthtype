import AppKit
import SwiftUI
import Testing
import MouthtypeCore
@testable import MouthtypeMac

/// Offscreen renders of the menu bar mouth tricks and the About credits, light and dark. Set `MOUTHTYPE_SETTINGS_PREVIEWS` to a
/// directory to keep the PNGs.
@MainActor @Suite(.serialized) struct EasterEggRenderTests {
    /// One strip of the menu bar glyphs at a size the eye can check: the true idle glyph, then every step of each trick.
    private func trickSheet() -> some View {
        let rows: [(String, [String])] = [
            ("idle", ["idle"]),
            ("tongue", MouthTrick.tongue.steps.map(\.file)),
            ("whistle", MouthTrick.whistle.steps.map(\.file)),
            ("reduce motion", MouthTrick.allCases.map(\.staticFrame.file)),
        ]
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(rows, id: \.0) { title, files in
                HStack(spacing: 10) {
                    Text(title).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 100, alignment: .trailing)
                    ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                        ZStack {
                            RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08))
                            if let image = StatusIcon.loadImage(named: file) {
                                Image(nsImage: image).renderingMode(.template).interpolation(.none)
                                    .resizable().frame(width: 16 * 4, height: 15 * 4).foregroundStyle(.primary)
                            }
                        }
                        .frame(width: 16 * 4 + 12, height: 15 * 4 + 12)
                    }
                }
            }
        }
        .padding(20)
    }

    private struct CreditsText: NSViewRepresentable {
        func makeNSView(context: Context) -> NSTextView {
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
            view.isEditable = false
            view.drawsBackground = false
            view.textStorage?.setAttributedString(AboutCredits.attributed())
            return view
        }
        func updateNSView(_ nsView: NSTextView, context: Context) {}
    }

    @Test func trickFramesRender() throws {
        for dark in [false, true] {
            let bitmap = try SettingsRender.render(
                ZStack {
                    DesignPalette.bg; trickSheet()
                }, dark: dark, size: NSSize(width: 1000, height: 340))
            #expect(bitmap.pixelsWide >= 1000)
            try SettingsRender.save(bitmap, name: "mouth-tricks-\(dark ? "dark" : "light")")
        }
    }

    @Test func creditsRender() throws {
        for dark in [false, true] {
            let bitmap = try SettingsRender.render(
                ZStack {
                    DesignPalette.bg; CreditsText().frame(width: 420, height: 300)
                }, dark: dark,
                size: NSSize(width: 460, height: 340))
            #expect(bitmap.pixelsWide >= 460)
            try SettingsRender.save(bitmap, name: "about-credits-\(dark ? "dark" : "light")")
        }
    }
}
