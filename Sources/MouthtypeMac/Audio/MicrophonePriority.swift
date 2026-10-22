import Foundation

struct MicrophonePriority: Codable, Equatable, Sendable {
    static let defaultsKey = "microphone.priority"
    var enabled: Bool
    var devices: [PreferredMicrophone]
    var fallbackToDefault = false

    private func validate() throws {
        guard devices.count <= 32,
            Set(devices.map(\.uid)).count == devices.count,
            devices.allSatisfy({ !$0.uid.isEmpty && !$0.name.isEmpty }),
            !enabled || !devices.isEmpty || fallbackToDefault
        else {
            throw CaptureError.microphonePreferenceUnreadable
        }
    }

    static func load(_ defaults: UserDefaults = .standard) throws -> Self? {
        guard let stored = defaults.object(forKey: defaultsKey) else { return nil }
        guard let data = stored as? Data, let result = try? JSONDecoder().decode(Self.self, from: data) else {
            throw CaptureError.microphonePreferenceUnreadable
        }
        try result.validate()
        return result
    }

    func save(in defaults: UserDefaults = .standard) throws {
        try validate()
        defaults.set(try JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }
}
