import CoreAudio
import Foundation
import Observation

enum MicrophoneChoice: Hashable {
    case systemDefault
    case device(String)
    case priorityList
    case invalidPreference
}

@MainActor @Observable final class MicrophoneSettingsModel {
    private let defaults: UserDefaults
    private let devices: () throws -> [MicrophoneDevice]
    private let defaultInput: () -> AudioDeviceID?
    private let onChanged: () -> Void
    private(set) var choice = MicrophoneChoice.systemDefault
    private(set) var inputs: [MicrophoneDevice] = []
    private(set) var priority: MicrophonePriority?
    private(set) var preferred: PreferredMicrophone?
    private(set) var error: String?
    private(set) var systemDefaultName: String?

    var status: String {
        if choice == .priorityList, let priority {
            if let selected = priority.devices.first(where: { choice in inputs.contains { $0.uid == choice.uid } }) {
                return "Next dictation uses \(selected.name), the first available input in your list."
            }
            return priority.fallbackToDefault ? "No listed input is available. Next dictation follows System Default." : "No listed input is available. Reconnect one or change your list."
        }
        if let preferred, !inputs.contains(where: { $0.uid == preferred.uid }) {
            return "\(preferred.name) is unavailable. Reconnect it or choose another input."
        }
        if inputs.isEmpty { return "No microphone found. Connect one, then refresh inputs." }
        if preferred != nil { return "Next dictation uses this microphone. Your system input is unchanged." }
        return "Next dictation follows System Default" + (systemDefaultName.map { " (\($0))." } ?? ".")
    }

    init(
        defaults: UserDefaults = .standard,
        devices: @escaping () throws -> [MicrophoneDevice] = { try InputDevice.availableMicrophones() },
        defaultInput: @escaping () -> AudioDeviceID? = { InputDevice.defaultInputID() },
        onChanged: @escaping () -> Void = {}
    ) {
        self.defaults = defaults
        self.devices = devices
        self.defaultInput = defaultInput
        self.onChanged = onChanged
        refresh()
    }

    func refresh() {
        error = nil
        do {
            priority = try MicrophonePriority.load(defaults)
            preferred = priority?.enabled == true ? nil : try PreferredMicrophone.load(defaults)
            choice = priority?.enabled == true ? .priorityList : preferred.map { .device($0.uid) } ?? .systemDefault
        } catch {
            preferred = nil
            choice = .invalidPreference
            self.error = String(describing: error)
        }
        do {
            inputs = try devices()
            let id = defaultInput()
            systemDefaultName = inputs.first { $0.input.id == id }?.name
        } catch {
            inputs = []
            systemDefaultName = nil
            self.error = String(describing: error)
        }
    }

    func choose(_ choice: MicrophoneChoice) {
        do {
            let selected: PreferredMicrophone?
            switch choice {
            case .systemDefault: selected = nil
            case .device(let uid):
                guard let device = inputs.first(where: { $0.uid == uid }) else { throw CaptureError.selectedMicrophoneUnavailable }
                selected = PreferredMicrophone(uid: device.uid, name: device.name)
            case .priorityList:
                var policy = (try? MicrophonePriority.load(defaults)) ?? MicrophonePriority(enabled: false, devices: [])
                if policy.devices.isEmpty, let initial = preferred ?? inputs.first.map({ PreferredMicrophone(uid: $0.uid, name: $0.name) }) {
                    policy.devices = [initial]
                }
                policy.enabled = true
                try policy.save(in: defaults)
                refresh()
                onChanged()
                return
            case .invalidPreference: return
            }
            try PreferredMicrophone.save(selected, in: defaults)
            if var policy = try? MicrophonePriority.load(defaults) {
                policy.enabled = false
                try policy.save(in: defaults)
            } else {
                defaults.removeObject(forKey: MicrophonePriority.defaultsKey)
            }
            refresh()
            onChanged()
        } catch { self.error = String(describing: error) }
    }
    private func updatePriority(_ change: (inout MicrophonePriority) -> Void) {
        do {
            guard var policy = try MicrophonePriority.load(defaults) else { return }
            change(&policy)
            try policy.save(in: defaults)
            refresh()
            onChanged()
        } catch { self.error = String(describing: error) }
    }

    func addPriority(uid: String) {
        guard let input = inputs.first(where: { $0.uid == uid }), priority?.devices.contains(where: { $0.uid == uid }) != true else { return }
        updatePriority { $0.devices.append(PreferredMicrophone(uid: input.uid, name: input.name)) }
    }

    func movePriority(uid: String, offset: Int) {
        guard let index = priority?.devices.firstIndex(where: { $0.uid == uid }),
            let count = priority?.devices.count, (0..<count).contains(index + offset)
        else { return }
        updatePriority { $0.devices.swapAt(index, index + offset) }
    }

    func removePriority(uid: String) { updatePriority { $0.devices.removeAll { $0.uid == uid } } }
    func setPriorityFallback(_ enabled: Bool) { updatePriority { $0.fallbackToDefault = enabled } }

}
