import AppKit
import SwiftUI

struct FontOverridesSection: View {
    @Bindable var model: SettingsModel

    private var typography: Typography { Typography(choice: model.font, overrides: model.fontOverrides) }

    var body: some View {
        SettingsGroup(eyebrow: "FONT OVERRIDES",
            footer: model.fontOverrides.enabled ? "Switching overrides off keeps your choices. Hi-Fi’s bitmap readouts keep their own artwork." : nil) {
            SettingsRow(title: "Override individual fonts",
                detail: model.fontOverrides.enabled ? "Use the base text font, or choose a family for each part." : nil) {
                Toggle("Override individual fonts", isOn: Binding(get: { model.fontOverrides.enabled }, set: model.setFontOverridesEnabled))
                    .labelsHidden().toggleStyle(.switch).accessibilityIdentifier("settings-font-overrides")
            }
            if model.fontOverrides.enabled {
                ForEach(FontGroup.allCases, id: \.rawValue) { group in
                    fontRow(group)
                }
            }
            if model.canResetFonts {
                SettingsRow(title: "Reset fonts to defaults") {
                    Button("Reset", action: model.resetFonts).accessibilityIdentifier("settings-font-reset")
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Ready when you are.").font(Font(typography.font(.pillMessage)))
                if model.fontOverrides.enabled {
                    Text("The words stay yours.").font(Font(typography.font(.body)))
                    Text("00:42").font(Font(typography.font(.numeric)))
                }
            }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Selected font preview")
        }
    }

    private func fontRow(_ group: FontGroup) -> some View {
        let family = model.fontOverrides.families[group]
        let unavailable = family.map { !model.fontFamilies.contains($0) } ?? false
        return SettingsRow(title: group.title,
            detail: (family ?? "Use base font") + (unavailable ? "\nUnavailable. Using the base font." : "")) {
            Menu {
                Button { model.setFontFamily(nil, for: group) } label: {
                    if family == nil { Label("Use base font", systemImage: "checkmark") }
                    else { Text("Use base font") }
                }
                Divider()
                ForEach(model.fontFamilies, id: \.self) { option in
                    Button { model.setFontFamily(option, for: group) } label: {
                        if option == family { Label(option, systemImage: "checkmark") }
                        else { Text(option) }
                    }
                }
            } label: { Text("Choose…") }
                .fixedSize().accessibilityLabel("Choose \(group.title.lowercased()) font")
                .accessibilityValue(family ?? "Use base font")
                .accessibilityIdentifier("settings-font-" + group.rawValue)
        }
    }
}
