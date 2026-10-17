import Foundation
import MouthtypeCore

enum AudioRetentionPreference {
    static let ageKey = "audioRetentionAge"
    static let sizeKey = "audioRetentionSize"

    static func load(_ defaults: UserDefaults = .standard) -> AudioRetentionPolicy {
        AudioRetentionPolicy(
            age: (defaults.object(forKey: ageKey) as? String).flatMap(AudioRetentionAge.init(rawValue:)) ?? .days90,
            size: (defaults.object(forKey: sizeKey) as? String).flatMap(AudioRetentionSize.init(rawValue:)) ?? .gb2
        )
    }

    static func setAge(_ value: AudioRetentionAge, in defaults: UserDefaults = .standard) {
        defaults.set(value.rawValue, forKey: ageKey)
    }

    static func setSize(_ value: AudioRetentionSize, in defaults: UserDefaults = .standard) {
        defaults.set(value.rawValue, forKey: sizeKey)
    }
}
