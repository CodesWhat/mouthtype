import SwiftUI

struct MicrophoneSettingsSection: View {
    @Bindable var model: MicrophoneSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Microphone").fontWeight(.medium)
                Spacer()
                Picker("Microphone", selection: Binding(get: { model.choice }, set: model.choose)) {
                    Text("System Default")
                        .tag(MicrophoneChoice.systemDefault)
                    ForEach(model.inputs, id: \.uid) { device in
                        Text(device.name).tag(MicrophoneChoice.device(device.uid))
                    }
                    if let preferred = model.preferred, !model.inputs.contains(where: { $0.uid == preferred.uid }) {
                        Text("\(preferred.name) (unavailable)").tag(MicrophoneChoice.device(preferred.uid)).disabled(true)
                    }
                    if model.choice == .invalidPreference {
                        Text("Choose an input").tag(MicrophoneChoice.invalidPreference).disabled(true)
                    }
                }.labelsHidden().frame(maxWidth: 300).accessibilityIdentifier("settings-microphone")
                Button("Refresh inputs", action: model.refresh).accessibilityIdentifier("settings-microphone-refresh")
            }
            Text(model.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
