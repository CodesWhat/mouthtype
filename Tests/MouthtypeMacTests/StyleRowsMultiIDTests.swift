import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor @Suite struct StyleRowsMultiIDTests {
    private let classic = "ru.keepcoder.Telegram"
    private let modern = "com.tdesktop.Telegram"

    private func telegramRows(_ styles: AppCleanupStyles, installed: Set<String>) -> [StyleRows.Row] {
        StyleRows.rows(for: .personal, in: styles, installed: installed.contains).filter { $0.member.name == "Telegram" }
    }

    private func model() -> SettingsModel {
        SettingsModel(defaults: UserDefaults(suiteName: "mouthtype.style-rows.\(UUID().uuidString)")!)
    }

    @Test func oneInstalledIDGetsTheOnlyRowAndEditsOnlyThatID() {
        let rows = telegramRows(AppCleanupStyles(), installed: [modern])
        #expect(rows.count == 1 && rows[0].targets == [modern])
        let m = model()
        m.setAppStyle(bundleIDs: rows[0].targets, appName: "Telegram", tone: .formal)
        #expect(m.appStyles.entries.map(\.bundleID) == [modern])
        #expect(m.appStyles.resolve(bundleID: modern, fallback: StylePreset.casual.options) == StylePreset.formal.options)
    }

    @Test func noneInstalledEditsEveryID() {
        let rows = telegramRows(AppCleanupStyles(), installed: [])
        #expect(rows.count == 1 && rows[0].targets == [classic, modern])
        let m = model()
        m.setAppStyle(bundleIDs: rows[0].targets, appName: "Telegram", tone: .veryCasual)
        #expect(Set(m.appStyles.entries.map(\.bundleID)) == [classic, modern])
        // Both stored rules are identical, so the page still shows a single row.
        #expect(telegramRows(m.appStyles, installed: []).count == 1)
    }

    @Test func bothInstalledGetOneRowEachBoundToItsExactID() {
        let rows = telegramRows(AppCleanupStyles(), installed: [classic, modern])
        #expect(rows.map(\.targets) == [[classic], [modern]])
        #expect(Set(rows.map(\.id)).count == 2)
    }

    @Test func aStoredOverrideOnAnUninstalledIDKeepsItsOwnRow() throws {
        var styles = AppCleanupStyles()
        try styles.set(bundleID: classic, appName: "Telegram", style: StylePreset.formal.options)
        let rows = telegramRows(styles, installed: [modern])
        #expect(rows.map(\.targets) == [[classic], [modern]])
        #expect(rows[0].ruleStyle == StylePreset.formal.options && rows[1].ruleStyle == nil)
    }

    @Test func differingOverridesWithNothingInstalledStaySeparate() throws {
        var styles = AppCleanupStyles()
        try styles.set(bundleID: classic, appName: "Telegram", style: StylePreset.formal.options)
        try styles.set(bundleID: modern, appName: "Telegram", style: StylePreset.veryCasual.options)
        let rows = telegramRows(styles, installed: [])
        #expect(rows.count == 2)
        #expect(rows.contains { $0.targets == [modern] && $0.ruleStyle == StylePreset.veryCasual.options })
    }

    @Test func singleIDAppsAreUnchanged() {
        let rows = StyleRows.rows(for: .email, in: AppCleanupStyles(), installed: { _ in true }).filter { $0.member.name == "Mail" }
        #expect(rows.count == 1 && rows[0].targets == ["com.apple.mail"] && rows[0].id == rows[0].member.id)
    }

    @Test func removingOneTelegramRowKeepsTheSiblingMemberAndOverride() throws {
        let m = model()
        m.setAppStyle(bundleIDs: [classic], appName: "Telegram", tone: .formal)
        m.setAppStyle(bundleIDs: [modern], appName: "Telegram", tone: .veryCasual)
        let rows = telegramRows(m.appStyles, installed: [classic, modern])
        let classicRow = try #require(rows.first { $0.targets == [classic] })
        m.removeContextMember(classicRow.member, bundleIDs: classicRow.targets, from: .personal)
        #expect(m.appStyles.entries.map(\.bundleID) == [modern])
        #expect(m.appStyles.contexts.context(bundleID: modern) == .personal)
        #expect(m.appStyles.contexts.context(bundleID: classic) == nil)
        #expect(telegramRows(m.appStyles, installed: [classic, modern]).map(\.targets) == [[modern]])
        // Removing the last identifier takes the whole member out.
        m.removeContextMember(classicRow.member, bundleIDs: [modern], from: .personal)
        #expect(telegramRows(m.appStyles, installed: [classic, modern]).isEmpty)
        #expect(m.appStyles.entries.isEmpty)
    }

    @Test func removingClassicTeamsKeepsModernTeamsAndItsOverride() throws {
        let modernTeams = "com.microsoft.teams2", classicTeams = "com.microsoft.teams"
        let m = model()
        m.setAppStyle(bundleIDs: [modernTeams], appName: "Microsoft Teams", tone: .formal)
        m.setAppStyle(bundleIDs: [classicTeams], appName: "Microsoft Teams", tone: .veryCasual)
        func teams() -> [StyleRows.Row] {
            StyleRows.rows(for: .work, in: m.appStyles, installed: { $0 == modernTeams }).filter { $0.member.name == "Microsoft Teams" }
        }
        let rows = teams()
        #expect(rows.map(\.targets) == [[modernTeams], [classicTeams]])
        m.removeContextMember(rows[1].member, bundleIDs: rows[1].targets, from: .work)
        #expect(m.appStyles.entries.map(\.bundleID) == [modernTeams])
        #expect(m.appStyles.resolve(bundleID: modernTeams, fallback: StylePreset.casual.options) == StylePreset.formal.options)
        #expect(m.appStyles.contexts.context(bundleID: modernTeams) == .work)
        #expect(m.appStyles.contexts.context(bundleID: classicTeams) == nil)
        #expect(teams().map(\.targets) == [[modernTeams]])
    }
}
