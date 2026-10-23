import AppKit
import Foundation
import Testing
@testable import MouthtypeMac

@MainActor @Suite struct FontOverridesTests {
    init() { FontRegistry.registerBundledFonts() }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "FontOverridesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test func roleChoicesSurviveDisablingAndKeepTheLegacyGlobalChoice() {
        withDefaults { defaults in
            TextFontPreference.set(.custom("Menlo"), in: defaults)
            #expect(!TextFontOverrides.load(defaults).enabled)
            TextFontOverrides.setFamily("Avenir Next", for: .heading, in: defaults)
            TextFontOverrides.setFamily("Menlo", for: .readout, in: defaults)
            TextFontOverrides.setEnabled(true, in: defaults)
            #expect(TextFontOverrides.load(defaults).enabled)
            TextFontOverrides.setEnabled(false, in: defaults)
            #expect(TextFontOverrides.load(defaults).families == [.heading: "Avenir Next", .readout: "Menlo"])
            #expect(TextFontPreference.current(defaults) == .custom("Menlo"))
            TextFontOverrides.setEnabled(true, in: defaults)
            #expect(TextFontOverrides.load(defaults).families[.heading] == "Avenir Next")
        }
    }

    @Test func groupsApplyIndependentlyAndPreserveRoleSizes() {
        let base = Typography(choice: .systema)
        let font = Typography(
            choice: .systema,
            overrides: TextFontOverrides(
                enabled: true,
                families: [.heading: "Menlo", .body: "Avenir Next", .readout: "Menlo"]))
        for role in [TextRole.header, .pillMessage, .numeric] { #expect(font.font(role).familyName == "Menlo") }
        for role in [TextRole.body, .pillDetail, .button] { #expect(font.font(role).familyName == "Avenir Next") }
        for role in TextRole.allCases { #expect(font.font(role).pointSize == base.font(role).pointSize) }
    }

    @Test func disabledAndUnavailableOverridesUseTheBaseWithoutLosingTheFamily() {
        let base = Typography(choice: .rounded)
        let saved = TextFontOverrides(enabled: false, families: [.heading: "Menlo"])
        let disabled = Typography(choice: .rounded, overrides: saved)
        let missing = Typography(
            choice: .rounded,
            overrides: TextFontOverrides(
                enabled: true,
                families: [.heading: "Not Installed Family"]), isInstalled: { _ in false })
        for role in TextRole.allCases {
            #expect(disabled.font(role).fontName == base.font(role).fontName)
            #expect(missing.font(role).fontName == base.font(role).fontName)
        }
        #expect(missing.overrides.families[.heading] == "Not Installed Family")
    }

    @Test func numericOverridesKeepTabularDigits() {
        let font = Typography(
            choice: .systema,
            overrides: TextFontOverrides(
                enabled: true,
                families: [.readout: "Avenir Next"])
        ).font(.numeric)
        #expect(font.familyName == "Avenir Next")
        func width(_ text: String) -> CGFloat { NSAttributedString(string: text, attributes: [.font: font]).size().width }
        #expect(abs(width("1111") - width("8888")) < 0.01)
    }

    @Test func resettingFontsLeavesUnrelatedPreferencesAlone() {
        withDefaults { defaults in
            defaults.set("kept", forKey: "otherPreference")
            TextFontPreference.set(.custom("Menlo"), in: defaults)
            TextFontOverrides.setFamily("Avenir Next", for: .body, in: defaults)
            TextFontOverrides.setEnabled(true, in: defaults)
            TextFontOverrides.reset(in: defaults)
            #expect(TextFontPreference.current(defaults) == .systema)
            #expect(TextFontOverrides.load(defaults) == TextFontOverrides())
            #expect(defaults.object(forKey: TextFontOverrides.familiesKey) == nil)
            #expect(defaults.string(forKey: "otherPreference") == "kept")
        }
    }

    @Test func theGlobalFontChooserKeepsTheBaseFamilyWhenBodyIsOverridden() {
        withDefaults { defaults in
            TextFontPreference.set(.custom("Menlo"), in: defaults)
            TextFontOverrides.setFamily("Avenir Next", for: .body, in: defaults)
            TextFontOverrides.setEnabled(true, in: defaults)
            #expect(Typography.current(defaults).font(.body).familyName == "Avenir Next")
            #expect(TextFontMenuSection(defaults: defaults).chooserFont.familyName == "Menlo")
        }
    }

    @Test func preferenceEditsNotifyExistingPillAndCardObservers() {
        withDefaults { defaults in
            let count = FontChangeCount()
            let observer = NotificationCenter.default.addObserver(forName: Typography.didChange, object: nil, queue: nil) { _ in count.increment() }
            defer { NotificationCenter.default.removeObserver(observer) }
            TextFontOverrides.setEnabled(true, in: defaults)
            TextFontOverrides.setFamily("Menlo", for: .heading, in: defaults)
            TextFontOverrides.reset(in: defaults)
            #expect(count.value == 3)
        }
    }

    @Test func changingOneGroupPreservesOtherAndUnknownSavedValues() {
        withDefaults { defaults in
            defaults.set(["heading": "Menlo", "readout": "", "body": 42, "future": "saved"], forKey: TextFontOverrides.familiesKey)
            #expect(TextFontOverrides.load(defaults).families == [.heading: "Menlo"])
            TextFontOverrides.setFamily("Avenir Next", for: .body, in: defaults)
            #expect(TextFontOverrides.load(defaults).families[.heading] == "Menlo")
            #expect(defaults.dictionary(forKey: TextFontOverrides.familiesKey)?["future"] as? String == "saved")
            TextFontOverrides.setFamily(nil, for: .body, in: defaults)
            #expect(TextFontOverrides.load(defaults).families[.body] == nil)
        }
    }
}

private final class FontChangeCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
