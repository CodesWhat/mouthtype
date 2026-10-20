import AppKit
import Testing
@testable import MouthtypeMac

@MainActor @Suite struct HomeMenuRoutingTests {
    @Test func openMouthtypeLandsOnHomeAndSettingsLandsOnGeneral() throws {
        var homeOpens = 0, settingsOpens = 0
        let section = SettingsMenuSection(open: { settingsOpens += 1 }, openHome: { homeOpens += 1 })
        #expect(section.items.map(\.title) == ["Open Mouthtype", "Settings…"])
        let home = try #require(section.items.first { $0.title == "Open Mouthtype" })
        _ = home.target?.perform(home.action, with: home)
        #expect(homeOpens == 1 && settingsOpens == 0)
        let settings = try #require(section.items.first { $0.title == "Settings…" })
        #expect(settings.keyEquivalent == ",")
        _ = settings.target?.perform(settings.action, with: settings)
        #expect(homeOpens == 1 && settingsOpens == 1)
    }

    @Test func applicationMenuCarriesBothEntries() throws {
        var homeOpens = 0
        let section = SettingsMenuSection(open: {}, openHome: { homeOpens += 1 })
        let app = try #require(section.applicationMenu().items.first?.submenu)
        let home = try #require(app.items.first { $0.title == "Open Mouthtype" })
        _ = home.target?.perform(home.action, with: home)
        #expect(homeOpens == 1)
        #expect(app.items.contains { $0.title == "Settings…" && $0.keyEquivalent == "," })
    }

    @Test func presentingLandsOnTheRequestedPageInTheSameWindow() {
        let name = "HomeRoutingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = SettingsModel(defaults: defaults)
        let window = SettingsWindow(model: model, reduceTransparency: { true })
        #expect(model.page == .home && !model.settingsOpen)
        window.present(destination: .settings(.general))
        #expect(model.page == .home && model.settingsOpen && model.modalPage == .general)
        window.present(page: .style)
        #expect(model.page == .style && !model.settingsOpen)
        window.present(destination: .settings(.health))
        #expect(model.page == .style && model.settingsOpen && model.modalPage == .health)
        window.present(page: .home)
        #expect(model.page == .home && !model.settingsOpen)
        window.close()
    }
}
