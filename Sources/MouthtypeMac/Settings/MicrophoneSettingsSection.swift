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
                    Text("Priority list").tag(MicrophoneChoice.priorityList)
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
            if model.choice == .priorityList, let priority = model.priority {
                ForEach(Array(priority.devices.enumerated()), id: \.element.uid) { index, device in
                    HStack {
                        Text(device.name + (model.inputs.contains(where: { $0.uid == device.uid }) ? "" : " (unavailable)"))
                        Spacer()
                        Button { model.movePriority(uid: device.uid, offset: -1) } label: { Image(systemName: "arrow.up") }
                            .disabled(index == 0).accessibilityLabel("Move \(device.name) up")
                        Button { model.movePriority(uid: device.uid, offset: 1) } label: { Image(systemName: "arrow.down") }
                            .disabled(index == priority.devices.count - 1).accessibilityLabel("Move \(device.name) down")
                        Button { model.removePriority(uid: device.uid) } label: { Image(systemName: "minus.circle") }
                            .disabled(priority.devices.count == 1 && !priority.fallbackToDefault).accessibilityLabel("Remove \(device.name)")
                    }
                }
                Menu("Add microphone") {
                    ForEach(model.inputs.filter { input in !priority.devices.contains(where: { $0.uid == input.uid }) }, id: \.uid) { input in
                        Button(input.name) { model.addPriority(uid: input.uid) }
                    }
                }.disabled(priority.devices.count >= 32)
                Toggle("Use System Default if no listed microphone is available", isOn: Binding(get: { priority.fallbackToDefault }, set: model.setPriorityFallback))
                Text("The first available listed microphone is chosen at the start of a take. A device change during recording still cancels that take.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text(model.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
