import CoreAudio
import Foundation
import Testing
@testable import MouthtypeMac

@Suite struct MicrophonePreferenceTests {
    private let builtin = MicrophoneDevice(uid: "builtin", name: "Built-in", input: InputDevice(sampleRate: 48_000, channels: 1, id: 42))
    private let usb = MicrophoneDevice(uid: "usb-stable", name: "USB microphone", input: InputDevice(sampleRate: 48_000, channels: 2, id: 51))

    @Test func systemDefaultFollowsTheCurrentDefaultDevice() throws {
        #expect(try PreferredMicrophone.resolve(nil, devices: [builtin, usb], defaultInput: 51) == usb.input)
        #expect(try PreferredMicrophone.resolve(nil, devices: [builtin, usb], defaultInput: 42) == builtin.input)
        #expect(throws: CaptureError.self) { try PreferredMicrophone.resolve(nil, devices: [builtin], defaultInput: nil) }
    }

    @Test func preferredDeviceUsesStableIdentityInsteadOfSystemDefaultOrOldNumericID() throws {
        let saved = PreferredMicrophone(uid: usb.uid, name: usb.name)
        var reconnected = usb
        reconnected.input.id = 99
        #expect(try PreferredMicrophone.resolve(saved, devices: [builtin, reconnected], defaultInput: 42) == reconnected.input)
        #expect(throws: CaptureError.self) { try PreferredMicrophone.resolve(saved, devices: [builtin], defaultInput: 42) }
    }

    @Test func savedChoiceRoundTripsAndSystemDefaultExplicitlyClearsIt() throws {
        let suite = "microphone-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(try PreferredMicrophone.load(defaults) == nil)
        let saved = PreferredMicrophone(uid: usb.uid, name: usb.name)
        try PreferredMicrophone.save(saved, in: defaults)
        #expect(try PreferredMicrophone.load(defaults) == saved)
        try PreferredMicrophone.save(nil, in: defaults)
        #expect(try PreferredMicrophone.load(defaults) == nil)
    }

    @Test func damagedPreferenceDoesNotSilentlyChooseAnotherMicrophone() throws {
        let suite = "microphone-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("invalid".utf8), forKey: PreferredMicrophone.defaultsKey)
        #expect(throws: (any Error).self) { try PreferredMicrophone.load(defaults) }
        #expect(defaults.data(forKey: PreferredMicrophone.defaultsKey) == Data("invalid".utf8))
    }

    @Test func emptyIdentityCannotBeSavedAsADevice() throws {
        let suite = "microphone-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(throws: (any Error).self) { try PreferredMicrophone.save(PreferredMicrophone(uid: "", name: "Unknown"), in: defaults) }
        #expect(defaults.object(forKey: PreferredMicrophone.defaultsKey) == nil)
    }
}
