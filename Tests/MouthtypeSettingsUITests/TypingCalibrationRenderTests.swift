import AppKit
import SwiftUI
import Testing
@testable import MouthtypeCore
@testable import MouthtypeMac

@MainActor @Suite(.serialized) struct TypingCalibrationRenderTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 100
        var now: TimeInterval { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    }

    @Test func calibrationCardRendersInEveryStateLightAndDark() throws {
        FontRegistry.registerBundledFonts()
        let name = "TypingCalibrationRenderTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let clock = Clock()
        let model = TypingCalibrationModel(defaults: defaults, now: { clock.now }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MOUTHTYPE_RENDER_DIR"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        func snap(_ label: String) throws {
            for dark in [false, true] {
                let bitmap = try SettingsRender.render(
                    TypingCalibrationCard(model: model).padding(24).background(DesignPalette.bg), dark: dark,
                    size: NSSize(width: 720, height: 560))
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: out.appendingPathComponent("typing-\(label)-\(dark ? "dark" : "light").png"))
            }
        }

        try snap("closed")
        model.open()
        try snap("idle")
        model.start()
        model.text = String(TypingCalibrationModel.passage.prefix(1))
        clock.advance(24)
        model.text = String(TypingCalibrationModel.passage.prefix(70)) + "xx"
        try snap("running")
        clock.advance(36)
        model.tick()
        #expect(model.result != nil)
        try snap("result")
        model.accept()
        try snap("accepted")
    }
}
