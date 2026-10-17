import Foundation

enum LivePreviewPreference {
    static let key = "livePreviewEnabled"
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: key) }
    static func set(_ enabled: Bool, in defaults: UserDefaults = .standard) { defaults.set(enabled, forKey: key) }
}
