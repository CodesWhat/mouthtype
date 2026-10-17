import CoreAudio
import Foundation
import Testing
@testable import MouthtypeMac

@MainActor @Suite struct MicrophoneSettingsTests {
    private let usb = MicrophoneDevice(uid: "usb", name: "USB Mic", input: .init(sampleRate: 48_000, channels: 1, id: 42))

    @Test func choosingAnInputPersistsItAndNotifiesOnce() throws {
        let suite = "microphone-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var changed = 0
        let model = MicrophoneSettingsModel(defaults: defaults, devices: { [usb] }, defaultInput: { 42 }, onChanged: { changed += 1 })
        model.choose(.device("usb"))
        #expect(model.choice == .device("usb"))
        #expect(try PreferredMicrophone.load(defaults)?.uid == "usb")
        #expect(changed == 1)
        model.choose(.systemDefault)
        #expect(try PreferredMicrophone.load(defaults) == nil)
        #expect(changed == 2)
    }

    @Test func missingSavedInputAndDiscoveryFailurePreserveThePreference() throws {
        let suite = "microphone-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try PreferredMicrophone.save(.init(uid: "usb", name: "USB Mic"), in: defaults)
        let original = defaults.data(forKey: PreferredMicrophone.defaultsKey)
        let model = MicrophoneSettingsModel(defaults: defaults, devices: { [] }, defaultInput: { nil })
        #expect(model.choice == .device("usb"))
        #expect(model.status.contains("USB Mic"))
        #expect(model.status.contains("unavailable"))
        model.choose(.device("nonexistent"))
        #expect(defaults.data(forKey: PreferredMicrophone.defaultsKey) == original)
        #expect(model.error != nil)
        let failed = MicrophoneSettingsModel(defaults: defaults, devices: { throw CaptureError.noInputDevice }, defaultInput: { nil })
        #expect(failed.error != nil)
        #expect(defaults.data(forKey: PreferredMicrophone.defaultsKey) == original)
    }

    @Test func brokenPreferenceNeedsAnExplicitNewChoice() throws {
        let suite = "microphone-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("broken".utf8), forKey: PreferredMicrophone.defaultsKey)
        let model = MicrophoneSettingsModel(defaults: defaults, devices: { [usb] }, defaultInput: { 42 })
        #expect(model.choice == .invalidPreference)
        #expect(model.error != nil)
        model.refresh()
        #expect(defaults.data(forKey: PreferredMicrophone.defaultsKey) == Data("broken".utf8))
        model.choose(.systemDefault)
        #expect(model.error == nil)
        #expect(model.choice == .systemDefault)
        #expect(defaults.object(forKey: PreferredMicrophone.defaultsKey) == nil)
    }
}
