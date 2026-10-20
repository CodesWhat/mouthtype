import Foundation
import MouthtypeCore

/// The four kinds of writing the Style page sorts apps and websites into. A context is a tone plus an optional cleanup level
/// applied to its member apps and sites. Personal, Work and Email have member lists; Other has none and means everything
/// not listed elsewhere, so its tone is the default tone and its level is the only thing it stores.
enum StyleContextID: String, CaseIterable, Sendable, Codable {
    case personal, work, email, other

    var title: String {
        switch self {
        case .personal: "Personal messages"
        case .work: "Work messages"
        case .email: "Email"
        case .other: "Other"
        }
    }

    /// The word used in "Counts as ..." and in accessibility labels.
    var noun: String {
        switch self {
        case .personal: "personal"
        case .work: "work"
        case .email: "email"
        case .other: "other"
        }
    }

    /// The tone a context starts with. Other has none of its own: it follows the default tone.
    var builtInTone: StylePreset? {
        switch self {
        case .personal, .work: .casual
        case .email: .formal
        case .other: nil
        }
    }

    var hasList: Bool { self != .other }
}

/// An app or website that counts as a context.
struct StyleMember: Equatable, Hashable, Sendable, Identifiable {
    enum Kind: Hashable, Sendable { case app, site }

    let kind: Kind
    /// App display name, or the domain for a website.
    let name: String
    /// Every bundle identifier the app ships under (an app can have a classic and a new build), or the domain.
    let keys: [String]
    let isBuiltIn: Bool

    var id: String { (kind == .app ? "app:" : "site:") + (keys.first ?? name) }
}

/// What a user changed about one context.
struct StyleContextConfig: Codable, Equatable, Sendable {
    /// A `StylePreset` raw value; nil keeps the built-in tone.
    var tone: String?
    /// A `CleanupLevel` raw value; nil is "Same as everywhere".
    var level: String?
    /// Member ids (`StyleMember.id`) of built-ins the user took out of this context.
    var removed: [String] = []
    var apps: [AddedApp] = []
    var sites: [String] = []

    struct AddedApp: Codable, Equatable, Sendable {
        let bundleID: String
        let appName: String
    }

    var isDefault: Bool { self == StyleContextConfig() }
}

struct StyleContexts: Equatable, Sendable {
    static let preferenceKey = "styleContexts"

    private(set) var configs: [StyleContextID: StyleContextConfig] = [:]

    // MARK: Built-ins

    static func builtIns(_ id: StyleContextID) -> [StyleMember] {
        func app(_ name: String, _ ids: String...) -> StyleMember { StyleMember(kind: .app, name: name, keys: ids, isBuiltIn: true) }
        func site(_ domain: String) -> StyleMember { StyleMember(kind: .site, name: domain, keys: [domain], isBuiltIn: true) }
        switch id {
        case .personal:
            return [app("Messages", "com.apple.MobileSMS"), app("WhatsApp", "net.whatsapp.WhatsApp"),
                    app("Telegram", "ru.keepcoder.Telegram", "org.telegram.desktop"), app("Discord", "com.hnc.Discord"),
                    app("Signal", "org.whispersystems.signal-desktop")]
        case .work:
            return [app("Slack", "com.tinyspeck.slackmacgap"), app("Microsoft Teams", "com.microsoft.teams2", "com.microsoft.teams"),
                    site("linkedin.com"), site("teams.microsoft.com")]
        case .email:
            return [app("Mail", "com.apple.mail"), app("Outlook", "com.microsoft.Outlook"),
                    site("mail.google.com"), site("outlook.office.com")]
        case .other:
            return []
        }
    }

    // MARK: Settings

    func config(_ id: StyleContextID) -> StyleContextConfig { configs[id] ?? StyleContextConfig() }

    var isDefault: Bool { configs.values.allSatisfy(\.isDefault) }

    /// The preset set for a context, or its built-in one. Other has none, so its tone is the default tone.
    func tone(_ id: StyleContextID) -> StylePreset? {
        config(id).tone.flatMap(StylePreset.init(rawValue:)) ?? id.builtInTone
    }

    /// Nil is "Same as everywhere".
    func level(_ id: StyleContextID) -> CleanupLevel? { config(id).level.flatMap(CleanupLevel.init(rawValue:)) }

    var overridingLevels: [(context: StyleContextID, level: CleanupLevel)] {
        StyleContextID.allCases.compactMap { id in level(id).map { (id, $0) } }
    }

    mutating func setTone(_ id: StyleContextID, _ tone: StylePreset?) {
        guard id.hasList else { return }
        update(id) { $0.tone = tone.flatMap { $0 == id.builtInTone ? nil : $0.rawValue } }
    }

    mutating func setLevel(_ id: StyleContextID, _ level: CleanupLevel?) {
        update(id) { $0.level = level?.rawValue }
    }

    private mutating func update(_ id: StyleContextID, _ change: (inout StyleContextConfig) -> Void) {
        var config = config(id)
        change(&config)
        configs[id] = config.isDefault ? nil : config
    }

    // MARK: Members

    /// Built-ins the user hasn't removed, then the apps and sites they added.
    func members(_ id: StyleContextID) -> [StyleMember] {
        guard id.hasList else { return [] }
        let config = config(id)
        let builtIn = Self.builtIns(id).filter { !config.removed.contains($0.id) }
        let apps = config.apps.map { StyleMember(kind: .app, name: $0.appName, keys: [$0.bundleID], isBuiltIn: false) }
        let sites = config.sites.map { StyleMember(kind: .site, name: $0, keys: [$0], isBuiltIn: false) }
        return builtIn + apps + sites
    }

    /// The context an app counts as, or nil when it is unlisted (and so Other). An app the user added beats a built-in.
    func context(bundleID: String?) -> StyleContextID? {
        guard let bundleID else { return nil }
        let listed = StyleContextID.allCases.filter(\.hasList)
        for id in listed where config(id).apps.contains(where: { $0.bundleID == bundleID }) { return id }
        for id in listed where members(id).contains(where: { $0.isBuiltIn && $0.kind == .app && $0.keys.contains(bundleID) }) { return id }
        return nil
    }

    /// The context a website host counts as: the longest matching domain, a user-added one winning a tie.
    func context(host: String?) -> StyleContextID? { siteMatch(host: host)?.context }

    func siteMatch(host: String?) -> (context: StyleContextID, length: Int, isBuiltIn: Bool)? {
        guard let host = host.flatMap(AppCleanupStyles.normalizedDomain) else { return nil }
        var best: (context: StyleContextID, length: Int, isBuiltIn: Bool)?
        for id in StyleContextID.allCases where id.hasList {
            for member in members(id) where member.kind == .site {
                guard let domain = member.keys.first, host == domain || host.hasSuffix("." + domain) else { continue }
                if let current = best, current.length > domain.count || (current.length == domain.count && !current.isBuiltIn) { continue }
                best = (id, domain.count, member.isBuiltIn)
            }
        }
        return best
    }

    /// Adds an app to a context. An app counts as one context at a time, so it leaves any other context first.
    mutating func addApp(_ id: StyleContextID, bundleID: String, appName: String) {
        guard id.hasList else { return }
        detachApp(bundleID: bundleID)
        let builtIn = Self.builtIns(id).first { $0.kind == .app && $0.keys.contains(bundleID) }
        update(id) { config in
            if let builtIn { config.removed.removeAll { $0 == builtIn.id } } else {
                config.apps.append(.init(bundleID: bundleID, appName: appName))
            }
        }
    }

    /// Adds a website to a context, leaving any other context it was in. Returns false for a malformed domain.
    @discardableResult
    mutating func addSite(_ id: StyleContextID, domain: String) -> Bool {
        guard id.hasList, let domain = AppCleanupStyles.normalizedDomain(domain) else { return false }
        detachSite(domain: domain)
        let builtIn = Self.builtIns(id).first { $0.kind == .site && $0.keys.first == domain }
        update(id) { config in
            if let builtIn { config.removed.removeAll { $0 == builtIn.id } } else { config.sites.append(domain) }
        }
        return true
    }

    mutating func remove(_ member: StyleMember, from id: StyleContextID) {
        update(id) { config in
            if member.isBuiltIn {
                if !config.removed.contains(member.id) { config.removed.append(member.id) }
            } else {
                config.apps.removeAll { member.keys.contains($0.bundleID) }
                config.sites.removeAll { member.keys.contains($0) }
            }
        }
    }

    private mutating func detachApp(bundleID: String) {
        for id in StyleContextID.allCases where id.hasList {
            update(id) { config in
                config.apps.removeAll { $0.bundleID == bundleID }
                for built in Self.builtIns(id) where built.kind == .app && built.keys.contains(bundleID) && !config.removed.contains(built.id) {
                    config.removed.append(built.id)
                }
            }
        }
    }

    private mutating func detachSite(domain: String) {
        for id in StyleContextID.allCases where id.hasList {
            update(id) { config in
                config.sites.removeAll { $0 == domain }
                for built in Self.builtIns(id) where built.kind == .site && built.keys.first == domain && !config.removed.contains(built.id) {
                    config.removed.append(built.id)
                }
            }
        }
    }

    // MARK: Storage

    private struct Document: Codable {
        var version = 1
        var contexts: [String: StyleContextConfig]
    }

    /// Unreadable data falls back to the built-in contexts rather than blocking dictation.
    static func load(_ defaults: UserDefaults = .standard) -> StyleContexts {
        guard let data = defaults.data(forKey: preferenceKey),
              let document = try? JSONDecoder().decode(Document.self, from: data), document.version == 1 else { return StyleContexts() }
        var result = StyleContexts()
        for (key, config) in document.contexts {
            if let id = StyleContextID(rawValue: key), !config.isDefault { result.configs[id] = config }
        }
        return result
    }

    func save(to defaults: UserDefaults = .standard) throws {
        guard !isDefault else { defaults.removeObject(forKey: Self.preferenceKey); return }
        let document = Document(contexts: Dictionary(uniqueKeysWithValues: configs.map { ($0.key.rawValue, $0.value) }))
        defaults.set(try JSONEncoder().encode(document), forKey: Self.preferenceKey)
    }
}
