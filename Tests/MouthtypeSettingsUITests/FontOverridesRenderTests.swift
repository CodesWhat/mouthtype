import AppKit
import MouthtypeCore
import SwiftUI
import Testing
@testable import MouthtypeMac

@MainActor @Suite(.serialized) struct FontOverridesRenderTests {
    @Test func defaultCustomAndMissingFontsRenderWithoutOpeningAFontPanel() throws {
        let name = "FontOverridesRenderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        FontRegistry.registerBundledFonts()
        let model = SettingsModel(defaults: defaults)
        try render(model, name: "font-default", size: NSSize(width: 580, height: 180))
        model.setFontFamily("Menlo", for: .heading)
        model.setFontFamily("Avenir Next", for: .body)
        model.setFontFamily("Menlo", for: .readout)
        model.setFontOverridesEnabled(true)
        try render(model, name: "font-custom", size: NSSize(width: 580, height: 480))
        model.setFontFamily("A saved font family that is unavailable on this Mac", for: .heading)
        try render(model, name: "font-unavailable-minimum", size: NSSize(width: 430, height: 550))
        model.setFontOverridesEnabled(false)
        try render(model, name: "font-disabled", size: NSSize(width: 430, height: 180))
        #expect(TextFontPreference.current(defaults) == .systema)
        #expect(model.fontOverrides.families[.heading] == "A saved font family that is unavailable on this Mac")
        #expect(NSFontPanel.sharedFontPanelExists == false)
    }

    private func render(_ model: SettingsModel, name: String, size: NSSize) throws {
        let view = NSHostingView(rootView: FontOverridesSection(model: model)
            .font(.custom("InstrumentSans-Regular", size: 13)).padding(24)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .textBackgroundColor)))
        view.setFrameSize(size)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= Int(size.width) && bitmap.pixelsHigh >= Int(size.height))
        if let directory = ProcessInfo.processInfo.environment["MOUTHTYPE_SETTINGS_PREVIEWS"] {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
        }
    }
}
