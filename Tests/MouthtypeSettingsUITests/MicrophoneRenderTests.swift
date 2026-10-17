import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MouthtypeMac

@MainActor @Suite(.serialized) struct MicrophoneRenderTests {
    @Test func functionalInputControlRendersSelectedMissingAndDamagedStates() throws {
        let suite = "microphone-render-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let device = MicrophoneDevice(uid: "usb", name: "USB Microphone", input: .init(sampleRate: 48_000, channels: 1, id: 42))
        for state in ["default", "selected", "missing", "damaged"] {
            defaults.removePersistentDomain(forName: suite)
            if state == "selected" || state == "missing" {
                try PreferredMicrophone.save(.init(uid: device.uid, name: device.name), in: defaults)
            }
            if state == "damaged" { defaults.set(Data("bad".utf8), forKey: PreferredMicrophone.defaultsKey) }
            let model = MicrophoneSettingsModel(defaults: defaults, devices: { state == "missing" ? [] : [device] }, defaultInput: { 42 })
            let view = NSHostingView(rootView: MicrophoneSettingsSection(model: model).padding()
                .frame(width: 590, height: 180).background(Color(nsColor: .textBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 590, height: 180),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = view
            view.setFrameSize(NSSize(width: 590, height: 180))
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            #expect(bitmap.pixelsWide >= 590)
            if let output = ProcessInfo.processInfo.environment["MOUTHTYPE_MICROPHONE_PREVIEWS"] {
                let directory = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: directory.appendingPathComponent("microphone-\(state).png"))
            }
        }
    }
}
