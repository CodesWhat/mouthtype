import AppKit
import CoreText

/// Where a piece of text sits, so one font setting can hand each place the right face and size.
enum TextRole: CaseIterable, Sendable {
    /// The reason line of a delivery card.
    case header
    /// Card transcript text.
    case body
    /// Card button labels.
    case button
    /// Clocks and countdowns: tabular figures so digits don't jiggle.
    case numeric
    /// The first line of a pill message.
    case pillMessage
    /// The second, quieter line of a pill message.
    case pillDetail
}

enum TextFontChoice: Equatable, Sendable {
    case systema, system, rounded, serif, mono
    case custom(String)

    static let standard: [TextFontChoice] = [.systema, .system, .rounded, .serif, .mono]

    var title: String {
        switch self {
        case .systema: "Systema Set"
        case .system: "System"
        case .rounded: "System Rounded"
        case .serif: "System Serif"
        case .mono: "System Mono"
        case .custom(let family): family
        }
    }
}

enum TextFontPreference {
    static let key = "textFont"
    static let familyKey = "textFontFamily"

    static func current(_ defaults: UserDefaults = .standard) -> TextFontChoice {
        switch defaults.string(forKey: key) {
        case "system": .system
        case "rounded": .rounded
        case "serif": .serif
        case "mono": .mono
        case "custom":
            defaults.string(forKey: familyKey).flatMap { $0.isEmpty ? nil : TextFontChoice.custom($0) } ?? .systema
        default: .systema
        }
    }

    static func set(_ choice: TextFontChoice, in defaults: UserDefaults = .standard) {
        switch choice {
        case .systema: defaults.set("systema", forKey: key)
        case .system: defaults.set("system", forKey: key)
        case .rounded: defaults.set("rounded", forKey: key)
        case .serif: defaults.set("serif", forKey: key)
        case .mono: defaults.set("mono", forKey: key)
        case .custom(let family):
            defaults.set("custom", forKey: key)
            defaults.set(family, forKey: familyKey)
        }
        NotificationCenter.default.post(name: Typography.didChange, object: nil)
    }
}

/// Hands out fonts by role for the chosen text font. The hi-fi skin's bitmap readouts don't use it.
struct Typography: Sendable {
    /// Posted on the main thread when the text font setting changes, so what is on screen can re-lay-out.
    static let didChange = Notification.Name("MouthtypeTextFontDidChange")

    let choice: TextFontChoice
    /// Whether a family is present, injectable so a missing family is testable.
    var isInstalled: @Sendable (String) -> Bool = { NSFontManager.shared.availableFontFamilies.contains($0) }

    init(choice: TextFontChoice, isInstalled: (@Sendable (String) -> Bool)? = nil) {
        self.choice = choice
        if let isInstalled { self.isInstalled = isInstalled }
    }

    static func current(_ defaults: UserDefaults = .standard) -> Typography {
        Typography(choice: TextFontPreference.current(defaults))
    }

    /// The choice actually in force: a custom family that isn't installed, or a Systema set whose files didn't
    /// register, resolves to System.
    var effectiveChoice: TextFontChoice {
        switch choice {
        case .custom(let family): isInstalled(family) ? choice : .system
        case .systema: Self.systemaAvailable ? .systema : .system
        default: choice
        }
    }

    static var systemaAvailable: Bool {
        NSFont(name: FontRegistry.serifName, size: 12) != nil && NSFont(name: FontRegistry.monoName, size: 12) != nil
            && FontRegistry.sansNames.allSatisfy { NSFont(name: $0, size: 12) != nil }
    }

    private struct Spec {
        var size: CGFloat
        var weight: NSFont.Weight
    }

    private static func spec(_ role: TextRole, systema: Bool) -> Spec {
        switch role {
        case .header: Spec(size: systema ? 15 : 12, weight: .semibold)
        case .body: Spec(size: 13, weight: .regular)
        case .button: Spec(size: 12, weight: .semibold)
        case .numeric: Spec(size: 11, weight: .medium)
        case .pillMessage: Spec(size: systema ? 14 : 12, weight: .medium)
        case .pillDetail: Spec(size: systema ? 11 : 11, weight: .regular)
        }
    }

    func font(_ role: TextRole) -> NSFont {
        let effective = effectiveChoice
        let spec = Self.spec(role, systema: effective == .systema)
        let base: NSFont
        switch effective {
        case .systema: base = Self.systema(role, spec)
        case .system: base = .systemFont(ofSize: spec.size, weight: spec.weight)
        case .rounded: base = Self.design(.rounded, spec)
        case .serif: base = Self.design(.serif, spec)
        case .mono: base = .monospacedSystemFont(ofSize: spec.size, weight: spec.weight)
        case .custom(let family): base = Self.family(family, spec)
        }
        return role == .numeric ? Self.tabular(base) : base
    }

    private static func systema(_ role: TextRole, _ spec: Spec) -> NSFont {
        let name: String
        switch role {
        case .header, .pillMessage: name = FontRegistry.serifName
        case .numeric: name = FontRegistry.monoName
        case .button: name = "InstrumentSans-SemiBold"
        case .body, .pillDetail: name = "InstrumentSans-Regular"
        }
        return NSFont(name: name, size: spec.size) ?? .systemFont(ofSize: spec.size, weight: spec.weight)
    }

    private static func design(_ design: NSFontDescriptor.SystemDesign, _ spec: Spec) -> NSFont {
        let base = NSFont.systemFont(ofSize: spec.size, weight: spec.weight)
        guard let descriptor = base.fontDescriptor.withDesign(design), let font = NSFont(descriptor: descriptor, size: spec.size) else {
            return base
        }
        return font
    }

    private static func family(_ family: String, _ spec: Spec) -> NSFont {
        let manager = NSFontManager.shared
        let weight: Int = switch spec.weight {
        case .semibold: 8
        case .medium: 6
        default: 5
        }
        return manager.font(withFamily: family, traits: [], weight: weight, size: spec.size)
            ?? .systemFont(ofSize: spec.size, weight: spec.weight)
    }

    /// The same font with proportional digits turned off.
    static func tabular(_ font: NSFont) -> NSFont {
        let features: [[NSFontDescriptor.FeatureKey: Int]] = [[
            .typeIdentifier: kNumberSpacingType, .selectorIdentifier: kMonospacedNumbersSelector,
        ]]
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: features])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    /// Height of one line in `font`, whole points.
    static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }
}
