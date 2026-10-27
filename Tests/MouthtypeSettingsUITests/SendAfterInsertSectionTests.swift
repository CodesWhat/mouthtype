import AppKit
import SwiftUI
import Testing

@testable import MouthtypeMac

@MainActor @Suite(.serialized) struct SendAfterInsertSectionTests {
    private func throwaway(_ body: (UserDefaults) throws -> Void) throws {
        let name = "SendAfterInsertSectionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        FontRegistry.registerBundledFonts()
        try body(defaults)
    }

    /// A minimal .app bundle in a temp directory; a nil identifier leaves it out of the Info.plist.
    private func fakeApp(named name: String, bundleID: String?, in directory: URL) throws -> URL {
        let app = directory.appendingPathComponent(name + ".app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleName": name, "CFBundlePackageType": "APPL"]
        if let bundleID { plist["CFBundleIdentifier"] = bundleID }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("send-after-insert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func addingARealAppBundleStoresItsIdentifier() throws {
        try throwaway { defaults in
            let directory = try tempDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let model = SettingsModel(defaults: defaults)
            model.addSendAfterInsertApplication(at: try fakeApp(named: "Chatty", bundleID: "test.chatty", in: directory))
            #expect(model.sendAfterInsertBundleIDs == ["test.chatty"])
            #expect(model.sendAfterInsertError == nil)
            #expect(SendAfterInsertSettings(defaults: defaults).isEnabled(bundleID: "test.chatty"))
        }
    }

    @Test func aNonAppURLOrABundleWithoutAnIdentifierSetsOnlyItsOwnError() throws {
        try throwaway { defaults in
            let directory = try tempDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let model = SettingsModel(defaults: defaults)
            model.addSendAfterInsertApplication(at: directory.appendingPathComponent("notes.txt"))
            #expect(model.sendAfterInsertError == "That application has no readable bundle identifier.")
            model.addSendAfterInsertApplication(at: try fakeApp(named: "Anon", bundleID: nil, in: directory))
            #expect(model.sendAfterInsertError != nil)
            #expect(model.sendAfterInsertBundleIDs.isEmpty)
            #expect(model.appStylesError == nil)
            model.addSendAfterInsertApplication(at: try fakeApp(named: "Chatty", bundleID: "test.chatty", in: directory))
            #expect(model.sendAfterInsertError == nil)
        }
    }

    @Test func removingAnAppDropsItFromTheModelAndDefaults() throws {
        try throwaway { defaults in
            let model = SettingsModel(defaults: defaults)
            model.addSendAfterInsert(bundleID: "test.one")
            model.addSendAfterInsert(bundleID: "test.two")
            model.removeSendAfterInsert(bundleID: "test.one")
            #expect(model.sendAfterInsertBundleIDs == ["test.two"])
            #expect(defaults.stringArray(forKey: "sendAfterInsertBundleIDs") == ["test.two"])
            model.removeSendAfterInsert(bundleID: "test.unknown")
            #expect(model.sendAfterInsertBundleIDs == ["test.two"])
        }
    }

    @Test func nameFallsBackToTheIdentifierForAnUnknownApp() {
        #expect(SendAfterInsertApps.name(bundleID: "test.not.installed.\(UUID().uuidString)").hasPrefix("test.not.installed."))
    }

    @Test func nameReadsTheInstalledAppsDisplayName() {
        #expect(SendAfterInsertApps.name(bundleID: "com.apple.finder") == "Finder")
    }

    @Test func theSectionRendersEmptyAndWithAppsInBothThemes() throws {
        try throwaway { defaults in
            let empty = SettingsModel(defaults: defaults)
            let emptyBitmaps = try [false, true].map {
                try SettingsRender.render(SendAfterInsertSection(model: empty).padding(20), dark: $0, size: NSSize(width: 720, height: 220))
            }
            SendAfterInsertSettings(defaults: defaults).add("com.apple.finder")
            SendAfterInsertSettings(defaults: defaults).add("test.not.installed")
            let filled = SettingsModel(defaults: defaults)
            #expect(filled.sendAfterInsertBundleIDs.count == 2)
            let filledBitmaps = try [false, true].map {
                try SettingsRender.render(SendAfterInsertSection(model: filled).padding(20), dark: $0, size: NSSize(width: 720, height: 300))
            }
            for bitmap in emptyBitmaps + filledBitmaps { #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0) }
            #expect(emptyBitmaps[0].tiffRepresentation != filledBitmaps[0].tiffRepresentation)
        }
        try throwaway { defaults in
            let model = SettingsModel(defaults: defaults)
            model.addSendAfterInsert(bundleID: "test.bad")
            model.addSendAfterInsertApplication(at: URL(fileURLWithPath: "/tmp/nothing.txt"))
            #expect(model.sendAfterInsertError != nil)
            _ = try SettingsRender.render(SendAfterInsertSection(model: model).padding(20), dark: false, size: NSSize(width: 720, height: 300))
        }
    }
}
