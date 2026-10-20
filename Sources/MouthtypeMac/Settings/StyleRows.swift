import Foundation
import MouthtypeCore

/// What each Style tab lists under "Counts as ...". Contexts hold built-in and added members; rules you made before contexts existed
/// (the per-app and per-website rules) stay as explicit overrides that win, and show here as ADDED BY YOU under the context whose
/// tone they match.
enum StyleRows {
    struct Row: Identifiable, Equatable {
        let member: StyleMember
        /// A rule you made on its own, not a context member.
        let ownRule: Bool
        /// Tone your own rule sets for this app or site, if any.
        let ruleStyle: StyleOptions?
        /// Cleanup level your own rule sets for this app or site, if any.
        let ruleLevel: CleanupLevel?
        var id: String { member.id }
        var isBuiltIn: Bool { member.isBuiltIn && !ownRule }
    }

    /// A rule no context claims: it sets only a cleanup level, or a tone no listed context uses.
    struct OwnRule: Identifiable, Equatable {
        let member: StyleMember
        let style: StyleOptions?
        let level: CleanupLevel?
        var id: String { member.id }
    }

    private static let listed = StyleContextID.allCases.filter(\.hasList)

    private static func appRule(_ member: StyleMember, in styles: AppCleanupStyles) -> AppCleanupStyle? {
        styles.entries.first { member.keys.contains($0.bundleID) }
    }

    private static func siteRule(_ member: StyleMember, in styles: AppCleanupStyles) -> WebsiteCleanupStyle? {
        member.keys.first.flatMap(styles.websiteRule(domain:))
    }

    private static func ruleStyle(_ member: StyleMember, in styles: AppCleanupStyles) -> StyleOptions? {
        member.kind == .app ? appRule(member, in: styles)?.style : siteRule(member, in: styles)?.style
    }

    private static func ruleLevel(_ member: StyleMember, in styles: AppCleanupStyles) -> CleanupLevel? {
        member.kind == .app ? appRule(member, in: styles)?.level : siteRule(member, in: styles)?.level
    }

    /// The context that lists an explicit tone rule: the one the app or site is a member of when the tones agree, otherwise the first
    /// listed context using that tone. Nil when none does.
    static func claim(_ member: StyleMember, style: StyleOptions, in styles: AppCleanupStyles) -> StyleContextID? {
        let contexts = styles.contexts
        let home = member.kind == .app ? contexts.context(bundleID: member.keys.first) : contexts.context(host: member.keys.first)
        if let home, contexts.tone(home)?.options == style { return home }
        return listed.first { contexts.tone($0)?.options == style }
    }

    /// Whether some context lists exactly this app or site, so that row can carry the rule. A parent domain doesn't count: a rule on
    /// jobs.linkedin.com is its own rule, not linkedin.com's.
    private static func isMember(kind: StyleMember.Kind, key: String, in styles: AppCleanupStyles) -> Bool {
        listed.contains { id in styles.contexts.members(id).contains { $0.kind == kind && $0.keys.contains(key) } }
    }

    static func rows(for id: StyleContextID, in styles: AppCleanupStyles) -> [Row] {
        guard id.hasList else { return [] }
        let contexts = styles.contexts
        var rows: [Row] = contexts.members(id).map {
            Row(member: $0, ownRule: false, ruleStyle: ruleStyle($0, in: styles), ruleLevel: ruleLevel($0, in: styles))
        }
        for entry in styles.entries {
            let member = StyleMember(kind: .app, name: entry.appName, keys: [entry.bundleID], isBuiltIn: false)
            guard let style = entry.style, !isMember(kind: .app, key: entry.bundleID, in: styles),
                  claim(member, style: style, in: styles) == id else { continue }
            rows.append(Row(member: member, ownRule: true, ruleStyle: style, ruleLevel: entry.level))
        }
        for entry in styles.websites {
            let member = StyleMember(kind: .site, name: entry.domain, keys: [entry.domain], isBuiltIn: false)
            guard let style = entry.style, !isMember(kind: .site, key: entry.domain, in: styles),
                  claim(member, style: style, in: styles) == id else { continue }
            rows.append(Row(member: member, ownRule: true, ruleStyle: style, ruleLevel: entry.level))
        }
        return rows
    }

    /// Explicit rules that appear in no context's list: not a member row, and no context claims their tone.
    static func ownRules(in styles: AppCleanupStyles) -> [OwnRule] {
        let apps = styles.entries.compactMap { entry -> OwnRule? in
            let member = StyleMember(kind: .app, name: entry.appName, keys: [entry.bundleID], isBuiltIn: false)
            if isMember(kind: .app, key: entry.bundleID, in: styles) { return nil }
            if let style = entry.style, claim(member, style: style, in: styles) != nil { return nil }
            return OwnRule(member: member, style: entry.style, level: entry.level)
        }
        let sites = styles.websites.compactMap { entry -> OwnRule? in
            let member = StyleMember(kind: .site, name: entry.domain, keys: [entry.domain], isBuiltIn: false)
            if isMember(kind: .site, key: entry.domain, in: styles) { return nil }
            if let style = entry.style, claim(member, style: style, in: styles) != nil { return nil }
            return OwnRule(member: member, style: entry.style, level: entry.level)
        }
        return apps + sites
    }
}
