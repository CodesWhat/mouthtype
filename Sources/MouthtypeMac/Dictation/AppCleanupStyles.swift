import Foundation
import MouthtypeCore

struct AppCleanupStyle: Equatable, Sendable {
    let bundleID: String
    let appName: String
    /// Nil keeps the tone the next rule down (app, then the global default) would give.
    let style: StyleOptions?
    /// Nil keeps the cleanup level the next rule down would give.
    var level: CleanupLevel?
}

struct WebsiteCleanupStyle: Equatable, Sendable {
    let domain: String
    let style: StyleOptions?
    var level: CleanupLevel?
}

struct AppCleanupStyles: Equatable, Sendable {
    static let preferenceKey = "cleanupAppStyles"
    private(set) var entries: [AppCleanupStyle] = []
    private(set) var websites: [WebsiteCleanupStyle] = []

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
    }

    private struct WebsiteRecord: Codable {
        let domain: String
        let capitalisation: String?
        let endingPunctuation: String?
        let cleanupLevel: String?
    }

    /// Both tone fields or neither; a rule that sets nothing at all is never stored.
    private static func decode(capitalisation: String?, ending: String?, level: String?) throws -> (StyleOptions?, CleanupLevel?) {
        var style: StyleOptions?
        switch (capitalisation, ending) {
        case (nil, nil): break
        case let (cap?, end?):
            guard let cap = Capitalisation(rawValue: cap), let end = EndingPunctuation(rawValue: end) else {
                throw ValidationError.invalidPreferences
            }
            style = StyleOptions(capitalisation: cap, endingPunctuation: end)
        default: throw ValidationError.invalidPreferences
        }
        var cleanup: CleanupLevel?
        if let level {
            guard let parsed = CleanupLevel(rawValue: level) else { throw ValidationError.invalidPreferences }
            cleanup = parsed
        }
        guard style != nil || cleanup != nil else { throw ValidationError.invalidPreferences }
        return (style, cleanup)
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
                let (style, level) = try Self.decode(capitalisation: entry.capitalisation, ending: entry.endingPunctuation,
                                                     level: entry.cleanupLevel)
                let bundleID = entry.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !result.entries.contains(where: { $0.bundleID == bundleID }) else {
                    throw ValidationError.invalidPreferences
                }
                try result.set(bundleID: bundleID, appName: entry.appName, style: style, level: level)
            }
            for entry in document.websites ?? [] {
                let (style, level) = try Self.decode(capitalisation: entry.capitalisation, ending: entry.endingPunctuation,
                                                     level: entry.cleanupLevel)
                guard !result.websites.contains(where: { $0.domain == Self.normalizedDomain(entry.domain) }) else {
                    throw ValidationError.invalidPreferences
                }
                try result.setWebsite(domain: entry.domain, style: style, level: level)
            }
            return result
        } catch {
            throw ValidationError.invalidPreferences
        }
    }

    func save(to defaults: UserDefaults = .standard) throws {
        let document = Document(entries: entries.map {
            Record(bundleID: $0.bundleID, appName: $0.appName, capitalisation: $0.style?.capitalisation.rawValue,
                   endingPunctuation: $0.style?.endingPunctuation.rawValue, cleanupLevel: $0.level?.rawValue)
        }, websites: websites.map {
            WebsiteRecord(domain: $0.domain, capitalisation: $0.style?.capitalisation.rawValue,
                          endingPunctuation: $0.style?.endingPunctuation.rawValue, cleanupLevel: $0.level?.rawValue)
        })
        defaults.set(try JSONEncoder().encode(document), forKey: Self.preferenceKey)
    }

    /// A rule that sets neither tone nor level is removed, the same as choosing "Use default" for both.
    mutating func set(bundleID: String, appName: String, style: StyleOptions?, level: CleanupLevel? = nil) throws {
        let bundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard !bundleID.isEmpty, bundleID.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
            !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains)
        }) else { throw ValidationError.invalidBundleID }
        let appName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appName.isEmpty else { throw ValidationError.missingAppName }
        guard style != nil || level != nil else { remove(bundleID: bundleID); return }
        let entry = AppCleanupStyle(bundleID: bundleID, appName: appName, style: style, level: level)
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
        guard domain.utf8.count <= 253, labels.count >= 2, labels.allSatisfy({
            !$0.isEmpty && $0.utf8.count <= 63 && $0.first != "-" && $0.last != "-" && $0.allSatisfy(allowed.contains)
        }) else { return nil }
        return domain
    }

    mutating func setWebsite(domain: String, style: StyleOptions?, level: CleanupLevel? = nil) throws {
        guard let domain = Self.normalizedDomain(domain) else { throw ValidationError.invalidDomain }
        websites.removeAll { $0.domain == domain }
        guard style != nil || level != nil else { return }
        websites.append(WebsiteCleanupStyle(domain: domain, style: style, level: level))
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
        guard let websiteHost, let host = Self.normalizedDomain(websiteHost), WebsiteContext.supports(bundleID: bundleID) else { return nil }
        return websites.filter { host == $0.domain || host.hasSuffix("." + $0.domain) }.max(by: { $0.domain.count < $1.domain.count })
    }

    /// Website rule, then app rule, then the global default; each field falls through on its own.
    func resolve(bundleID: String?, websiteHost: String? = nil, fallback: StyleOptions) -> StyleOptions {
        websiteRule(websiteHost: websiteHost, bundleID: bundleID)?.style
            ?? entries.first { $0.bundleID == bundleID }?.style ?? fallback
    }

    /// Whether any app or website rule sets a level above Off, so cleanup can run for it even when the global level is Off.
    var enablesCleanup: Bool {
        entries.contains { $0.level.map { $0 != .off } ?? false } || websites.contains { $0.level.map { $0 != .off } ?? false }
    }

    /// Nil means no rule sets a level, so the global level stands.
    func resolveLevel(bundleID: String?, websiteHost: String? = nil) -> CleanupLevel? {
        websiteRule(websiteHost: websiteHost, bundleID: bundleID)?.level ?? entries.first { $0.bundleID == bundleID }?.level
    }
}
