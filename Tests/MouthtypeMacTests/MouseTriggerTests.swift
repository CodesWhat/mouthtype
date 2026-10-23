import CoreGraphics
import Foundation
import MouthtypeCore
import Testing
@testable import MouthtypeMac

@MainActor @Suite struct MouseTriggerTests {
    private let ms: UInt64 = 1_000_000
    private func down(_ at: UInt64, flags: UInt64 = 0) -> MouseSample { .init(isDown: true, flags: flags, timestamp: at) }
    private func up(_ at: UInt64) -> MouseSample { .init(isDown: false, flags: 0, timestamp: at) }

    private func service(mode: RecordingMode) -> HotkeyService {
        HotkeyService(
            options: .init(configuration: .init(recordingMode: mode), mouseTrigger: .middle), otherKeysHeld: { _ in false })
    }

    private func events(_ service: HotkeyService, count: Int) async -> [HotkeyEvent] {
        let collector = Task { @MainActor in
            var received: [HotkeyEvent] = []
            for await event in service.events {
                received.append(event)
                if received.count == count { break }
            }
            return received
        }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(5))
            collector.cancel()
        }
        let result = await collector.value
        deadline.cancel()
        return result
    }

    @Test func buttonsMapToCGEventNumbersAndNoneIsUnset() {
        #expect(MouseTrigger.none.buttonNumber == nil)
        #expect(MouseTrigger.middle.buttonNumber == 2)
        #expect(MouseTrigger.back.buttonNumber == 3)
        #expect(MouseTrigger.forward.buttonNumber == 4)
        #expect(MouseTrigger.allCases.compactMap(\.buttonNumber).allSatisfy { $0 >= 2 })
    }

    @Test func preferenceDefaultsToNoneAndIgnoresMalformedValues() {
        let name = "MouseTriggerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(MouseTriggerPreference.current(defaults) == .none)
        for value in ["left", "Middle", 3] as [Any] {
            defaults.set(value, forKey: MouseTriggerPreference.key)
            #expect(MouseTriggerPreference.current(defaults) == .none)
        }
        for trigger in MouseTrigger.allCases {
            MouseTriggerPreference.set(trigger, in: defaults)
            #expect(MouseTriggerPreference.current(defaults) == trigger)
        }
    }

    @Test func mapperEmitsFnHeldOnPressAndReleaseOnUpOnly() {
        var mapper = MouseInputMapper()
        #expect(mapper.map(up(0), otherKeysHeld: { false }) == nil)
        #expect(mapper.map(down(5), otherKeysHeld: { false })?.keyEvent == KeyEvent(key: nil, modifiers: [.fn]))
        #expect(mapper.map(down(6), otherKeysHeld: { false }) == nil)
        #expect(mapper.held)
        #expect(mapper.map(up(9), otherKeysHeld: { false }) == MappedInput(keyEvent: KeyEvent(key: nil, modifiers: []), timestampNanos: 9))
        #expect(!mapper.held)
    }

    @Test func mapperRefusesAPressMadeWithKeysOrModifiersDown() {
        var mapper = MouseInputMapper()
        #expect(mapper.map(down(0), otherKeysHeld: { true })?.keyEvent.key == .heldElsewhere)
        _ = mapper.map(up(1), otherKeysHeld: { false })
        #expect(mapper.map(down(2, flags: CGEventFlags.maskCommand.rawValue), otherKeysHeld: { false })?.keyEvent.key == .heldElsewhere)
    }

    @Test func holdModeStartsOnPressAndEndsOnReleaseAfterTheMinimum() async {
        let service = service(mode: .hold)
        defer { service.stop() }
        service.process(mouse: down(0))
        service.process(mouse: up(1_000 * ms))
        #expect(await events(service, count: 2) == [.pressed(at: 0), .released(at: 1_000 * ms)])
    }

    @Test func holdModeDiscardsAClickShorterThanTheMinimum() async {
        let service = service(mode: .hold)
        defer { service.stop() }
        service.process(mouse: down(0))
        service.process(mouse: up(100 * ms))
        #expect(await events(service, count: 2) == [.pressed(at: 0), .discarded(reason: .tooShort)])
    }

    @Test func toggleModeStartsOnOneClickAndStopsOnTheNext() async {
        let service = service(mode: .toggle)
        defer { service.stop() }
        service.process(mouse: down(0))
        service.process(mouse: up(50 * ms))
        service.process(mouse: down(2_000 * ms))
        service.process(mouse: up(2_050 * ms))
        #expect(
            await events(service, count: 3) == [.pressed(at: 0), .locked(at: 0, trigger: .toggle), .released(at: 2_000 * ms)])
    }

    @Test func refusedPressStartsNothingAndTheNextCleanPressWorks() async {
        var keysHeld = true
        let service = HotkeyService(
            options: .init(configuration: .init(recordingMode: .toggle), mouseTrigger: .middle), otherKeysHeld: { _ in keysHeld })
        defer { service.stop() }
        service.process(mouse: down(0))
        service.process(mouse: up(10 * ms))
        keysHeld = false
        service.process(mouse: down(20 * ms))
        #expect(await events(service, count: 2) == [.pressed(at: 20 * ms), .locked(at: 20 * ms, trigger: .toggle)])
    }

    @Test func escapeCancelsAHeldMouseRecording() async {
        let service = service(mode: .hold)
        defer { service.stop() }
        service.process(mouse: down(0))
        service.process(.init(kind: .keyDown, keyCode: 53, flags: 0, timestamp: 500 * ms))
        service.process(mouse: up(900 * ms))
        service.process(mouse: down(2_000 * ms))
        service.process(mouse: up(3_000 * ms))
        #expect(
            await events(service, count: 4) == [
                .pressed(at: 0), .cancelled(reason: .escape), .pressed(at: 2_000 * ms), .released(at: 3_000 * ms),
            ])
    }

    @Test func aKeyTypedEarlyInAMouseHoldDiscardsIt() async {
        let service = service(mode: .hold)
        defer { service.stop() }
        service.process(mouse: down(0))
        service.process(.init(kind: .keyDown, keyCode: 0, flags: 0, timestamp: 100 * ms))
        #expect(await events(service, count: 2) == [.pressed(at: 0), .discarded(reason: .otherInput)])
    }

    @Test func mouseReleaseDoesNotEndATakeTheKeyboardStarted() async {
        let service = service(mode: .hold)
        defer { service.stop() }
        service.process(.init(kind: .flagsChanged, keyCode: 63, flags: CGEventFlags.maskSecondaryFn.rawValue, timestamp: 0))
        service.process(mouse: down(100 * ms))
        service.process(mouse: up(200 * ms))
        service.process(.init(kind: .flagsChanged, keyCode: 63, flags: 0, timestamp: 1_000 * ms))
        #expect(await events(service, count: 2) == [.pressed(at: 0), .released(at: 1_000 * ms)])
    }

    @Test func switchingTheButtonCancelsTheActiveTakeAndKeepsItStoppedWithoutTaps() async throws {
        let service = service(mode: .hold)
        defer { service.stop() }
        service.process(mouse: down(0))
        try service.switchMouseTrigger(.none)
        #expect(service.mouseTrigger == .none)
        #expect(await events(service, count: 2) == [.pressed(at: 0), .cancelled(reason: .inputLost)])
    }
}
