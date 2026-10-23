import AppKit
import SwiftUI

/// The font override rows of the Appearance card, and a standalone card of the same rows for tests and previews. `rows` is a plain
/// view builder so each row lands in the page's card with a hairline between it and the next.
struct FontOverridesSection: View {
    @Bindable var model: SettingsModel

    private var typography: Typography { Typography(choice: model.font, overrides: model.fontOverrides) }

    var body: some View {
        DesignSection(
            eyebrow: "Font overrides",
            footer: model.fontOverrides.enabled ? "Turning overrides off keeps your choices." : nil
        ) {
            rows
        }
    }

    @ViewBuilder var rows: some View {
        DesignRow(
            title: "Override individual fonts",
            detail: model.fontOverrides.enabled
                ? "Use the base text font, or choose a family for each part."
                : "Pick separate heading, body and readout fonts."
        ) {
            Toggle("Override individual fonts", isOn: Binding(get: { model.fontOverrides.enabled }, set: model.setFontOverridesEnabled))
                .labelsHidden().toggleStyle(.designSwitch).accessibilityIdentifier("settings-font-overrides")
        }
        if model.fontOverrides.enabled {
            ForEach(FontGroup.allCases, id: \.rawValue) { group in
                fontRow(group)
            }
        }
        if model.canResetFonts {
            DesignRow(title: "Reset fonts to defaults") {
                Button("Reset", action: model.resetFonts).buttonStyle(.designSecondary)
                    .accessibilityLabel("Reset fonts to defaults").accessibilityIdentifier("settings-font-reset")
            }
        }
        VStack(alignment: .leading, spacing: 10) {
            Text("Ready when you are.").font(Font(typography.font(.pillMessage)))
            if model.fontOverrides.enabled {
                Text("The words stay yours.").font(Font(typography.font(.body)))
                Text("00:42").font(Font(typography.font(.numeric)))
            }
        }
        .foregroundStyle(DesignPalette.ink)
        .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine).accessibilityLabel("Selected font preview")
    }

    private static let baseFont = ""

    private func fontRow(_ group: FontGroup) -> some View {
        let family = model.fontOverrides.families[group]
        let unavailable = family.map { !model.fontFamilies.contains($0) } ?? false
        var choices = [DesignChoice("Use base font", Self.baseFont)]
        if let family, unavailable { choices.append(DesignChoice(family, family)) }
        choices += model.fontFamilies.map { DesignChoice($0, $0) }
        return DesignRow(
            title: group.title,
            detail: unavailable ? "Unavailable. Using the base font." : nil
        ) {
            DesignPopup(
                title: "Choose \(group.title.lowercased()) font",
                selection: Binding(get: { family ?? Self.baseFont }, set: { model.setFontFamily($0.isEmpty ? nil : $0, for: group) }),
                choices: choices
            )
            .accessibilityIdentifier("settings-font-" + group.rawValue)
        }
    }
}
