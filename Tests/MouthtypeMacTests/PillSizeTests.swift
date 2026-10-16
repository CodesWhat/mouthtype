import AppKit
import Testing
@testable import MouthtypeMac

@MainActor
@Suite struct PillSizeTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "pill-size-test-\(UUID().uuidString)")!
    }

    private func controller(size: Int) -> PillController {
        let preferences = defaults()
        preferences.set("hifi", forKey: "pillSkin")
        preferences.set(size, forKey: "hiFiPillSize")
        return PillController(level: { .silence }, defaults: preferences)
    }

    @Test func savedLargeSizeDoublesTheActualChassis() throws {
        let pill = controller(size: 2)
        let view = try #require(pill.skin as? HiFiPillView)
        let chassis = try #require(view.container.sublayers?.first)
        #expect(chassis.frame.size == CGSize(width: 292, height: 64))
        #expect(view.bounds.contains(chassis.frame))
        #expect(chassis.magnificationFilter == .nearest)
        #expect(pill.panel.frame.size == PillController.panelSize)
    }

    @Test func largeControlsScaleWithTheArtAndStayInsideThePanel() throws {
        let standard = controller(size: 1)
        let large = controller(size: 2)
        standard.skin.showRecording(locked: true)
        large.skin.showRecording(locked: true)
        for control in [PillControl.cancel, .stop] {
            let normal = try #require(standard.skin.controlFrames[control])
            let bigger = try #require(large.skin.controlFrames[control])
            #expect(bigger.width == normal.width * 2 && bigger.height == normal.height * 2)
            #expect(large.host.bounds.contains(PillHit.target(for: bigger)))
            #expect(PillHit.control(at: CGPoint(x: bigger.midX, y: bigger.midY), frames: large.skin.controlFrames) == control)
        }
    }

    @Test func sizeMenuPersistsTheChoiceAndSelectsHiFi() throws {
        let preferences = defaults()
        var selected: [PillSkinKind] = []
        let section = PillSkinMenuSection(defaults: preferences, onSelect: { selected.append($0) })
        let styles = try #require(section.items.first?.submenu)
        let sizes = try #require(styles.items.first(where: { $0.title == "Hi-Fi Size" })?.submenu)
        #expect(sizes.items.map(\.title) == ["Standard", "Large (2×)"])
        #expect(sizes.items.map(\.state) == [.on, .off])
        let bigger = try #require(sizes.items.last)
        _ = bigger.target?.perform(bigger.action, with: bigger)
        #expect(preferences.integer(forKey: "hiFiPillSize") == 2)
        #expect(preferences.string(forKey: "pillSkin") == "hifi")
        #expect(selected == [.hifi])
        #expect(sizes.items.map(\.state) == [.off, .on])
    }

    @Test func cardClearsTheLargerPill() throws {
        let standard = controller(size: 1)
        let large = controller(size: 2)
        let normal = try #require(standard.cardAnchor())
        let bigger = try #require(large.cardAnchor())
        #expect(bigger.top - normal.top == 32)
        #expect(bigger.midX == normal.midX)
    }

    @Test func unknownSavedSizesKeepTheStandardPill() throws {
        for value in [0, -2, 99] {
            let pill = controller(size: value)
            let view = try #require(pill.skin as? HiFiPillView)
            #expect(view.container.sublayers?.first?.frame.size == CGSize(width: 146, height: 32))
        }
    }

    @Test func aRecordingKeepsItsSizeUntilTheNextAppearance() throws {
        let preferences = defaults()
        preferences.set("hifi", forKey: "pillSkin")
        let pill = PillController(level: { .silence }, defaults: preferences)
        let section = PillSkinMenuSection(defaults: preferences, onSelect: { pill.setSkin($0) })
        let sizes = try #require(section.items[0].submenu?.items.first(where: { $0.title == "Hi-Fi Size" })?.submenu)
        pill.showHandsFree()
        defer { pill.hide() }
        let original = pill.skin
        let bigger = try #require(sizes.items.last)
        _ = bigger.target?.perform(bigger.action, with: bigger)
        #expect(pill.skin === original && pill.skin.isLocked)
        pill.hide()
        pill.showRecording()
        let view = try #require(pill.skin as? HiFiPillView)
        #expect(view.container.sublayers?.first?.frame.size == CGSize(width: 292, height: 64))
        #expect(pill.skin !== original)
        pill.hide()
        pill.setSkin(.classic)
        let classic = pill.skin
        pill.setSkin(.hifi)
        #expect(pill.skin !== classic)
        #expect((pill.skin as? HiFiPillView)?.container.sublayers?.first?.frame.width == 292)
    }

    @Test func theLastSizeChoiceWinsBeforeTheNextAppearance() throws {
        let preferences = defaults()
        preferences.set("hifi", forKey: "pillSkin")
        let pill = PillController(level: { .silence }, defaults: preferences)
        let section = PillSkinMenuSection(defaults: preferences, onSelect: { pill.setSkin($0) })
        let sizes = try #require(section.items[0].submenu?.items.first(where: { $0.title == "Hi-Fi Size" })?.submenu)
        pill.showRecording()
        defer { pill.hide() }
        let original = pill.skin
        for item in sizes.items.reversed() { _ = item.target?.perform(item.action, with: item) }
        pill.hide()
        pill.showRecording()
        #expect(pill.skin === original)
        #expect(preferences.integer(forKey: "hiFiPillSize") == 1)
    }

    @Test func bitmapMessagesKeepTheirScrollTimingAtBothSizes() throws {
        let normal = try #require(controller(size: 1).skin as? HiFiPillView)
        let large = try #require(controller(size: 2).skin as? HiFiPillView)
        let message = PillMessage("Secure field, not pasted. Copied to the clipboard instead.")
        for view in [normal, large] { view.showMessage(message, overRecording: false) }
        #expect(normal.messageScrollDistance > 0)
        #expect(large.messageScrollDistance == normal.messageScrollDistance)
        #expect(large.controlFrames.isEmpty)
    }

}
