import Foundation
import MouthtypeCore

enum RecordingModePreference {
    private static let key = "recordingMode"

    static func current(_ defaults: UserDefaults = .standard) -> RecordingMode {
        guard let value = defaults.string(forKey: key), let mode = RecordingMode(rawValue: value) else { return .hold }
        return mode
    }

    static func set(_ value: RecordingMode, in defaults: UserDefaults = .standard) {
        defaults.set(value.rawValue, forKey: key)
    }
}
