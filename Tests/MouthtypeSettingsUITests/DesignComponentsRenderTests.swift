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
        #expect(hex(DesignPalette.NS.accent, .aqua) == "315B54" && hex(DesignPalette.NS.accent, .darkAqua) == "4F8F82")
        #expect(hex(DesignPalette.NS.symbol, .darkAqua) == "8FC1B5" && hex(DesignPalette.NS.orange, .aqua) == "F19A4B")
        #expect(hex(DesignPalette.NS.c0, .aqua) == "E6E6EA" && hex(DesignPalette.NS.c4, .aqua) == "315B54")
        #expect(hex(DesignPalette.NS.c1, .darkAqua) == "2B3A37" && hex(DesignPalette.NS.c4, .darkAqua) == "8FC1B5")
        #expect(hex(DesignPalette.NS.track, .aqua) == "D9D9DE" && hex(DesignPalette.NS.key, .darkAqua) == "38383B")
    }

    @Test func everyPixelIconIsBundledAsATemplateImage() {
        for icon in DesignIcon.allCases {
            let image = icon.image
            #expect(image?.isTemplate == true, "\(icon.rawValue) missing")
            #expect(image?.representations.count == 3, "\(icon.rawValue) should carry 1x, 2x and 4x")
            #expect(image?.size == NSSize(width: 16, height: 16))
        }
    }

    @Test func bundledFontsRegisterOrTheSystemFallbackStillGivesTypography() {
        FontRegistry.registerBundledFonts()
        #expect(FontRegistry.registered?.count == 3)
        #expect(NSFont(name: FontRegistry.serifName, size: 28) != nil)
        // The helpers return a Font either way; a fallback must not trap.
        _ = (DesignFont.serif(28), DesignFont.sans(13, .semibold), DesignFont.mono(10))
    }
}
