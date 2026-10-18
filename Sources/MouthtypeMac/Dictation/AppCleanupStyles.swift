import Foundation
import MouthtypeCore

struct AppCleanupStyle: Equatable, Sendable {
    let bundleID: String
    let appName: String
    let style: StyleOptions
}

struct WebsiteCleanupStyle: Equatable, Sendable {
    let domain: String
    let style: StyleOptions
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
        let capitalisation: String
        let endingPunctuation: String
    }

    private struct WebsiteRecord: Codable {
        let domain: String
        let capitalisation: String
        let endingPunctuation: String
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
                guard let capitalisation = Capitalisation(rawValue: entry.capitalisation),
                      let ending = EndingPunctuation(rawValue: entry.endingPunctuation) else {
                    throw ValidationError.invalidPreferences
                }
                let bundleID = entry.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !result.entries.contains(where: { $0.bundleID == bundleID }) else {
                    throw ValidationError.invalidPreferences
                }
                try result.set(bundleID: bundleID, appName: entry.appName,
                               style: StyleOptions(capitalisation: capitalisation, endingPunctuation: ending))
            }
            for entry in document.websites ?? [] {
                guard let capitalisation = Capitalisation(rawValue: entry.capitalisation),
                      let ending = EndingPunctuation(rawValue: entry.endingPunctuation),
                      !result.websites.contains(where: { $0.domain == Self.normalizedDomain(entry.domain) }) else {
                    throw ValidationError.invalidPreferences
                }
                try result.setWebsite(domain: entry.domain, style: StyleOptions(capitalisation: capitalisation, endingPunctuation: ending))
            }
            return result
        } catch {
            throw ValidationError.invalidPreferences
        }
    }

    func save(to defaults: UserDefaults = .standard) throws {
        let document = Document(entries: entries.map {
            Record(bundleID: $0.bundleID, appName: $0.appName, capitalisation: $0.style.capitalisation.rawValue,
                   endingPunctuation: $0.style.endingPunctuation.rawValue)
        }, websites: websites.map {
            WebsiteRecord(domain: $0.domain, capitalisation: $0.style.capitalisation.rawValue, endingPunctuation: $0.style.endingPunctuation.rawValue)
        })
        defaults.set(try JSONEncoder().encode(document), forKey: Self.preferenceKey)
    }

    mutating func set(bundleID: String, appName: String, style: StyleOptions) throws {
        let bundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard !bundleID.isEmpty, bundleID.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
            !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains)
        }) else { throw ValidationError.invalidBundleID }
        let appName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appName.isEmpty else { throw ValidationError.missingAppName }
        let entry = AppCleanupStyle(bundleID: bundleID, appName: appName, style: style)
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

    mutating func setWebsite(domain: String, style: StyleOptions) throws {
        guard let domain = Self.normalizedDomain(domain) else { throw ValidationError.invalidDomain }
        websites.removeAll { $0.domain == domain }
        websites.append(WebsiteCleanupStyle(domain: domain, style: style))
        websites.sort { $0.domain < $1.domain }
    }

    mutating func removeWebsite(domain: String) {
        websites.removeAll { $0.domain == Self.normalizedDomain(domain) }
    }

    func resolve(bundleID: String?, websiteHost: String? = nil, fallback: StyleOptions) -> StyleOptions {
        if let websiteHost, let host = Self.normalizedDomain(websiteHost), WebsiteContext.supports(bundleID: bundleID),
           let match = websites.filter({ host == $0.domain || host.hasSuffix("." + $0.domain) }).max(by: { $0.domain.count < $1.domain.count }) {
            return match.style
        }
        return entries.first { $0.bundleID == bundleID }?.style ?? fallback
    }
}
