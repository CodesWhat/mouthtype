import Foundation
import Testing
@testable import MouthtypeMac

@Suite struct MicrophonePriorityTests {
    let desk = MicrophoneDevice(uid: "desk", name: "Desk", input: .init(sampleRate: 48_000, channels: 1, id: 11))
    let builtin = MicrophoneDevice(uid: "built-in", name: "Built-in", input: .init(sampleRate: 48_000, channels: 1, id: 22))

    @Test func orderedAvailableDevicesAndExplicitFallback() throws {
        var policy = MicrophonePriority(enabled: true, devices: [.init(uid: desk.uid, name: desk.name), .init(uid: builtin.uid, name: builtin.name)])
        let preferred = PreferredMicrophone(uid: "missing", name: "Old fixed input")
        #expect(try CaptureInputSelection.resolve(preferred: preferred, priority: policy, devices: [builtin, desk], defaultInput: 22).device == desk.input)
        #expect(try CaptureInputSelection.resolve(preferred: preferred, priority: policy, devices: [builtin], defaultInput: 22).device == builtin.input)
        policy.devices = [.init(uid: desk.uid, name: desk.name)]
        #expect(throws: CaptureError.self) { try CaptureInputSelection.resolve(preferred: nil, priority: policy, devices: [builtin], defaultInput: 22) }
        policy.fallbackToDefault = true
        let fallback = try CaptureInputSelection.resolve(preferred: nil, priority: policy, devices: [builtin], defaultInput: 22)
        #expect(fallback.device == builtin.input)
        #expect(fallback.followsDefault)
    }

    @Test func disabledPolicyPreservesExistingFixedDeviceContract() throws {
        let policy = MicrophonePriority(enabled: false, devices: [.init(uid: builtin.uid, name: builtin.name)], fallbackToDefault: true)
        #expect(throws: CaptureError.self) {
            try CaptureInputSelection.resolve(preferred: .init(uid: desk.uid, name: desk.name), priority: policy, devices: [builtin], defaultInput: 22)
        }
    }

    @Test func invalidAvailableDeviceDoesNotSilentlySelectAnotherInput() throws {
        var invalid = desk
        invalid.input.sampleRate = 0
        let policy = MicrophonePriority(enabled: true, devices: [.init(uid: desk.uid, name: desk.name)], fallbackToDefault: true)
        #expect(throws: CaptureError.self) { try CaptureInputSelection.resolve(preferred: nil, priority: policy, devices: [invalid, builtin], defaultInput: 22) }
    }

    @Test func storageRejectsDuplicateAndBrokenPreferencesWithoutOverwriting() throws {
        let suite = "priority-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var policy = MicrophonePriority(enabled: true, devices: [.init(uid: desk.uid, name: desk.name)])
        try policy.save(in: defaults)
        #expect(try MicrophonePriority.load(defaults) == policy)
        policy.devices.append(policy.devices[0])
        #expect(throws: CaptureError.self) { try policy.save(in: defaults) }
        #expect(try MicrophonePriority.load(defaults)?.devices.count == 1)
        defaults.set(Data("broken".utf8), forKey: MicrophonePriority.defaultsKey)
        #expect(throws: CaptureError.self) { try MicrophonePriority.load(defaults) }
    }
}

@MainActor @Suite struct MicrophonePrioritySettingsTests {
    @Test func enableReorderRemoveAndDisableRetainExplicitChoices() throws {
        let suite = "priority-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let devices = [MicrophoneDevice(uid: "a", name: "A", input: .init(sampleRate: 48_000, channels: 1, id: 1)),
                       MicrophoneDevice(uid: "b", name: "B", input: .init(sampleRate: 48_000, channels: 1, id: 2))]
        var changed = 0
        let model = MicrophoneSettingsModel(defaults: defaults, devices: { devices }, defaultInput: { 1 }, onChanged: { changed += 1 })
        model.choose(.priorityList)
        model.addPriority(uid: "b")
        model.movePriority(uid: "b", offset: -1)
        #expect(model.priority?.devices.map(\.uid) == ["b", "a"])
        model.setPriorityFallback(true)
        model.removePriority(uid: "a")
        #expect(model.priority?.fallbackToDefault == true)
        #expect(model.priority?.devices.map(\.uid) == ["b"])
        model.choose(.systemDefault)
        #expect(model.priority?.enabled == false)
        #expect(changed == 6)
        model.choose(.priorityList)
        #expect(model.priority?.devices.map(\.uid) == ["b"])
    }
}
