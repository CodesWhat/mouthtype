import AppKit
import SwiftUI
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor private final class StyleStubCleaner: CleanupModelManaging {
    var state = CleanerState.ready(loadSeconds: 1)
    let modelName = "Fast cleanup"
    let downloadSizeMB = 600
    func start() {}
    func levelChanged() {}
    func startDownload() {}
    func cancelDownload() {}
    nonisolated func recordingStarted() {}
    func readiness(waitingUpTo limit: Duration) async -> SmartCleanerInfo? { nil }
    func run(_ request: SmartCleanupRequest) async -> SmartCleanupResult { fatalError("Rendering does not run cleanup") }
}

@MainActor @Suite(.serialized) struct StylePageRenderTests {
    private func makeModel(rules: Bool = true) throws -> (SettingsModel, UserDefaults, () -> Void) {
        let name = "StylePageRender-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        FontRegistry.registerBundledFonts()
        let model = SettingsModel(defaults: defaults)
        if rules {
            model.addContextSite(.personal, domain: "web.whatsapp.com")
            model.setContextLevel(.other, .basic)
            model.setAppStyle(bundleID: "com.apple.Terminal", appName: "Terminal", tone: .veryCasual)
            model.setAppStyle(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", tone: .formal)
        }
        return (model, defaults, { defaults.removePersistentDomain(forName: name) })
    }

    private let actions = SettingsActions(cleaner: StyleStubCleaner())
    private let size = NSSize(width: 900, height: 1500)

    private func page(_ model: SettingsModel, _ tab: StyleTab) -> some View {
        DesignPage(title: "Your words. Your way.", summary: "A tone for each kind of writing, and the apps that count as each kind.") {
            StylePage(model: model, actions: actions, initialTab: tab)
        }
    }

    @Test(arguments: [false, true])
    func everyTabRendersInLightAndDark(dark: Bool) throws {
        let (model, _, cleanup) = try makeModel()
        defer { cleanup() }
        for tab in StyleTab.allCases {
            let bitmap = try SettingsRender.render(page(model, tab), dark: dark, size: size)
            #expect(bitmap.pixelsWide >= Int(size.width))
            try SettingsRender.save(bitmap, name: "style-\(StyleTabBar.slug(tab))-\(dark ? "dark" : "light")")
        }
    }

    @Test func styleRendersInsideTheWindowAtMinimumSize() throws {
        let (model, _, cleanup) = try makeModel()
        defer { cleanup() }
        model.page = .style
        let bitmap = try SettingsRender.render(model: model, actions: actions, dark: false, size: SettingsTheme.minimumSize)
        #expect(bitmap.pixelsWide >= 860)
        try SettingsRender.save(bitmap, name: "style-window-minimum")
    }

    @Test func tonePickMovesTheContextAndOtherFollowsTheDefaultTone() throws {
        let (model, defaults, cleanup) = try makeModel(rules: false)
        defer { cleanup() }
        #expect(model.appStyles.contexts.tone(.personal) == .casual)
        model.setContextTone(.personal, .veryCasual)
        #expect(model.appStyles.contexts.tone(.personal) == .veryCasual)
        #expect(model.appStyles.resolve(bundleID: "com.apple.MobileSMS", fallback: .formal) == StylePreset.veryCasual.options)
        model.setContextTone(.other, .casual)
        #expect(model.cleanup.style == StylePreset.casual.options)
        #expect(try AppCleanupStyles.load(defaults).resolve(bundleID: "com.apple.Terminal", fallback: model.cleanup.style) == StylePreset.casual.options)
    }

    @Test func addingAndRemovingMembersPersists() throws {
        let (model, defaults, cleanup) = try makeModel(rules: false)
        defer { cleanup() }
        model.addContextSite(.email, domain: "fastmail.com")
        model.addContextApp(.email, bundleID: "com.readdle.smartemail-Mac", appName: "Spark")
        #expect(try AppCleanupStyles.load(defaults).contexts.context(host: "fastmail.com") == .email)
        let spark = try #require(StyleRows.rows(for: .email, in: model.appStyles, installed: { _ in true }).first { $0.member.name == "Spark" })
        model.removeContextMember(spark.member, from: .email)
        model.addContextSite(.email, domain: "not a domain")
        #expect(model.appStylesError != nil)
        model.refresh()
        #expect(StyleRows.rows(for: .email, in: model.appStyles, installed: { _ in true }).map(\.member.name) == ["Mail", "Outlook", "mail.google.com", "outlook.office.com", "fastmail.com"])
    }

    @Test func existingToneRuleIsReplacedByTheListYouAddItToButALevelRuleStays() throws {
        let (model, _, cleanup) = try makeModel(rules: false)
        defer { cleanup() }
        model.setAppStyle(bundleID: "org.example.Chat", appName: "Chat", tone: .formal)
        model.addContextApp(.personal, bundleID: "org.example.Chat", appName: "Chat")
        #expect(model.appStyles.entries.isEmpty)
        #expect(model.appStyles.resolve(bundleID: "org.example.Chat", fallback: .formal) == StylePreset.casual.options)
        model.setAppCleanupLevel(bundleID: "org.example.Chat", appName: "Chat", level: .basic)
        model.addContextApp(.work, bundleID: "org.example.Chat", appName: "Chat")
        #expect(model.appStyles.resolveLevel(bundleID: "org.example.Chat") == .basic)
    }

    @Test func writingSwitchesLiveOnAdvancedAndNotOnStyle() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let settings = root.appendingPathComponent("Sources/MouthtypeMac/Settings")
        let advanced = try String(contentsOf: settings.appendingPathComponent("SettingsAdvancedPage.swift"), encoding: .utf8)
        for title in ["Remove fillers", "Spoken commands and lists", "Format numbers", "Lowercase sentence starts", "Drop the final full stop",
                      "Learn from my corrections", "Edit dictionary file…"] {
            #expect(advanced.contains("\"\(title)\""), "missing \(title)")
        }
        #expect(advanced.contains("PasteSettings.supportedTerminals"))
        for file in ["StylePage", "StyleCleanupTab", "StyleRows", "SettingsWritingPage"] {
            let style = try String(contentsOf: settings.appendingPathComponent("\(file).swift"), encoding: .utf8)
            #expect(!style.contains("setFillers") && !style.contains("setLearnCorrections") && !style.contains("setChunks"), "\(file) still holds an Advanced switch")
        }
    }

    @Test func nothingOnThePageIsTruncated() throws {
        let (model, _, cleanup) = try makeModel()
        defer { cleanup() }
        for tab in StyleTab.allCases {
            let (view, _) = SettingsRender.host(page(model, tab), dark: false, size: NSSize(width: 640, height: 1500))
            var clipped: [String] = []
            func descend(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(descend) }
            for field in descend(view).compactMap({ $0 as? NSTextField }) where !field.isEditable && field.bounds.width > 0 && !field.stringValue.isEmpty {
                let needed = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: field.bounds.width, height: .greatestFiniteMagnitude)).height ?? 0
                if needed > field.bounds.height + 2 { clipped.append(field.stringValue) }
            }
            #expect(clipped.isEmpty, "\(tab.title): \(clipped)")
        }
    }
}
