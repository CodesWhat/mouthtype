import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@Suite struct AppCleanupStylesTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "mouthtype.app-styles.tests.\(UUID().uuidString)")!
    }

    @Test func emptyPreferencesKeepGlobalStyleForEveryApp() throws {
        let styles = try AppCleanupStyles.load(defaults())
        #expect(styles.entries.isEmpty)
        for bundleID in [nil, "", "com.apple.MobileSMS", "com.tinyspeck.slackmacgap"] {
            #expect(styles.resolve(bundleID: bundleID, fallback: StylePreset.casual.options) == StylePreset.casual.options)
        }
    }

    @Test func configuredStylesRoundTripAndChangeOnlyMatchingApp() throws {
        let d = defaults()
        var styles = AppCleanupStyles()
        try styles.set(bundleID: "com.apple.MobileSMS", appName: "Messages", style: StylePreset.casual.options)
        try styles.set(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", style: .formal)
        try styles.save(to: d)
        let saved = try AppCleanupStyles.load(d)
        #expect(saved == styles)
        #expect(saved.resolve(bundleID: "com.apple.MobileSMS", fallback: .formal) == StylePreset.casual.options)
        #expect(saved.resolve(bundleID: "com.tinyspeck.slackmacgap", fallback: StylePreset.veryCasual.options) == .formal)
        #expect(saved.resolve(bundleID: "org.example.Messages", fallback: .formal) == .formal)
    }

    @Test func changesReplaceOneEntryAndRemovalRestoresFallback() throws {
        let d = defaults()
        var styles = AppCleanupStyles()
        try styles.set(bundleID: "org.example.chat", appName: "Chat", style: .formal)
        let custom = StyleOptions(capitalisation: .lowercase, endingPunctuation: .keep)
        try styles.set(bundleID: "org.example.chat", appName: "Chat renamed", style: custom)
        #expect(styles.entries.count == 1)
        #expect(styles.entries.first?.appName == "Chat renamed")
        try styles.save(to: d)
        #expect(try AppCleanupStyles.load(d).resolve(bundleID: "org.example.chat", fallback: .formal) == custom)
        styles.remove(bundleID: "org.example.chat")
        styles.remove(bundleID: "org.example.missing")
        try styles.save(to: d)
        #expect(try AppCleanupStyles.load(d).entries.isEmpty)
        #expect(styles.resolve(bundleID: "org.example.chat", fallback: .formal) == .formal)
    }

    @Test func invalidEditsLeaveExistingEntriesIntact() throws {
        var styles = AppCleanupStyles()
        try styles.set(bundleID: "org.example.chat", appName: "Chat", style: .formal)
        let before = styles
        for bundleID in ["", " ", "not an app", "a..b", ".app", "app.", "org/example/chat"] {
            #expect(throws: (any Error).self) {
                try styles.set(bundleID: bundleID, appName: "Chat", style: .formal)
            }
            #expect(styles == before)
        }
        #expect(throws: (any Error).self) {
            try styles.set(bundleID: "org.example.chat", appName: " \n", style: .formal)
        }
        #expect(styles == before)
    }

    @Test func malformedPreferencesAreReportedAndPreserved() {
        let d = defaults()
        let bad = Data("not json".utf8)
        d.set(bad, forKey: AppCleanupStyles.preferenceKey)
        #expect(throws: (any Error).self) { try AppCleanupStyles.load(d) }
        #expect(d.data(forKey: AppCleanupStyles.preferenceKey) == bad)
        d.set("unexpected preference type", forKey: AppCleanupStyles.preferenceKey)
        #expect(throws: (any Error).self) { try AppCleanupStyles.load(d) }
        #expect(d.string(forKey: AppCleanupStyles.preferenceKey) == "unexpected preference type")
    }

    @Test func duplicateOrUnknownStoredStylesDoNotPartiallyLoad() {
        let d = defaults()
        for json in [
            """
            {"version":1,"entries":[{"bundleID":"org.example.chat","appName":"Chat","capitalisation":"sentence","endingPunctuation":"keep"},{"bundleID":"org.example.chat","appName":"Chat2","capitalisation":"lowercase","endingPunctuation":"keep"}]}
            """,
            """
            {"version":1,"entries":[{"bundleID":"org.example.chat","appName":"Chat","capitalisation":"rewrite","endingPunctuation":"keep"}]}
            """,
            """
            {"version":2,"entries":[]}
            """,
        ] {
            let data = Data(json.utf8)
            d.set(data, forKey: AppCleanupStyles.preferenceKey)
            #expect(throws: (any Error).self) { try AppCleanupStyles.load(d) }
            #expect(d.data(forKey: AppCleanupStyles.preferenceKey) == data)
        }
    }
}
