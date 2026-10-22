import Foundation
import MouthtypeCore

struct AppCleanupStyle: Equatable, Sendable {
    let bundleID: String
    let appName: String
    /// Nil keeps the tone the next rule down (app, then the global default) would give.
    let style: StyleOptions?
    /// Nil keeps the cleanup level the next rule down would give.
    var level: CleanupLevel?
    /// Tone and formatting instructions for Thorough cleanup in this app. Nil keeps the next rule down's (then the global ones).
    var instructions: String?
}

struct WebsiteCleanupStyle: Equatable, Sendable {
    let domain: String
    let style: StyleOptions?
    var level: CleanupLevel?
    var instructions: String?
}

struct AppCleanupStyles: Equatable, Sendable {
    static let preferenceKey = "cleanupAppStyles"
    private(set) var entries: [AppCleanupStyle] = []
    private(set) var websites: [WebsiteCleanupStyle] = []
    /// The Style page's contexts: Personal, Work, Email and Other, with their built-in apps and websites. The explicit app and website
    /// rules above are kept exactly as stored and always win over a context.
    var contexts = StyleContexts()

    enum ValidationError: LocalizedError {
        case invalidBundleID, missingAppName, invalidPreferences, invalidDomain

        var errorDescription: String? {
            switch self {
            case .invalidDomain: "Enter a domain such as slack.com, without a scheme, path or wildcard."
            case .invalidBundleID: "Choose an application with a valid bundle identifier."
            case .missingAppName: "The application needs a name."
            case .invalidPreferences: "Saved app styles couldn't be read. Existing preferences have been kept."
            }
        }
    }

    private struct Record: Codable {
        let bundleID: String
        let appName: String
        let capitalisation: String?
        let endingPunctuation: String?
        /// Absent in rules saved before cleanup levels existed.
        let cleanupLevel: String?
        /// Absent in rules saved before the Excited tone existed, and in every tone but Excited.
        let excited: Bool?
        /// Absent in rules saved before instructions existed, and when the rule has none.
        let instructions: String?
    }

    private struct WebsiteRecord: Codable {
        let domain: String
        let capitalisation: String?
        let endingPunctuation: String?
        let cleanupLevel: String?
        let excited: Bool?
        let instructions: String?
    }

    /// Both tone fields or neither; a rule that sets nothing at all is never stored.
    private static func decode(
        capitalisation: String?, ending: String?, level: String?, excited: Bool?, instructions: String?
    ) throws -> (StyleOptions?, CleanupLevel?, String?) {
        var style: StyleOptions?
        switch (capitalisation, ending) {
        case (nil, nil):
            guard excited != true else { throw ValidationError.invalidPreferences }
        case let (cap?, end?):
            guard let cap = Capitalisation(rawValue: cap), let end = EndingPunctuation(rawValue: end) else {
                throw ValidationError.invalidPreferences
            }
            style = StyleOptions(capitalisation: cap, endingPunctuation: end, excited: excited ?? false)
        default: throw ValidationError.invalidPreferences
        }
        var cleanup: CleanupLevel?
        if let level {
            guard let parsed = CleanupLevel(rawValue: level) else { throw ValidationError.invalidPreferences }
            cleanup = parsed
        }
        let notes = CleanupInstructions.normalize(instructions)
        guard style != nil || cleanup != nil || notes != nil else { throw ValidationError.invalidPreferences }
        return (style, cleanup, notes)
    }

    private struct Document: Codable {
        var version = 1
        let entries: [Record]
        var websites: [WebsiteRecord]?
    }

    static func load(_ defaults: UserDefaults = .standard) throws -> AppCleanupStyles {
        guard let stored = defaults.object(forKey: preferenceKey) else { return AppCleanupStyles() }
        guard let data = stored as? Data else { throw ValidationError.invalidPreferences }
        do {
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1 else { throw ValidationError.invalidPreferences }
            var result = AppCleanupStyles()
            for entry in document.entries {
                let (style, level, instructions) = try Self.decode(
                    capitalisation: entry.capitalisation, ending: entry.endingPunctuation,
                    level: entry.cleanupLevel, excited: entry.excited, instructions: entry.instructions)
                let bundleID = entry.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !result.entries.contains(where: { $0.bundleID == bundleID }) else {
                    throw ValidationError.invalidPreferences
                }
                try result.set(bundleID: bundleID, appName: entry.appName, style: style, level: level, instructions: instructions)
            }
            for entry in document.websites ?? [] {
                let (style, level, instructions) = try Self.decode(
                    capitalisation: entry.capitalisation, ending: entry.endingPunctuation,
                    level: entry.cleanupLevel, excited: entry.excited, instructions: entry.instructions)
                guard !result.websites.contains(where: { $0.domain == Self.normalizedDomain(entry.domain) }) else {
                    throw ValidationError.invalidPreferences
                }
                try result.setWebsite(domain: entry.domain, style: style, level: level, instructions: instructions)
            }
            result.contexts = StyleContexts.load(defaults)
            return result
        } catch {
            throw ValidationError.invalidPreferences
        }
    }

    func save(to defaults: UserDefaults = .standard) throws {
        let document = Document(
            entries: entries.map {
                Record(
                    bundleID: $0.bundleID, appName: $0.appName, capitalisation: $0.style?.capitalisation.rawValue,
                    endingPunctuation: $0.style?.endingPunctuation.rawValue, cleanupLevel: $0.level?.rawValue,
                    excited: $0.style?.excited == true ? true : nil, instructions: $0.instructions)
            },
            websites: websites.map {
                WebsiteRecord(
                    domain: $0.domain, capitalisation: $0.style?.capitalisation.rawValue,
                    endingPunctuation: $0.style?.endingPunctuation.rawValue, cleanupLevel: $0.level?.rawValue,
                    excited: $0.style?.excited == true ? true : nil, instructions: $0.instructions)
            })
        defaults.set(try JSONEncoder().encode(document), forKey: Self.preferenceKey)
        try contexts.save(to: defaults)
    }

    /// A rule that sets none of tone, level and instructions is removed, the same as choosing "Use default" for all of them.
    mutating func set(
        bundleID: String, appName: String, style: StyleOptions?, level: CleanupLevel? = nil, instructions: String? = nil
    ) throws {
        let bundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard !bundleID.isEmpty,
            bundleID.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
                !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains)
            })
        else { throw ValidationError.invalidBundleID }
        let appName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appName.isEmpty else { throw ValidationError.missingAppName }
        let instructions = CleanupInstructions.normalize(instructions)
        guard style != nil || level != nil || instructions != nil else { remove(bundleID: bundleID); return }
        let entry = AppCleanupStyle(bundleID: bundleID, appName: appName, style: style, level: level, instructions: instructions)
        if let index = entries.firstIndex(where: { $0.bundleID == bundleID }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        entries.sort {
            let comparison = $0.appName.localizedStandardCompare($1.appName)
            return comparison == .orderedSame ? $0.bundleID < $1.bundleID : comparison == .orderedAscending
        }
    }

    mutating func remove(bundleID: String) {
        entries.removeAll { $0.bundleID == bundleID }
    }

    static func normalizedDomain(_ input: String) -> String? {
        var domain = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if domain.hasSuffix(".") { domain.removeLast() }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        guard domain.utf8.count <= 253, labels.count >= 2,
            labels.allSatisfy({
                !$0.isEmpty && $0.utf8.count <= 63 && $0.first != "-" && $0.last != "-" && $0.allSatisfy(allowed.contains)
            })
        else { return nil }
        return domain
    }

    mutating func setWebsite(domain: String, style: StyleOptions?, level: CleanupLevel? = nil, instructions: String? = nil) throws {
        guard let domain = Self.normalizedDomain(domain) else { throw ValidationError.invalidDomain }
        websites.removeAll { $0.domain == domain }
        let instructions = CleanupInstructions.normalize(instructions)
        guard style != nil || level != nil || instructions != nil else { return }
        websites.append(WebsiteCleanupStyle(domain: domain, style: style, level: level, instructions: instructions))
        websites.sort { $0.domain < $1.domain }
    }

    mutating func removeWebsite(domain: String) {
        websites.removeAll { $0.domain == Self.normalizedDomain(domain) }
    }

    /// The rule saved for exactly this domain, if any.
    func websiteRule(domain: String) -> WebsiteCleanupStyle? {
        Self.normalizedDomain(domain).flatMap { host in websites.first { $0.domain == host } }
    }

    private func websiteRule(websiteHost: String?, bundleID: String?) -> WebsiteCleanupStyle? {
        guard let host = supportedHost(websiteHost, bundleID: bundleID) else { return nil }
        return websites.filter { host == $0.domain || host.hasSuffix("." + $0.domain) }.max(by: { $0.domain.count < $1.domain.count })
    }

    private func supportedHost(_ websiteHost: String?, bundleID: String?) -> String? {
        guard let websiteHost, let host = Self.normalizedDomain(websiteHost), WebsiteContext.supports(bundleID: bundleID) else { return nil }
        return host
    }

    /// Whether a website can change the result: an explicit website rule, or a site listed in a context.
    var hasWebsiteRules: Bool {
        !websites.isEmpty || StyleContextID.allCases.contains { contexts.members($0).contains { $0.kind == .site } }
    }

    /// The tone and cleanup level one rule or context contributes. A nil field falls through to the next layer.
    private struct Layer {
        let style: StyleOptions?
        let level: CleanupLevel?
        var instructions: String?
    }

    /// What you configured always beats a built-in default. In order: your website rules (the longest matching domain only, so a
    /// parent domain never fills its fields in), your app rule, then the contexts' lists (a listed site, then a listed app, whether
    /// built in or added), then Other, which only carries a cleanup level and only for what no list claims. Each field falls through
    /// on its own, so with no contexts set up this is the original website-then-app resolution.
    private func layers(bundleID: String?, websiteHost: String?) -> [Layer] {
        var result: [Layer] = []
        var hasListedSite = false
        let host = supportedHost(websiteHost, bundleID: bundleID)
        if let host, let rule = websiteRule(websiteHost: host, bundleID: bundleID) { result.append(Layer(style: rule.style, level: rule.level, instructions: rule.instructions)) }
        if let rule = entries.first(where: { $0.bundleID == bundleID }) {
            result.append(Layer(style: rule.style, level: rule.level, instructions: rule.instructions))
        }
        if let host, let match = contexts.siteMatch(host: host) {
            hasListedSite = true
            result.append(Layer(style: contexts.tone(match.context)?.options, level: contexts.level(match.context)))
        }
        if let id = contexts.context(bundleID: bundleID) {
            result.append(Layer(style: contexts.tone(id)?.options, level: contexts.level(id)))
        } else if !hasListedSite {
            result.append(Layer(style: nil, level: contexts.level(.other)))
        }
        return result
    }

    /// Your website rule, your app rule, a context's site, a context's app, then the global default.
    func resolve(bundleID: String?, websiteHost: String? = nil, fallback: StyleOptions) -> StyleOptions {
        layers(bundleID: bundleID, websiteHost: websiteHost).lazy.compactMap(\.style).first ?? fallback
    }

    /// Whether any rule or context sets a level above Off, so cleanup can run for it even when the global level is Off.
    var enablesCleanup: Bool {
        entries.contains { $0.level.map { $0 != .off } ?? false } || websites.contains { $0.level.map { $0 != .off } ?? false }
            || contexts.overridingLevels.contains { $0.level != .off }
    }

    /// Nil means nothing sets a level, so the global level stands.
    func resolveLevel(bundleID: String?, websiteHost: String? = nil) -> CleanupLevel? {
        layers(bundleID: bundleID, websiteHost: websiteHost).lazy.compactMap(\.level).first
    }

    /// Your website rule's instructions, else your app rule's. Nil means neither sets any, so the global instructions stand.
    /// Contexts carry a tone and a level but no instructions.
    func resolveInstructions(bundleID: String?, websiteHost: String? = nil) -> String? {
        layers(bundleID: bundleID, websiteHost: websiteHost).lazy.compactMap(\.instructions).first
    }

    /// The instructions saved on exactly this app's rule, if any.
    func instructions(bundleID: String) -> String? { entries.first { $0.bundleID == bundleID }?.instructions }
}
