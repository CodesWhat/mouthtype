import AppKit
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
        /// The exact bundle identifiers this row reads and writes. Empty for a website.
        var targets: [String] = []
        /// Set when an app with several identifiers is split into one row per identifier.
        var splitKey: String?
        /// Instructions your own rule sets for this app or site, if any.
        var ruleInstructions: String?
        var id: String { member.id + (splitKey.map { "#" + $0 } ?? "") }
        var isBuiltIn: Bool { member.isBuiltIn && !ownRule }
    }

    /// A rule no context claims: it sets only a cleanup level, or a tone no listed context uses.
    struct OwnRule: Identifiable, Equatable {
        let member: StyleMember
        let style: StyleOptions?
        let level: CleanupLevel?
        var instructions: String? = nil
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

    private static func ruleInstructions(_ member: StyleMember, in styles: AppCleanupStyles) -> String? {
        member.kind == .app ? appRule(member, in: styles)?.instructions : siteRule(member, in: styles)?.instructions
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

    static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// The rows for one built-in or added member. A website has one. An app has one row per identifier that is installed or carries
    /// a stored rule, each bound to exactly that identifier. With none installed and a stored rule it has one row that edits every
    /// identifier it ships under (plus a row for any stored rule that differs), so an edit never lands on an identifier dictation
    /// won't see. With none installed and no stored rule it has no row.
    private static func memberRows(_ member: StyleMember, in styles: AppCleanupStyles, installed: (String) -> Bool) -> [Row] {
        guard member.kind == .app else {
            return [
                Row(
                    member: member, ownRule: false, ruleStyle: ruleStyle(member, in: styles), ruleLevel: ruleLevel(member, in: styles),
                    ruleInstructions: ruleInstructions(member, in: styles))
            ]
        }
        func row(_ keys: [String], split: String?) -> Row {
            let entry = keys.lazy.compactMap { key in styles.entries.first { $0.bundleID == key } }.first
            return Row(
                member: member, ownRule: false, ruleStyle: entry?.style, ruleLevel: entry?.level, targets: keys, splitKey: split,
                ruleInstructions: entry?.instructions)
        }
        let present = member.keys.filter(installed)
        if present.isEmpty {
            // A built-in that isn't installed and has no stored rule stays out of the list. Display only: the context still matches it.
            guard !member.isBuiltIn || member.keys.contains(where: { key in styles.entries.contains { $0.bundleID == key } }) else { return [] }
            let primary = row(member.keys, split: member.keys.count > 1 ? member.keys[0] : nil)
            var rows = [primary]
            for key in member.keys.dropFirst() {
                guard let entry = styles.entries.first(where: { $0.bundleID == key }),
                    entry.style != primary.ruleStyle || entry.level != primary.ruleLevel || entry.instructions != primary.ruleInstructions
                else { continue }
                rows.append(row([key], split: key))
            }
            return rows
        }
        let keys = member.keys.filter { key in installed(key) || styles.entries.contains { $0.bundleID == key } }
        return keys.map { row([$0], split: keys.count > 1 ? $0 : nil) }
    }

    static func rows(for id: StyleContextID, in styles: AppCleanupStyles, installed: (String) -> Bool = isInstalled) -> [Row] {
        guard id.hasList else { return [] }
        let contexts = styles.contexts
        var rows: [Row] = contexts.members(id).flatMap { memberRows($0, in: styles, installed: installed) }
        for entry in styles.entries {
            let member = StyleMember(kind: .app, name: entry.appName, keys: [entry.bundleID], isBuiltIn: false)
            guard let style = entry.style, !isMember(kind: .app, key: entry.bundleID, in: styles),
                claim(member, style: style, in: styles) == id
            else { continue }
            rows.append(
                Row(
                    member: member, ownRule: true, ruleStyle: style, ruleLevel: entry.level, targets: [entry.bundleID],
                    ruleInstructions: entry.instructions))
        }
        for entry in styles.websites {
            let member = StyleMember(kind: .site, name: entry.domain, keys: [entry.domain], isBuiltIn: false)
            guard let style = entry.style, !isMember(kind: .site, key: entry.domain, in: styles),
                claim(member, style: style, in: styles) == id
            else { continue }
            rows.append(Row(member: member, ownRule: true, ruleStyle: style, ruleLevel: entry.level, ruleInstructions: entry.instructions))
        }
        return rows
    }

    /// Explicit rules that appear in no context's list: not a member row, and no context claims their tone.
    static func ownRules(in styles: AppCleanupStyles) -> [OwnRule] {
        let apps = styles.entries.compactMap { entry -> OwnRule? in
            let member = StyleMember(kind: .app, name: entry.appName, keys: [entry.bundleID], isBuiltIn: false)
            if isMember(kind: .app, key: entry.bundleID, in: styles) { return nil }
            if let style = entry.style, claim(member, style: style, in: styles) != nil { return nil }
            return OwnRule(member: member, style: entry.style, level: entry.level, instructions: entry.instructions)
        }
        let sites = styles.websites.compactMap { entry -> OwnRule? in
            let member = StyleMember(kind: .site, name: entry.domain, keys: [entry.domain], isBuiltIn: false)
            if isMember(kind: .site, key: entry.domain, in: styles) { return nil }
            if let style = entry.style, claim(member, style: style, in: styles) != nil { return nil }
            return OwnRule(member: member, style: entry.style, level: entry.level, instructions: entry.instructions)
        }
        return apps + sites
    }
}
