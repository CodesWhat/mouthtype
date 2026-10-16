import CoreGraphics
import Foundation
import MouthtypeCore
import Testing
@testable import MouthtypeMac

@MainActor @Suite struct RecordingToggleServiceTests {
    @Test func guideExplainsToggleForTheActualShortcutAndKeepsEscapeException() {
        let fn = HelpMenuSection.instructions(for: nil, mode: .toggle)
        #expect(fn.contains("press Fn to start"))
        #expect(!fn.contains("hold Fn") && !fn.contains("double-tap"))
        let key = DictationShortcut(keyCode: 40, modifiers: CGEventFlags.maskControl.rawValue, keyName: "K")
        let combo = HelpMenuSection.instructions(for: key, mode: .toggle)
        #expect(combo.contains("press ⌃K to start") && !combo.contains("Fn"))
        #expect(combo.contains("Press Esc to cancel"))
        let escape = HelpMenuSection.instructions(for: .init(keyCode: 53, keyName: "Escape"), mode: .toggle)
        #expect(!escape.contains("Press Esc to cancel"))
        #expect(escape.contains("Cancel Dictation in the menu"))
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
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { collector.cancel() }
        }
        let result = await collector.value
        deadline.cancel()
        return result
    }

    @Test(.timeLimit(.minutes(1))) func fnRemapAndCustomComboToggleWithoutASecondTap() async {
        let fn = CGEventFlags.maskSecondaryFn.rawValue
        let control = CGEventFlags.maskControl.rawValue
        let cases: [(HotkeySource, TapSample.Kind, TapSample.Kind, UInt16, UInt64)] = [
            (.fnFlag, .flagsChanged, .flagsChanged, 63, fn),
            (.remapped(keyCode: 80), .keyDown, .keyUp, 80, 0),
            (.shortcut(.init(keyCode: 40, modifiers: control, keyName: "K")), .keyDown, .keyUp, 40, control),
        ]
        for (source, down, up, code, flags) in cases {
            let service = HotkeyService(options: .init(source: source, configuration: .init(recordingMode: .toggle)), otherKeysHeld: { _ in false })
            defer { service.stop() }
            service.process(.init(kind: down, keyCode: code, flags: flags, timestamp: 0))
            service.process(.init(kind: down, keyCode: code, flags: flags, timestamp: 1, isAutorepeat: true))
            service.process(.init(kind: up, keyCode: code, flags: 0, timestamp: 50_000_000))
            service.process(.init(kind: .keyDown, keyCode: 0, flags: 0, timestamp: 80_000_000))
            service.process(.init(kind: down, keyCode: code, flags: flags, timestamp: 100_000_000))
            service.process(.init(kind: up, keyCode: code, flags: 0, timestamp: 150_000_000))
            #expect(await events(service, count: 3) == [.pressed(at: 0), .locked(at: 0, trigger: .toggle), .released(at: 100_000_000)])
        }
    }

    @Test(.timeLimit(.minutes(1))) func capsLockStillTogglesOnEveryPhysicalPress() async {
        let service = HotkeyService(options: .init(source: .shortcut(.init(keyCode: 57, keyName: "Caps Lock")), configuration: .init(recordingMode: .toggle)), otherKeysHeld: { _ in false })
        defer { service.stop() }
        service.process(.init(kind: .flagsChanged, keyCode: 57, flags: CGEventFlags.maskAlphaShift.rawValue, timestamp: 0))
        service.process(.init(kind: .flagsChanged, keyCode: 57, flags: 0, timestamp: 1_000_000_000))
        #expect(await events(service, count: 3) == [.pressed(at: 0), .locked(at: 0, trigger: .toggle), .released(at: 1_000_000_000)])
    }

    @Test(.timeLimit(.minutes(1))) func changingModeCancelsTheActiveTakeAndLeavesTheNextPressFresh() async throws {
        let service = HotkeyService(options: .init(source: .remapped(keyCode: 80), configuration: .init(recordingMode: .toggle)), otherKeysHeld: { _ in false })
        defer { service.stop() }
        service.process(.init(kind: .keyDown, keyCode: 80, flags: 0, timestamp: 0))
        try service.switchRecordingMode(.hold)
        service.process(.init(kind: .keyDown, keyCode: 80, flags: 0, timestamp: 1_000_000_000))
        service.process(.init(kind: .keyUp, keyCode: 80, flags: 0, timestamp: 2_000_000_000))
        #expect(await events(service, count: 5) == [.pressed(at: 0), .locked(at: 0, trigger: .toggle), .cancelled(reason: .inputLost), .pressed(at: 1_000_000_000), .released(at: 2_000_000_000)])
    }
}
