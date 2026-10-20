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

    static func rows(for id: StyleContextID, in styles: AppCleanupStyles) -> [Row] {
        guard id.hasList else { return [] }
        let contexts = styles.contexts
        var rows: [Row] = []
        for member in contexts.members(id) {
            // A tone rule of your own that differs from this context's tone wins, so the app counts under the context it matches.
            if let style = ruleStyle(member, in: styles), contexts.tone(id)?.options != style { continue }
            rows.append(Row(member: member, ownRule: false, ruleLevel: ruleLevel(member, in: styles)))
        }
        for entry in styles.entries {
            let member = StyleMember(kind: .app, name: entry.appName, keys: [entry.bundleID], isBuiltIn: false)
            guard let style = entry.style, claim(member, style: style, in: styles) == id,
                  !rows.contains(where: { $0.member.keys.contains(entry.bundleID) }) else { continue }
            rows.append(Row(member: member, ownRule: true, ruleLevel: entry.level))
        }
        for entry in styles.websites {
            let member = StyleMember(kind: .site, name: entry.domain, keys: [entry.domain], isBuiltIn: false)
            guard let style = entry.style, claim(member, style: style, in: styles) == id,
                  !rows.contains(where: { $0.member.keys.contains(entry.domain) }) else { continue }
            rows.append(Row(member: member, ownRule: true, ruleLevel: entry.level))
        }
        return rows
    }

    /// Explicit rules that appear in no context's list.
    static func ownRules(in styles: AppCleanupStyles) -> [OwnRule] {
        let apps = styles.entries.compactMap { entry -> OwnRule? in
            let member = StyleMember(kind: .app, name: entry.appName, keys: [entry.bundleID], isBuiltIn: false)
            if let style = entry.style, claim(member, style: style, in: styles) != nil { return nil }
            // A level-only rule on a listed app shows on that app's row instead.
            if entry.style == nil, styles.contexts.context(bundleID: entry.bundleID) != nil { return nil }
            return OwnRule(member: member, style: entry.style, level: entry.level)
        }
        let sites = styles.websites.compactMap { entry -> OwnRule? in
            let member = StyleMember(kind: .site, name: entry.domain, keys: [entry.domain], isBuiltIn: false)
            if let style = entry.style, claim(member, style: style, in: styles) != nil { return nil }
            if entry.style == nil, styles.contexts.context(host: entry.domain) != nil { return nil }
            return OwnRule(member: member, style: entry.style, level: entry.level)
        }
        return apps + sites
    }
}
