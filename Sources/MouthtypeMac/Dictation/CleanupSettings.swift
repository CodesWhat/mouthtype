import Foundation
import MouthtypeCore

/// The Cleanup submenu's switches, kept in UserDefaults. Everything is on and the style is formal by default.
struct CleanupSettings: Equatable, Sendable {
    var enabled = true
    var fillers = true
    var spokenCommands = true
    var numbers = true
    var style = StyleOptions.formal

    enum Key {
        static let enabled = "cleanupEnabled"
        static let fillers = "cleanupFillers"
        static let spokenCommands = "cleanupSpokenCommands"
        static let numbers = "cleanupNumbers"
        static let capitalisation = "cleanupCapitalisation"
        static let endingPunctuation = "cleanupEndingPunctuation"
    }

    static func load(_ defaults: UserDefaults = .standard) -> CleanupSettings {
        func flag(_ key: String) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
        return CleanupSettings(
            enabled: flag(Key.enabled), fillers: flag(Key.fillers), spokenCommands: flag(Key.spokenCommands),
            numbers: flag(Key.numbers),
            style: StyleOptions(
                capitalisation: defaults.string(forKey: Key.capitalisation).flatMap(Capitalisation.init(rawValue:)) ?? .sentence,
                endingPunctuation: defaults.string(forKey: Key.endingPunctuation).flatMap(EndingPunctuation.init(rawValue:)) ?? .keep
            )
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Key.enabled)
        defaults.set(fillers, forKey: Key.fillers)
        defaults.set(spokenCommands, forKey: Key.spokenCommands)
        defaults.set(numbers, forKey: Key.numbers)
        defaults.set(style.capitalisation.rawValue, forKey: Key.capitalisation)
        defaults.set(style.endingPunctuation.rawValue, forKey: Key.endingPunctuation)
    }

    /// What the text pipeline runs. With cleanup off nothing runs at all, style included.
    var pipelineOptions: TextPipelineOptions {
        guard enabled else { return .none }
        return TextPipelineOptions(fillers: fillers, spokenCommands: spokenCommands, numbers: numbers, style: style)
    }

    /// The `style` column value: the preset name, or "custom".
    var styleName: String { style.preset?.rawValue ?? "custom" }
}
