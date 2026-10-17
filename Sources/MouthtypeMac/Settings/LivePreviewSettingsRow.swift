import SwiftUI

struct LivePreviewSettingsRow: View {
    let model: SettingsModel

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Live words").fontWeight(.medium)
                Text("Show provisional words above the pill. Only the final text is inserted after you stop. Applies to the next recording.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("Live words", isOn: Binding(get: { model.livePreview }, set: model.setLivePreview))
                .labelsHidden().toggleStyle(.switch).accessibilityIdentifier("settings-live-preview")
        }.padding(.vertical, 17)
    }
}
