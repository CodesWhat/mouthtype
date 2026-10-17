import CoreAudio
import Foundation
import Observation

enum MicrophoneChoice: Hashable {
    case systemDefault
    case device(String)
    case invalidPreference
}

@MainActor @Observable final class MicrophoneSettingsModel {
    private let defaults: UserDefaults
    private let devices: () throws -> [MicrophoneDevice]
    private let defaultInput: () -> AudioDeviceID?
    private let onChanged: () -> Void
    private(set) var choice = MicrophoneChoice.systemDefault
    private(set) var inputs: [MicrophoneDevice] = []
    private(set) var preferred: PreferredMicrophone?
    private(set) var error: String?
    private(set) var systemDefaultName: String?

    var status: String {
        if let preferred, !inputs.contains(where: { $0.uid == preferred.uid }) {
            return "\(preferred.name) is unavailable. Reconnect it or choose another input."
        }
        if inputs.isEmpty { return "No microphone found. Connect one, then refresh inputs." }
        if let preferred { return "Next dictation uses \(preferred.name). Your Mac’s system input stays unchanged." }
        return "Next dictation follows System Default" + (systemDefaultName.map { " (\($0))." } ?? ".")
    }

    init(defaults: UserDefaults = .standard,
         devices: @escaping () throws -> [MicrophoneDevice] = { try InputDevice.availableMicrophones() },
         defaultInput: @escaping () -> AudioDeviceID? = { InputDevice.defaultInputID() },
         onChanged: @escaping () -> Void = {}) {
        self.defaults = defaults
        self.devices = devices
        self.defaultInput = defaultInput
        self.onChanged = onChanged
        refresh()
    }

    func refresh() {
        error = nil
        do {
            preferred = try PreferredMicrophone.load(defaults)
            choice = preferred.map { .device($0.uid) } ?? .systemDefault
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
            case .invalidPreference: return
            }
            try PreferredMicrophone.save(selected, in: defaults)
            refresh()
            onChanged()
        } catch { self.error = String(describing: error) }
    }
}
