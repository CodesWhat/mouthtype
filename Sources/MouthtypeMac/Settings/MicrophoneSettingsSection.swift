import SwiftUI

/// General: the microphone popup row. The priority list lives on the Advanced page (`MicrophonePriorityRows`).
struct MicrophoneSettingsSection: View {
    @Bindable var model: MicrophoneSettingsModel

    private var choices: [DesignChoice<MicrophoneChoice>] {
        var list = [DesignChoice("System Default", MicrophoneChoice.systemDefault), DesignChoice("Priority list", .priorityList)]
        list += model.inputs.map { DesignChoice($0.name, MicrophoneChoice.device($0.uid)) }
        if let preferred = model.preferred, !model.inputs.contains(where: { $0.uid == preferred.uid }) {
            list.append(DesignChoice("\(preferred.name) (unavailable)", .device(preferred.uid)))
        }
        if model.choice == .invalidPreference { list.append(DesignChoice("Choose an input", .invalidPreference)) }
        return list
    }

    var body: some View {
        Group {
            DesignRow(title: "Microphone", detail: model.status) {
                DesignPopup(title: "Microphone", selection: Binding(get: { model.choice }, set: { if $0 != model.choice { model.choose($0) } }),
                    choices: choices).accessibilityIdentifier("settings-microphone")
                Button("Refresh inputs", action: model.refresh).buttonStyle(.designSecondary).fixedSize()
                    .accessibilityIdentifier("settings-microphone-refresh")
            }
            if let error = model.error { ModalCardNote(text: error, tone: .red) }
        }
    }
}

/// Advanced: rank your inputs, the first one connected wins the take. While the list isn't the chosen microphone, one row switches to it.
struct MicrophonePriorityRows: View {
    @Bindable var model: MicrophoneSettingsModel

    var body: some View {
        Group {
            if model.choice == .priorityList, let priority = model.priority {
                DesignRow(title: "Microphone priority list", detail: "Rank your inputs. The first one that's connected wins the take.") {
                    EmptyView()
                }
                ForEach(Array(priority.devices.enumerated()), id: \.element.uid) { index, device in
                    DesignRow(title: device.name + (model.inputs.contains(where: { $0.uid == device.uid }) ? "" : " (unavailable)")) {
                        Button { model.movePriority(uid: device.uid, offset: -1) } label: { Image(systemName: "arrow.up") }
                            .buttonStyle(.designSecondary).fixedSize().disabled(index == 0).accessibilityLabel("Move \(device.name) up")
                        Button { model.movePriority(uid: device.uid, offset: 1) } label: { Image(systemName: "arrow.down") }
                            .buttonStyle(.designSecondary).fixedSize().disabled(index == priority.devices.count - 1).accessibilityLabel("Move \(device.name) down")
                        Button { model.removePriority(uid: device.uid) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.designSecondary).fixedSize().disabled(priority.devices.count == 1 && !priority.fallbackToDefault)
                            .accessibilityLabel("Remove \(device.name)")
                    }
                }
                DesignRow(title: "Add microphone") {
                    Menu("Add microphone") {
                        ForEach(model.inputs.filter { input in !priority.devices.contains(where: { $0.uid == input.uid }) }, id: \.uid) { input in
                            Button(input.name) { model.addPriority(uid: input.uid) }
                        }
                    }.menuStyle(.button).buttonStyle(.designSecondary).fixedSize().disabled(priority.devices.count >= 32)
                        .accessibilityLabel("Add microphone to the priority list")
                }
                ModalToggleRow(title: "Use System Default if no listed microphone is available",
                    isOn: Binding(get: { priority.fallbackToDefault }, set: model.setPriorityFallback))
                    .disabled(priority.devices.isEmpty)
                if priority.devices.isEmpty { ModalCardNote(text: "Add a microphone before turning off System Default fallback.") }
                ModalCardNote(text: "The first available listed microphone is chosen at the start of a take. A device change during recording still cancels that take.")
            } else {
                DesignRow(title: "Microphone priority list", detail: "Rank your inputs. The first one that's connected wins the take.") {
                    Button("Use priority list") { model.choose(.priorityList) }.buttonStyle(.designSecondary).fixedSize()
                        .accessibilityIdentifier("settings-microphone-priority")
                }
            }
        }
    }
}
