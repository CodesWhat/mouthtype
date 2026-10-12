import AppKit
import Foundation
import Testing
@testable import MouthtypeMac

@MainActor
@Suite struct TypographyTests {
    init() { FontRegistry.registerBundledFonts() }

    private func width(_ text: String, _ font: NSFont) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: font]).size().width
    }

    @Test func theBundledFontsRegisterFromTheBundle() {
        let families = FontRegistry.registerBundledFonts()
        #expect(families == ["Instrument Serif", "Instrument Sans", "JetBrains Mono"])
        for name in [FontRegistry.serifName, FontRegistry.monoName] + FontRegistry.sansNames {
            #expect(NSFont(name: name, size: 12) != nil, "\(name) should resolve")
        }
        #expect(Typography.systemaAvailable)
        let files = FontRegistry.fontURLs(in: .module).map(\.lastPathComponent)
        #expect(files.count == 5)
        for file in files where file.hasSuffix(".ttf") {
            let licence = "OFL-" + file.split(separator: "-")[0] + ".txt"
            #expect(Bundle.module.url(forResource: licence, withExtension: nil, subdirectory: FontRegistry.directory) != nil)
        }
    }

    @Test func theSystemaSetHandsEachRoleItsFace() {
        let t = Typography(choice: .systema)
        #expect(t.font(.header).familyName == "Instrument Serif")
        #expect(t.font(.pillMessage).familyName == "Instrument Serif")
        #expect(t.font(.body).familyName == "Instrument Sans")
        #expect(t.font(.pillDetail).familyName == "Instrument Sans")
        #expect(t.font(.button).fontName == "InstrumentSans-SemiBold")
        #expect(t.font(.numeric).familyName == "JetBrains Mono")
        // The serif is sized up against the sans it stands in for.
        let sans = Typography(choice: .system)
        #expect(t.font(.header).pointSize >= sans.font(.header).pointSize + 2)
        #expect(t.font(.pillMessage).pointSize >= sans.font(.pillMessage).pointSize + 2)
        #expect(t.font(.pillDetail).pointSize < t.font(.pillMessage).pointSize)
    }

    @Test func eachSystemChoiceServesEveryRoleFromOneFamily() {
        let system = Typography(choice: .system)
        let rounded = Typography(choice: .rounded)
        let serif = Typography(choice: .serif)
        let mono = Typography(choice: .mono)
        for role in TextRole.allCases {
            #expect(system.font(role).familyName?.hasPrefix("Instrument") == false)
            #expect(rounded.font(role).fontName.contains("Rounded"))
            #expect(serif.font(role).fontName.contains("NewYork"))
            #expect(mono.font(role).isFixedPitch)
        }
        #expect(system.font(.pillMessage).pointSize == 12 && system.font(.body).pointSize == 13)
    }

    @Test func aCustomFamilyServesEveryRoleAndAMissingOneFallsBackToSystem() {
        let custom = Typography(choice: .custom("Menlo"))
        for role in TextRole.allCases { #expect(custom.font(role).familyName == "Menlo") }
        #expect(custom.effectiveChoice == .custom("Menlo"))

        let missing = Typography(choice: .custom("No Such Family 123"))
        #expect(missing.effectiveChoice == .system)
        let system = Typography(choice: .system)
        for role in TextRole.allCases { #expect(missing.font(role).fontName == system.font(role).fontName) }
        // A family reported absent by the check falls back even when it exists.
        #expect(Typography(choice: .custom("Menlo"), isInstalled: { _ in false }).effectiveChoice == .system)
    }

    @Test func theNumericRoleHasTabularFigures() {
        // Without the feature the system face has proportional digits, so equal widths below come from the role.
        let body = Typography(choice: .system).font(.body)
        #expect(abs(width("1", body) - width("8", body)) > 1)
        let choices: [TextFontChoice] = [.systema, .system, .rounded, .serif, .mono, .custom("Avenir Next")]
        for choice in choices {
            let font = Typography(choice: choice).font(.numeric)
            #expect(abs(width("1", font) - width("8", font)) < 0.01, "digits should share a width in \(choice.title)")
            #expect(abs(width("1111", font) - width("8888", font)) < 0.01)
        }
    }

    @Test func theChoiceIsStoredAndReadBack() throws {
        let suite = "mouthtype-typography-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(TextFontPreference.current(defaults) == .systema)
        for choice in TextFontChoice.standard + [.custom("Menlo")] {
            TextFontPreference.set(choice, in: defaults)
            #expect(TextFontPreference.current(defaults) == choice)
        }
        defaults.set("custom", forKey: TextFontPreference.key)
        defaults.set("", forKey: TextFontPreference.familyKey)
        #expect(TextFontPreference.current(defaults) == .systema)
        defaults.set("bogus", forKey: TextFontPreference.key)
        #expect(TextFontPreference.current(defaults) == .systema)
    }

    @Test func theTextFontMenuListsTheChoicesAndAppliesAPick() throws {
        let suite = "mouthtype-fontmenu-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let section = TextFontMenuSection(defaults: defaults)
        let submenu = try #require(section.items.first?.submenu)
        #expect(submenu.items.filter { !$0.isSeparatorItem }.map(\.title) == [
            "Systema Set", "System", "System Rounded", "System Serif", "System Mono", "Choose Font\u{2026}",
        ])
        #expect(submenu.items.map(\.state).prefix(5) == [.on, .off, .off, .off, .off])
        let serif = try #require(submenu.items.first { $0.title == "System Serif" })
        _ = serif.target?.perform(serif.action, with: serif)
        #expect(TextFontPreference.current(defaults) == .serif)
        #expect(submenu.items.map(\.state).prefix(5) == [.off, .off, .off, .on, .off])
    }
}
