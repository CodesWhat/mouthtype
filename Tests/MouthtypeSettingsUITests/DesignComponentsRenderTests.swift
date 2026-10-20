import AppKit
import SwiftUI
import Testing
@testable import MouthtypeMac

/// The shared redesign components drawn together in light and dark (PNGs go to MOUTHTYPE_SETTINGS_PREVIEWS), plus the palette values.
@MainActor @Suite(.serialized) struct DesignComponentsRenderTests {
    private struct Gallery: View {
        @State var sounds = true
        @State var live = false
        @State var behavior = "hold"
        @State var size = "auto"

        var body: some View {
            DesignPage(title: "Your recent takes.", summary: "Everything you dictated lately.", trailing: {
                Button("Transcribe a file…") {}.buttonStyle(.designSecondary)
            }, content: {
                DesignSection(eyebrow: "Dictation", footer: "A footer note wraps under the card.") {
                    DesignRow(title: "Shortcut", detail: "Hold it, speak, let go.") {
                        DesignKbd("Fn")
                        Button("Change…") {}.buttonStyle(.designSecondary)
                    }
                    DesignRow(title: "Recording behavior", detail: "Hold to talk, or press once to start and again to stop.") {
                        DesignPopup(title: "Recording behavior", selection: $behavior,
                                    choices: [DesignChoice("Hold to talk", "hold"), DesignChoice("Press to toggle", "toggle")])
                    }
                    DesignRow(title: "Recording sounds", detail: "A small cue when you start and finish.") {
                        Toggle("Recording sounds", isOn: $sounds).labelsHidden().toggleStyle(.designSwitch)
                    }
                    DesignRow(title: "Live words") {
                        Toggle("Live words", isOn: $live).labelsHidden().toggleStyle(.designSwitch)
                    }
                    DesignRow(title: "Pill size") {
                        DesignSegmented(title: "Pill size", selection: $size,
                                        choices: [DesignChoice("Auto", "auto"), DesignChoice("Large", "large", dot: DesignPalette.accent)])
                    }
                }
                HStack(spacing: 8) {
                    ForEach(Array(DesignPalette.chart.enumerated()), id: \.offset) { _, color in
                        RoundedRectangle(cornerRadius: 6).fill(color).frame(width: 36, height: 24)
                    }
                    Button("Save") {}.buttonStyle(.designPrimary)
                    ForEach(DesignIcon.allCases) { DesignIconView(icon: $0) }
                }
            })
        }
    }

    @Test func galleryRendersInLightAndDark() throws {
        FontRegistry.registerBundledFonts()
        for dark in [false, true] {
            let bitmap = try SettingsRender.render(Gallery(), dark: dark, size: NSSize(width: 700, height: 560))
            try SettingsRender.save(bitmap, name: "design-components-\(dark ? "dark" : "light")")
        }
    }

    /// Three rows with the first and last drawn as hovered, the way a list row's grey fill sits against the card.
    private struct HoveredRows: View {
        var body: some View {
            DesignSection(eyebrow: "Hover") {
                DesignRow(title: "First row, hovered", detail: "The fill must stop at the card's rounded corners.") { EmptyView() }
                    .background(DesignPalette.hair2)
                DesignRow(title: "Middle row") { EmptyView() }
                DesignRow(title: "Last row, hovered") { EmptyView() }
                    .background(DesignPalette.hair2)
            }
            .padding(24)
        }
    }

    @Test func hoveredFirstAndLastRowsStayInsideTheCardCorners() throws {
        FontRegistry.registerBundledFonts()
        for dark in [false, true] {
            let size = NSSize(width: 480, height: 260)
            let bitmap = try SettingsRender.render(HoveredRows(), dark: dark, size: size)
            try SettingsRender.save(bitmap, name: "design-card-hover-\(dark ? "dark" : "light")")
            let scale = CGFloat(bitmap.pixelsWide) / size.width
            // The card starts 24 pt in, plus 6 pt of eyebrow and its height; read just inside the top-left corner and inside the row.
            func pixel(_ x: CGFloat, _ y: CGFloat) -> NSColor? {
                bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB)
            }
            func same(_ a: NSColor?, _ b: NSColor?) -> Bool {
                guard let a, let b else { return false }
                return abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) < 0.02
            }
            // Find the card's top edge: the first row from the top where the middle of the page is no longer the page background.
            let page = pixel(4, 4)
            var top: CGFloat = 0
            for y in stride(from: CGFloat(10), to: 120, by: 1) where !same(pixel(size.width / 2, y), page) && !same(pixel(size.width / 2, y), nil) {
                // The eyebrow text can match this too, so take the first full-width run: the card edge is non-page at both x = 40 and x = 440.
                if !same(pixel(60, y), page), !same(pixel(440, y), page) { top = y; break }
            }
            #expect(top > 0)
            let inside = pixel(size.width / 2, top + 12)
            let corner = pixel(24.5, top + 0.5)
            #expect(!same(corner, inside), "the hover fill reaches the square corner")
        }
    }

    @Test func paletteMatchesTheHandoffValues() {
        func hex(_ color: NSColor, _ name: NSAppearance.Name) -> String {
            var out = ""
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let c = color.usingColorSpace(.sRGB)!
                out = String(format: "%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
            }
            return out
        }
        #expect(hex(DesignPalette.NS.bg, .aqua) == "F3F3F5" && hex(DesignPalette.NS.bg, .darkAqua) == "1F1F21")
        #expect(hex(DesignPalette.NS.surface, .aqua) == "FFFFFF" && hex(DesignPalette.NS.surface, .darkAqua) == "2A2A2C")
        // v1-pass lime.
        #expect(hex(DesignPalette.NS.accent, .aqua) == "76A11A" && hex(DesignPalette.NS.accent, .darkAqua) == "A6CD52")
        #expect(hex(DesignPalette.NS.onAccent, .aqua) == "1D1D1F" && hex(DesignPalette.NS.onAccent, .darkAqua) == "1F1F21")
        #expect(hex(DesignPalette.NS.accentText, .aqua) == "4A6A12" && hex(DesignPalette.NS.focus, .aqua) == "4A6A12")
        #expect(hex(DesignPalette.NS.orange, .aqua) == "E37512" && hex(DesignPalette.NS.orange, .darkAqua) == "F19A4B")
        #expect(hex(DesignPalette.NS.success, .aqua) == "537F5D" && hex(DesignPalette.NS.danger, .darkAqua) == "FF564C")
        #expect(hex(DesignPalette.NS.gold, .aqua) == "BB8C1A" && hex(DesignPalette.NS.silver, .aqua) == "8F939D")
        #expect(hex(DesignPalette.NS.bronze, .aqua) == "B8733A" && hex(DesignPalette.NS.personalBest, .darkAqua) == "3A2B1B")
        #expect(hex(DesignPalette.NS.c0, .aqua) == "EFF4E4" && hex(DesignPalette.NS.c4, .aqua) == "3B4F0E")
        #expect(hex(DesignPalette.NS.c1, .darkAqua) == "556535" && hex(DesignPalette.NS.c4, .darkAqua) == "DBEBBA")
        #expect(hex(DesignPalette.NS.track, .aqua) == "D9D9DE" && hex(DesignPalette.NS.key, .darkAqua) == "38383B")
    }

    @Test func lightAccentFillClearsThreeToOneOnWhiteAndCarriesDarkInk() {
        func luminance(_ value: Int) -> Double {
            let channels = [16, 8, 0].map { Double((value >> $0) & 0xFF) / 255 }.map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
        }
        func ratio(_ a: Int, _ b: Int) -> Double {
            let (x, y) = (luminance(a), luminance(b))
            return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }
        #expect(ratio(0x76A11A, 0xFFFFFF) >= 3)
        #expect(ratio(0x1D1D1F, 0x76A11A) >= 4.5)
        #expect(ratio(0x1F1F21, 0xA6CD52) >= 4.5)
    }

    @Test func everyPixelIconIsBundledAsATemplateImage() {
        for icon in DesignIcon.allCases {
            let image = icon.image
            #expect(image?.isTemplate == true, "\(icon.rawValue) missing")
            #expect(image?.representations.count == 3, "\(icon.rawValue) should carry 1x, 2x and 4x")
            #expect(image?.size == NSSize(width: 16, height: 16))
            // Pixelarticons sampled without smoothing: 16, 32 and 64 px, every pixel fully on or fully off, so each stays crisp.
            let sizes = (image?.representations.compactMap { ($0 as? NSBitmapImageRep).map { $0.pixelsWide } } ?? []).sorted()
            #expect(sizes == [16, 32, 64], "\(icon.rawValue) scales")
            for case let rep as NSBitmapImageRep in image?.representations ?? [] {
                var partial = 0, lit = 0
                for y in 0..<rep.pixelsHigh {
                    for x in 0..<rep.pixelsWide {
                        let alpha = rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
                        if alpha > 0.001 && alpha < 0.999 { partial += 1 }
                        if alpha >= 0.999 { lit += 1 }
                    }
                }
                #expect(partial == 0 && lit > 0, "\(icon.rawValue) \(rep.pixelsWide) px has smoothed or empty pixels")
            }
        }
    }

    @Test func pixelarticonsLicenceShipsWithTheFontLicences() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let licence = root.appendingPathComponent("Sources/MouthtypeMac/Resources/Fonts/MIT-Pixelarticons.txt")
        let text = try String(contentsOf: licence, encoding: .utf8)
        #expect(try String(contentsOf: root.appendingPathComponent("THIRD_PARTY_NOTICES.md"), encoding: .utf8).contains("MIT-Pixelarticons.txt"))
        #expect(text.contains("MIT License") && text.contains("Gerrit Halfmann"))
    }

    @Test func bundledFontsRegisterOrTheSystemFallbackStillGivesTypography() {
        FontRegistry.registerBundledFonts()
        #expect(FontRegistry.registered?.count == 3)
        #expect(NSFont(name: FontRegistry.serifName, size: 28) != nil)
        // The helpers return a Font either way; a fallback must not trap.
        _ = (DesignFont.serif(28), DesignFont.sans(13, .semibold), DesignFont.mono(10))
    }
}
