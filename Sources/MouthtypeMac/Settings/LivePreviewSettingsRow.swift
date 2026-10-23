import SwiftUI

struct LivePreviewSettingsRow: View {
    let model: SettingsModel

    var body: some View {
        ModalToggleRow(
            title: "Live words",
            detail: "Shows words above the pill as you speak. Only the final text is inserted.",
            isOn: Binding(get: { model.livePreview }, set: model.setLivePreview), identifier: "settings-live-preview")
    }
}
