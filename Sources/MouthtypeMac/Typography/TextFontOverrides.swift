import Foundation

enum FontGroup: String, CaseIterable, Sendable {
    case heading, body, readout
    var title: String { rawValue.capitalized }
    init(role: TextRole) {
        switch role {
        case .header, .pillMessage: self = .heading
        case .body, .pillDetail, .button: self = .body
        case .numeric: self = .readout
        }
    }
}

struct TextFontOverrides: Equatable, Sendable {
    static let enabledKey = "textFontOverridesEnabled"
    static let familiesKey = "textFontRoleFamilies"
    var enabled = false
    var families: [FontGroup: String] = [:]

    static func load(_ defaults: UserDefaults = .standard) -> Self {
        let saved = defaults.dictionary(forKey: familiesKey) ?? [:]
        var families: [FontGroup: String] = [:]
        for group in FontGroup.allCases {
            if let family = saved[group.rawValue] as? String, !family.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                families[group] = family
            }
        }
        return Self(enabled: defaults.bool(forKey: enabledKey), families: families)
    }
    static func setEnabled(_ value: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: enabledKey)
        NotificationCenter.default.post(name: Typography.didChange, object: nil)
    }
    static func setFamily(_ family: String?, for group: FontGroup, in defaults: UserDefaults = .standard) {
        var saved = defaults.dictionary(forKey: familiesKey) ?? [:]
        let family = family?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let family, !family.isEmpty { saved[group.rawValue] = family } else { saved.removeValue(forKey: group.rawValue) }
        defaults.set(saved, forKey: familiesKey)
        NotificationCenter.default.post(name: Typography.didChange, object: nil)
    }
    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: enabledKey)
        defaults.removeObject(forKey: familiesKey)
        TextFontPreference.set(.systema, in: defaults)
    }
}
