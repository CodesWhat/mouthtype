import Foundation
import MouthtypeCore

/// The Cleanup submenu's switches, kept in UserDefaults. The level is Fast, every stage is on and the style is
/// formal by default. Fast and Thorough need their selected model; without it the app runs as Basic.
struct CleanupSettings: Equatable, Sendable {
    var level = CleanupLevel.light
    var fillers = true
    var spokenCommands = true
    /// "slash research" becomes "/research" in coding targets. Absent means on.
    var slashCommands = true
    var numbers = true
    var style = StyleOptions.formal
    /// Your own tone and formatting instructions for Thorough cleanup, for every app and site no rule of its own covers. Empty means none.
    var instructions = ""

    var enabled: Bool { level != .off }

    enum Key {
        static let level = "cleanupLevel"
        /// The master switch before levels existed. Read once so an old "off" is kept.
        static let legacyEnabled = "cleanupEnabled"
        static let fillers = "cleanupFillers"
        static let spokenCommands = "cleanupSpokenCommands"
        static let numbers = "cleanupNumbers"
        static let slashCommands = "cleanupSlashCommands"
        static let capitalisation = "cleanupCapitalisation"
        static let endingPunctuation = "cleanupEndingPunctuation"
        /// Absent means off.
        static let excited = "cleanupExcited"
        static let instructions = "cleanupInstructions"
    }

    static func load(_ defaults: UserDefaults = .standard) -> CleanupSettings {
        func flag(_ key: String) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
        let stored = defaults.string(forKey: Key.level).flatMap(CleanupLevel.init(rawValue:))
        let legacyOff = defaults.object(forKey: Key.legacyEnabled) as? Bool == false
        return CleanupSettings(
            level: stored ?? (legacyOff ? .off : .light), fillers: flag(Key.fillers), spokenCommands: flag(Key.spokenCommands),
            slashCommands: flag(Key.slashCommands), numbers: flag(Key.numbers),
            style: StyleOptions(
                capitalisation: defaults.string(forKey: Key.capitalisation).flatMap(Capitalisation.init(rawValue:)) ?? .sentence,
                endingPunctuation: defaults.string(forKey: Key.endingPunctuation).flatMap(EndingPunctuation.init(rawValue:)) ?? .keep,
                excited: defaults.object(forKey: Key.excited) as? Bool ?? false
            ),
            instructions: CleanupInstructions.normalize(defaults.string(forKey: Key.instructions)) ?? ""
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(level.rawValue, forKey: Key.level)
        defaults.set(fillers, forKey: Key.fillers)
        defaults.set(spokenCommands, forKey: Key.spokenCommands)
        defaults.set(numbers, forKey: Key.numbers)
        defaults.set(slashCommands, forKey: Key.slashCommands)
        defaults.set(style.capitalisation.rawValue, forKey: Key.capitalisation)
        defaults.set(style.endingPunctuation.rawValue, forKey: Key.endingPunctuation)
        defaults.set(style.excited, forKey: Key.excited)
        if let instructions = CleanupInstructions.normalize(instructions) {
            defaults.set(instructions, forKey: Key.instructions)
        } else {
            defaults.removeObject(forKey: Key.instructions)
        }
    }

    /// What the text pipeline runs. With cleanup off nothing runs at all, style included.
    var pipelineOptions: TextPipelineOptions {
        guard enabled else { return .none }
        return TextPipelineOptions(
            fillers: fillers, spokenCommands: spokenCommands, slashCommands: slashCommands,
            countedLists: spokenCommands, numbers: numbers, style: style)
    }

    /// The `style` column value: the preset name, or "custom".
    var styleName: String { style.preset?.rawValue ?? "custom" }
}
