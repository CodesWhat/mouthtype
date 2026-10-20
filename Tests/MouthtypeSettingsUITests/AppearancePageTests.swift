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
}
