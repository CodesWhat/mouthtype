import AppKit
import SwiftUI
import Testing
@testable import MouthtypeMac

@MainActor @Suite(.serialized) struct AppearancePageTests {
    private func makeModel(skin: PillSkinKind, overrides: Bool = false) -> (SettingsModel, UserDefaults, String) {
        let name = "AppearancePageTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        PillSkinPreference.set(skin, in: defaults)
        FontRegistry.registerBundledFonts()
        let model = SettingsModel(defaults: defaults)
        model.page = .appearance
        if overrides { model.setFontOverridesEnabled(true) }
        return (model, defaults, name)
    }

    @Test func fontRowsApplyToEveryStyleExceptHiFi() {
        for skin in PillSkinKind.allCases {
            #expect(skin.usesTextFont == (skin != .hifi), "text font for \(skin)")
            #expect(skin.hasReadoutColour == (skin == .hifi), "readout colour for \(skin)")
        }
        #expect(PillSkinKind.minimal.textFontDetail == "Used by the delivery cards.")
        #expect(PillSkinKind.classic.textFontDetail.contains("pill"))
    }

    @Test func selectingATileChangesTheSavedStyle() {
        let (model, defaults, name) = makeModel(skin: .classic)
        defer { defaults.removePersistentDomain(forName: name) }
        var picked: PillSkinKind?
        let picker = AppearanceStylePicker(selection: model.skin, onSelect: { picked = $0 })
        picker.onSelect(.matrix)
        model.setSkin(picked ?? .classic)
        #expect(PillSkinPreference.current(defaults) == .matrix)
    }

    @Test func previewSizeNamesAutomaticAsStandard() {
        #expect(PillSize.automatic.previewTitle == "Standard")
        #expect(PillSize.standard.previewTitle == "Standard")
        #expect(PillSize.large.previewTitle == "Large")
    }

    @Test func rendersEveryStyleInLightAndDarkWithOverrides() throws {
        for skin in PillSkinKind.allCases {
            for dark in [false, true] {
                let (model, defaults, name) = makeModel(skin: skin, overrides: skin != .hifi)
                defer { defaults.removePersistentDomain(forName: name) }
                model.setFontFamily("Menlo", for: .heading)
                let bitmap = try SettingsRender.render(model: model, actions: SettingsActions(), dark: dark, size: NSSize(width: 900, height: 900))
                #expect(bitmap.pixelsWide >= 900)
                try SettingsRender.save(bitmap, name: "appearance-redesign-\(skin.rawValue)-\(dark ? "dark" : "light")")
            }
        }
    }

    @Test func glassIsASwitchOnClassicNotATile() {
        #expect(PillSkinKind.pickerKinds == [.classic, .matrix, .minimal, .hifi])
        #expect(PillSkinKind.glass.pickerKind == .classic && PillSkinKind.classic.pickerKind == .classic)
        for skin in PillSkinKind.allCases { #expect(skin.hasGlassSwitch == (skin == .classic || skin == .glass), "glass switch for \(skin)") }
    }

    @Test func aSavedGlassSkinLoadsAsClassicWithGlassOn() {
        let (model, defaults, name) = makeModel(skin: .glass)
        defer { defaults.removePersistentDomain(forName: name) }
        // The stored value is untouched, so the live pill, the menu and the cards still read `glass`.
        #expect(model.skin == .glass && defaults.string(forKey: "pillSkin") == "glass")
        #expect(model.skin.pickerKind == .classic && model.skin.hasGlassSwitch)
        model.setSkin(.classic)
        #expect(PillSkinPreference.current(defaults) == .classic)
        model.setSkin(.glass)
        #expect(PillSkinPreference.current(defaults) == .glass)
    }

    @Test func tilesShowTheRealPillOnTheSwatch() throws {
        FontRegistry.registerBundledFonts()
        for skin in PillSkinKind.allCases {
            for wallpaper in PreviewWallpaper.allCases {
                let image = try #require(PillTileImage.image(skin: skin, readout: .amber, wallpaper: wallpaper), "\(skin) on \(wallpaper)")
                // Trimmed to the pill, so it is wider than tall and no larger than the preview canvas.
                #expect(image.size.width > image.size.height && image.size.width < PreviewFit.canvas.width)
            }
        }
    }
}
