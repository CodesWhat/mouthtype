import FnRemapKit
import ApplicationServices
import CoreGraphics
import Foundation

/// `--emulation-selftest`: runs the Fn remap's off-main paths for real, with no human. It applies the remap, posts an
/// arrow through the real key tap with the hotkey forced "held" (the dictation key itself is never synthesized),
/// checks the replacement came back stamped and passed through without being emulated again, then toggles the remap
/// off and on on the live service. The replacement keys it posts are real events: a stamped Right arrow and End
/// reach whatever app is in front.
@MainActor
enum EmulationSelfTest {
    private static let rightArrow: UInt16 = 124
    private static let end: UInt16 = 119
    private static let f20: UInt16 = 90

    static func run(remap: FnRemap) async {
        guard let preferences = UserDefaults(suiteName: "com.codeswhat.mouthtype.emulation-selftest") else {
            Log.probe.error("emulation-selftest: no scratch defaults")
            return
        }
        preferences.removePersistentDomain(forName: "com.codeswhat.mouthtype.emulation-selftest")
        let coordinator = FnRemapCoordinator(remap: remap, preferences: preferences)
        var ok = true
        func check(_ label: String, _ passed: Bool) {
            if !passed { ok = false }
            Log.probe.info("emulation-selftest: \(label, privacy: .public) \(passed ? "ok" : "FAILED", privacy: .public)")
        }

        let source = coordinator.initialSource()
        check("remap applied at start (source \(String(describing: source)))", source == .remapped(keyCode: FnRemapMapping.fnDestinationKeyCode))
        Log.probe.info("emulation-selftest: mapping now \(remap.currentDescription(), privacy: .public)")
        let service = HotkeyService(options: .init(source: source))
        do {
            try service.start()
        } catch {
            Log.probe.error("emulation-selftest: taps not started: \(String(describing: error), privacy: .public)")
            _ = coordinator.deactivate()
            return
        }
        check("always-on key tap installed in remap mode", service.keyTapInstalled)
        await probe(service, check: check)
        await inputProbe(service, mode: "remap", check: check)

        // Off: the service goes back to the Fn flag source and the mapping is restored.
        let off = coordinator.setEnabled(false)
        do { try service.switchSource(off) } catch { check("switch to Fn flag source: \(error)", false) }
        check("remap off: Fn flag source, no idle key tap", service.source == .fnFlag && !service.keyTapInstalled)
        check("remap off: mapping restored", !remap.isApplied)
        Log.probe.info("emulation-selftest: mapping now \(remap.currentDescription(), privacy: .public), health \(service.health.statusText, privacy: .public)")
        check("remap off: preference false", !coordinator.preferred)
        try? await Task.sleep(for: .milliseconds(300))
        await inputProbe(service, mode: "fn-flag", check: check)

        // On again, live.
        let on = coordinator.setEnabled(true)
        do { try service.switchSource(on) } catch { check("switch to remapped source: \(error)", false) }
        check("remap on: remapped source and key tap back", service.source == on && on != .fnFlag && service.keyTapInstalled)
        check("remap on: mapping applied", remap.isApplied)
        Log.probe.info("emulation-selftest: mapping now \(remap.currentDescription(), privacy: .public), health \(service.health.statusText, privacy: .public)")
        await probe(service, check: check)

        service.stop()
        coordinator.deactivate()
        check("remap restored at end", !remap.isApplied)
        preferences.removePersistentDomain(forName: "com.codeswhat.mouthtype.emulation-selftest")
        Log.probe.info("emulation-selftest: mapping at end \(remap.currentDescription(), privacy: .public)")
        try? await Task.sleep(for: .milliseconds(500))
        Log.probe.info("emulation-selftest: \(ok ? "PASS" : "FAIL", privacy: .public), no trap")
    }

    /// With the hotkey forced held: an unstamped Right arrow must be swallowed and replaced by a stamped End, which
    /// passes through; a stamped Right arrow must pass through untouched. Nothing may be emulated twice.
    private static func probe(_ service: HotkeyService, check: (String, Bool) -> Void) async {
        let shared = service.shared
        let before = (shared.swallowed.load(ordering: .relaxed), shared.emulated.load(ordering: .relaxed), shared.stampedSeen.load(ordering: .relaxed))
        shared.hotkeyHeld.store(true, ordering: .relaxed)
        post(rightArrow, down: true, stamped: false)
        post(rightArrow, down: false, stamped: false)
        try? await Task.sleep(for: .milliseconds(300))
        let mid = (shared.swallowed.load(ordering: .relaxed), shared.emulated.load(ordering: .relaxed), shared.stampedSeen.load(ordering: .relaxed))
        check("arrow down and up swallowed (\(mid.0 - before.0))", mid.0 - before.0 == 2)
        check("End posted for both through the real path (\(mid.1 - before.1))", mid.1 - before.1 == 2)
        check("both replacements came back stamped and passed (\(mid.2 - before.2))", mid.2 - before.2 == 2)

        post(rightArrow, down: true, stamped: true)
        post(rightArrow, down: false, stamped: true)
        try? await Task.sleep(for: .milliseconds(300))
        let after = (shared.swallowed.load(ordering: .relaxed), shared.emulated.load(ordering: .relaxed), shared.stampedSeen.load(ordering: .relaxed))
        check("stamped arrows pass: not swallowed, not emulated, seen (\(after.2 - mid.2))", after.0 == mid.0 && after.1 == mid.1 && after.2 - mid.2 == 2)
        shared.hotkeyHeld.store(false, ordering: .relaxed)
        shared.pending.withLock { $0.removeAll() }
    }

    /// An unstamped F20 keyDown must bump the user-input count and a stamped one must not. Nothing is forwarded.
    private static func inputProbe(_ service: HotkeyService, mode: String, check: (String, Bool) -> Void) async {
        let shared = service.shared
        check("\(mode): input count tracked", service.userInputGeneration != nil)
        let start = shared.userInput.load(ordering: .relaxed)
        post(f20, down: true, stamped: true, flags: 0)
        post(f20, down: false, stamped: true, flags: 0)
        try? await Task.sleep(for: .milliseconds(300))
        let stamped = shared.userInput.load(ordering: .relaxed)
        check("\(mode): stamped F20 not counted (\(stamped - start))", stamped == start)
        post(f20, down: true, stamped: false, flags: 0)
        post(f20, down: false, stamped: false, flags: 0)
        try? await Task.sleep(for: .milliseconds(300))
        let real = shared.userInput.load(ordering: .relaxed)
        check("\(mode): unstamped F20 counted once (\(real - stamped))", real - stamped == 1)
        Log.probe.info("emulation-selftest: \(mode, privacy: .public) input generation \(real, privacy: .public)")
    }

    private static func post(_ keyCode: UInt16, down: Bool, stamped: Bool, flags: UInt64? = nil) {
        let source = CGEventSource(stateID: .privateState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: down) else { return }
        event.flags = CGEventFlags(rawValue: flags ?? (CGEventFlags.maskNumericPad.rawValue | CGEventFlags.maskSecondaryFn.rawValue))
        if stamped { event.setIntegerValueField(.eventSourceUserData, value: SyntheticEvents.stamp) }
        event.post(tap: .cgSessionEventTap)
    }
}
