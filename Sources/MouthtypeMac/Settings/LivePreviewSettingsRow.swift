import SwiftUI

struct LivePreviewSettingsRow: View {
    let model: SettingsModel

    var body: some View {
        SettingsRow(title: "Live words",
            detail: "Show provisional words above the pill. Only the final text is inserted after you stop. Applies to the next recording.") {
            Toggle("Live words", isOn: Binding(get: { model.livePreview }, set: model.setLivePreview))
                .labelsHidden().toggleStyle(.switch).accessibilityIdentifier("settings-live-preview")
        }
    }
}
