import Foundation
import CoreAudio

struct MicrophoneDevice: Equatable, Sendable {
    var uid: String
    var name: String
    var input: InputDevice
}

struct PreferredMicrophone: Codable, Equatable, Sendable {
    static let defaultsKey = "microphone.preferred"
    var uid: String
    var name: String

    static func load(_ defaults: UserDefaults = .standard) throws -> Self? {
        guard let stored = defaults.object(forKey: defaultsKey) else { return nil }
        guard let data = stored as? Data,
              let preference = try? JSONDecoder().decode(Self.self, from: data), !preference.uid.isEmpty
        else { throw CaptureError.microphonePreferenceUnreadable }
        return preference
    }
    static func save(_ value: Self?, in defaults: UserDefaults = .standard) throws {
        guard let value else { defaults.removeObject(forKey: defaultsKey); return }
        guard !value.uid.isEmpty else { throw CaptureError.microphonePreferenceUnreadable }
        defaults.set(try JSONEncoder().encode(value), forKey: defaultsKey)
    }
    static func resolve(_ preference: Self?, devices: [MicrophoneDevice], defaultInput: AudioDeviceID?) throws -> InputDevice {
        let chosen: MicrophoneDevice?
        if let preference {
            chosen = devices.first { $0.uid == preference.uid }
            guard chosen != nil else { throw CaptureError.selectedMicrophoneUnavailable }
        } else {
            chosen = devices.first { $0.input.id == defaultInput }
        }
        guard let chosen else { throw CaptureError.noInputDevice }
        try InputDevice.validate(sampleRate: chosen.input.sampleRate, channels: chosen.input.channels)
        return chosen.input
    }
}

struct CaptureInputSelection: Equatable, Sendable {
    var device: InputDevice
    var followsDefault: Bool

    static func resolve(preferred: PreferredMicrophone?, priority: MicrophonePriority?, devices: [MicrophoneDevice], defaultInput: AudioDeviceID?) throws -> Self {
        if let priority, priority.enabled {
            for choice in priority.devices {
                if let found = devices.first(where: { $0.uid == choice.uid }) {
                    try InputDevice.validate(sampleRate: found.input.sampleRate, channels: found.input.channels)
                    return Self(device: found.input, followsDefault: false)
                }
            }
            guard priority.fallbackToDefault else { throw CaptureError.selectedMicrophoneUnavailable }
            return Self(device: try PreferredMicrophone.resolve(nil, devices: devices, defaultInput: defaultInput), followsDefault: true)
        }
        return Self(device: try PreferredMicrophone.resolve(preferred, devices: devices, defaultInput: defaultInput), followsDefault: preferred == nil)
    }

    static func current() throws -> Self {
        try resolve(preferred: PreferredMicrophone.load(), priority: MicrophonePriority.load(),
                    devices: InputDevice.availableMicrophones(), defaultInput: InputDevice.defaultInputID())
    }
}

protocol CaptureInputDriving: Sendable {
    func prepare(device: InputDevice, followsDefault: Bool) throws
    func start(device: InputDevice, followsDefault: Bool, sink: InputSink) throws -> InputDevice
    func stop()
}

extension HALInput: CaptureInputDriving {}
