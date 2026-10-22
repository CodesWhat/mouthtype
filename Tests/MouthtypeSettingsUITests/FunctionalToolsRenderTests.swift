import AppKit
import SwiftUI
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor private final class RenderSelection: SelectionEditing {
    func capture() throws -> SelectedText {
        SelectedText(pid: 123, element: nil, range: NSRange(location: 0, length: 30), text: "um send Sean the notes  please")
    }
    func replace(_ original: SelectedText, with replacement: String) -> Bool { false }
}

@MainActor @Suite(.serialized) struct FunctionalToolsRenderTests {
    private func render(_ view: NSView, size: NSSize, name: String) throws {
        view.setFrameSize(size)
        view.layoutSubtreeIfNeeded()
        let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        #expect(image.pixelsWide >= Int(size.width))
        if let output = ProcessInfo.processInfo.environment["MOUTHTYPE_FUNCTIONAL_PREVIEWS"] {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try #require(image.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
        }
    }

    @Test func selectionPreviewRendersWithoutActivatingOrShowingWindow() throws {
        let model = SelectionCleanupModel(editor: RenderSelection())
        model.prepare()
        let controller = SelectionCleanupWindow(model: model)
        #expect(controller.window?.isVisible == false)
        try render(#require(controller.window?.contentView), size: NSSize(width: 680, height: 470), name: "selection-cleanup")
        #expect(controller.window?.isVisible == false)
    }

    @Test func microphoneListAndWebsiteRulesRenderInSettings() throws {
        let suite = "functional-render-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let devices = [
            MicrophoneDevice(uid: "desk", name: "Desk microphone", input: .init(sampleRate: 48_000, channels: 1, id: 1)),
            MicrophoneDevice(uid: "builtin", name: "Built-in microphone", input: .init(sampleRate: 48_000, channels: 1, id: 2)),
        ]
        try MicrophonePriority(enabled: true, devices: devices.map { .init(uid: $0.uid, name: $0.name) }).save(in: defaults)
        let microphone = MicrophoneSettingsModel(defaults: defaults, devices: { devices }, defaultInput: { 2 })
        let model = SettingsModel(defaults: defaults, microphone: microphone)
        model.setLevel(.basic)
        model.setWebsiteStyle(domain: "slack.com", tone: .formal)
        model.setWebsiteCleanupLevel(domain: "slack.com", level: .medium)
        model.setAppCleanupLevel(bundleID: "com.apple.Terminal", appName: "Terminal", level: .off)
        #expect(model.appStyles.websites.first?.level == .medium && model.appStyles.entries.first?.level == .off)
        let controller = SettingsWindow(model: model, reduceTransparency: { true })
        for page in [SettingsPage.style] {
            model.page = page
            controller.window?.contentView = NSHostingView(rootView: SettingsView(model: model, actions: SettingsActions()).frame(width: 1000, height: 690))
            try render(#require(controller.window?.contentView), size: NSSize(width: 1000, height: 690), name: "functional-\(page.rawValue)")
        }
        controller.window?.contentView = NSHostingView(rootView: SettingsModalView(model: model).frame(width: 760, height: 540))
        try render(#require(controller.window?.contentView), size: NSSize(width: 760, height: 540), name: "functional-general")
        #expect(controller.window?.isVisible == false)
    }
}
