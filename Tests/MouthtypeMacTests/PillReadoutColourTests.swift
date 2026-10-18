import AppKit
import Testing
@testable import MouthtypeMac

@MainActor
@Suite struct PillReadoutColourTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "pill-readout-\(UUID().uuidString)")!
    }

    private func hifi(_ readout: PillReadoutColour) throws -> HiFiPillView {
        let view = try #require(try PillSkinFactory.make(.hifi, frame: NSRect(x: 0, y: 0, width: 200, height: 60), scale: .standard, readout: readout) as? HiFiPillView)
        view.showFractions([1, 1, 1, 1, 1, 1, 1, 1, 1, 1])
        return view
    }

    private func srgb(_ color: CGColor?) -> [Int] {
        guard let components = color?.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components else { return [] }
        return components.prefix(3).map { Int(($0 * 255).rounded()) }
    }

    @Test func defaultsToAmberAndRoundTrips() {
        let store = defaults()
        #expect(PillReadoutPreference.current(store) == .amber)
        for colour in PillReadoutColour.allCases {
            PillReadoutPreference.set(colour, in: store)
            #expect(PillReadoutPreference.current(store) == colour)
        }
        store.set("chartreuse", forKey: PillReadoutPreference.key)
        #expect(PillReadoutPreference.current(store) == .amber)
    }

    @Test func amberKeepsTheLayoutsOwnColours() throws {
        let view = try hifi(.amber)
        #expect(srgb(view.segmentColor(column: 0, row: 0)) == [0xff, 0xb0, 0x2e])
        #expect(srgb(view.segmentColor(column: 0, row: 3)) == [0xff, 0x7a, 0x1e])
        #expect(srgb(view.segmentColor(column: 0, row: 4)) == [0xff, 0x3b, 0x2e])
    }

    @Test func coolWhiteAndRedRetintTheReadout() throws {
        let cool = try hifi(.coolWhite)
        #expect(srgb(cool.segmentColor(column: 4, row: 0)) == [0xe8, 0xf1, 0xff])
        #expect(srgb(cool.segmentColor(column: 4, row: 3)) == [0x9c, 0xc0, 0xff])
        #expect(srgb(cool.textColor) == [0xe8, 0xf1, 0xff])
        let red = try hifi(.red)
        #expect(srgb(red.segmentColor(column: 4, row: 0)) == [0xff, 0x3d, 0x32])
        #expect(srgb(red.textColor) == [0xff, 0x3d, 0x32])
    }

    @Test func changingTheReadoutRetintsALiveView() throws {
        let view = try hifi(.amber)
        view.setReadout(.coolWhite)
        #expect(view.readout == .coolWhite)
        #expect(srgb(view.segmentColor(column: 0, row: 0)) == [0xe8, 0xf1, 0xff])
        view.setReadout(.amber)
        #expect(srgb(view.segmentColor(column: 0, row: 0)) == [0xff, 0xb0, 0x2e])
    }

    @Test func thePaletteIsDistinctPerColour() {
        let colors = PillLayout.Colors(segmentNormal: "#ffb02e", segmentHot: "#ff7a1e", segmentPeak: "#ff3b2e", segmentDim: "#2e2008", windowBackground: "#080b0a", text: "#ffb02e", error: "#ff3b2e")
        let palettes = PillReadoutColour.allCases.map { $0.palette(base: colors) }
        #expect(Set(palettes.map(\.normal)).count == 3)
    }

    @Test func theSettingsModelStoresTheChoiceAndTellsThePill() {
        let store = defaults()
        var notified: [PillSkinKind] = []
        let model = SettingsModel(defaults: store, onSkinChanged: { notified.append($0) })
        #expect(model.readoutColour == .amber)
        model.setSkin(.hifi)
        model.setReadoutColour(.red)
        #expect(model.readoutColour == .red && PillReadoutPreference.current(store) == .red)
        #expect(notified == [.hifi, .hifi])
        #expect(SettingsModel(defaults: store).readoutColour == .red)
    }
}
