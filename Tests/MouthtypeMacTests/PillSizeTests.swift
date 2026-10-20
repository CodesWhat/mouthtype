import AppKit
import Testing
@testable import MouthtypeMac

@MainActor
@Suite struct PillSizeTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "pill-size-test-\(UUID().uuidString)")!
    }

    private func controller(size: String, skin: String = "hifi") -> PillController {
        let preferences = defaults()
        preferences.set(skin, forKey: "pillSkin")
        preferences.set(size, forKey: "pillSize")
        return PillController(level: { .silence }, defaults: preferences)
    }

    @Test func savedLargeSizeDoublesTheActualChassis() throws {
        let pill = controller(size: "large")
        let view = try #require(pill.skin as? HiFiPillView)
        let chassis = try #require(view.container.sublayers?.first)
        #expect(chassis.frame.size == CGSize(width: 292, height: 64))
        #expect(view.bounds.contains(chassis.frame))
        #expect(chassis.magnificationFilter == .nearest)
        #expect(pill.panel.frame.size == PillGeometry.panelSize(for: .large))
    }

    @Test func largeControlsScaleWithTheArtAndStayInsideThePanel() throws {
        let standard = controller(size: "standard")
        let large = controller(size: "large")
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

    @Test func sizeMenuPersistsTheChoiceForEitherSkin() throws {
        let preferences = defaults()
        var selected: [PillSkinKind] = []
        let section = PillSkinMenuSection(defaults: preferences, onSelect: { selected.append($0) })
        let styles = try #require(section.items.first?.submenu)
        let sizes = try #require(styles.items.first(where: { $0.title == "Pill Size" })?.submenu)
        #expect(sizes.items.map(\.title) == ["Automatic", "Standard", "Large"])
        #expect(sizes.items.map(\.state) == [.on, .off, .off])
        let bigger = try #require(sizes.items.last)
        _ = bigger.target?.perform(bigger.action, with: bigger)
        #expect(preferences.string(forKey: "pillSize") == "large")
        #expect(preferences.string(forKey: "pillSkin") == nil)
        #expect(selected == [.classic])
        #expect(sizes.items.map(\.state) == [.off, .off, .on])
    }

    @Test func cardClearsTheLargerPill() throws {
        let standard = controller(size: "standard")
        let large = controller(size: "large")
        let normal = try #require(standard.cardAnchor())
        let bigger = try #require(large.cardAnchor())
        #expect(bigger.top - normal.top == 32)
        #expect(bigger.midX == normal.midX)
    }

    @Test func ringCardClearsTheLargerRing() throws {
        let standard = controller(size: "standard", skin: "ring")
        let large = controller(size: "large", skin: "ring")
        #expect(standard.skin is RingPillView && large.skin is RingPillView)
        let normal = try #require(standard.cardAnchor())
        let bigger = try #require(large.cardAnchor())
        #expect(bigger.top - normal.top == 40)
        #expect(bigger.midX == normal.midX)
        #expect(large.panel.frame.size == PillGeometry.panelSize(for: .large))
    }

    @Test func unknownSavedSizesFallBackToAutomatic() {
        for value in ["", "huge", "2", "Large"] {
            let preferences = defaults()
            preferences.set(value, forKey: "pillSize")
            #expect(PillSizePreference.current(preferences) == .automatic)
        }
    }

    @Test func aRecordingKeepsItsSizeUntilTheNextAppearance() throws {
        let preferences = defaults()
        preferences.set("hifi", forKey: "pillSkin")
        preferences.set("standard", forKey: "pillSize")
        let pill = PillController(level: { .silence }, defaults: preferences)
        let section = PillSkinMenuSection(defaults: preferences, onSelect: { pill.setSkin($0) })
        let sizes = try #require(section.items[0].submenu?.items.first(where: { $0.title == "Pill Size" })?.submenu)
        pill.showHandsFree()
        defer { pill.hide() }
        let original = pill.skin
        let bigger = try #require(sizes.items.last)
        _ = bigger.target?.perform(bigger.action, with: bigger)
        #expect(pill.skin === original && pill.skin.isLocked && pill.pillScale == .standard)
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
        preferences.set("standard", forKey: "pillSize")
        let pill = PillController(level: { .silence }, defaults: preferences)
        let section = PillSkinMenuSection(defaults: preferences, onSelect: { pill.setSkin($0) })
        let sizes = try #require(section.items[0].submenu?.items.first(where: { $0.title == "Pill Size" })?.submenu)
        pill.showRecording()
        defer { pill.hide() }
        let original = pill.skin
        for item in sizes.items.filter({ $0.title != "Automatic" }).reversed() { _ = item.target?.perform(item.action, with: item) }
        pill.hide()
        pill.showRecording()
        #expect(pill.skin === original)
        #expect(preferences.string(forKey: "pillSize") == "standard")
    }

    @Test func bitmapMessagesKeepTheirScrollTimingAtBothSizes() throws {
        let normal = try #require(controller(size: "standard").skin as? HiFiPillView)
        let large = try #require(controller(size: "large").skin as? HiFiPillView)
        let message = PillMessage("Secure field, not pasted. Copied to the clipboard instead.")
        for view in [normal, large] { view.showMessage(message, overRecording: false) }
        #expect(normal.messageScrollDistance > 0)
        #expect(large.messageScrollDistance == normal.messageScrollDistance)
        #expect(large.controlFrames.isEmpty)
    }

}
