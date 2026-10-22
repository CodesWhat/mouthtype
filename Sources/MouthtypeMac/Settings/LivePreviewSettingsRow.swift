import SwiftUI

struct LivePreviewSettingsRow: View {
    let model: SettingsModel

    var body: some View {
        ModalToggleRow(
            title: "Live words",
            detail: "Shows words as you speak, above the pill. Only the final text is inserted after you stop. Applies to the next recording.",
            isOn: Binding(get: { model.livePreview }, set: model.setLivePreview), identifier: "settings-live-preview")
    }
}
