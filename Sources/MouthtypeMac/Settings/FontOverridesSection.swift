import AppKit
import SwiftUI

struct FontOverridesSection: View {
    @Bindable var model: SettingsModel

    private var typography: Typography { Typography(choice: model.font, overrides: model.fontOverrides) }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Toggle("Override individual fonts", isOn: Binding(get: { model.fontOverrides.enabled }, set: model.setFontOverridesEnabled))
                .accessibilityIdentifier("settings-font-overrides")
            if model.fontOverrides.enabled {
                Text("Use the base text font, or choose a family for each part.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(FontGroup.allCases, id: \.rawValue) { group in
                    fontRow(group)
                }
                Text("Switching overrides off keeps your choices. Hi-Fi’s bitmap readouts keep their own artwork.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Reset fonts to defaults", action: model.resetFonts).accessibilityIdentifier("settings-font-reset")
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Ready when you are.").font(Font(typography.font(.pillMessage)))
                if model.fontOverrides.enabled {
                    Text("The words stay yours.").font(Font(typography.font(.body)))
                    Text("00:42").font(Font(typography.font(.numeric)))
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor)).accessibilityLabel("Selected font preview")
        }
    }

    private func fontRow(_ group: FontGroup) -> some View {
        let family = model.fontOverrides.families[group]
        return HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(group.title).fontWeight(.medium)
                Text(family ?? "Use base font").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let family, !model.fontFamilies.contains(family) {
                    Text("Unavailable. Using the base font.").font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
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
                .frame(width: 105).accessibilityLabel("Choose \(group.title.lowercased()) font")
                .accessibilityValue(family ?? "Use base font")
                .accessibilityIdentifier("settings-font-" + group.rawValue)
        }.padding(.vertical, 5)
    }
}
