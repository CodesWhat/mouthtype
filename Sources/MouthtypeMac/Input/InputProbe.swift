import FnRemapKit
import AppKit
import CoreGraphics
import Foundation

/// `--globe-probe <seconds>` and `--hotkey-log <seconds>`: run the taps for a while, log every event they see
/// (category `probe`), clean up, quit. The first applies the Fn remap and so answers whether the Globe action
/// still fires; the second is the plain Fn path with no remap.
@MainActor
enum InputProbe {
    enum Mode: Equatable {
        case globeProbe(seconds: Double)
        case hotkeyLog(seconds: Double)
        case tapCycle(cycles: Int)
        case emulation
        case guardToggle
    }

    static let globeFlag = "--globe-probe"
    static let hotkeyLogFlag = "--hotkey-log"
    static let tapCycleFlag = "--tap-cycle-selftest"
    static let emulationFlag = "--emulation-selftest"
    static let guardFlag = "--fn-guard-selftest"
    static let defaultSeconds = 30.0

    static func mode(in arguments: [String]) -> Mode? {
        if let seconds = seconds(after: globeFlag, in: arguments) { return .globeProbe(seconds: seconds) }
        if let seconds = seconds(after: hotkeyLogFlag, in: arguments) { return .hotkeyLog(seconds: seconds) }
        if arguments.contains(emulationFlag) { return .emulation }
        if arguments.contains(guardFlag) { return .guardToggle }
        if let index = arguments.firstIndex(of: tapCycleFlag) {
            let requested = arguments.indices.contains(index + 1) ? Int(arguments[index + 1]) : nil
            return .tapCycle(cycles: min(20, max(1, requested ?? 3)))
        }
        return nil
    }

    private static func seconds(after flag: String, in arguments: [String]) -> Double? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        guard arguments.indices.contains(index + 1), let seconds = Double(arguments[index + 1]), seconds > 0, seconds <= 600 else {
            return defaultSeconds
        }
        return seconds
    }

    static func describe(_ sample: TapSample) -> String {
        let type = switch sample.kind {
        case .flagsChanged: "flagsChanged"
        case .keyDown: "keyDown"
        case .keyUp: "keyUp"
        }
        let fn = sample.flags & CGEventFlags.maskSecondaryFn.rawValue != 0
        return "type=\(type) keyCode=\(sample.keyCode) flags=0x\(String(sample.flags, radix: 16)) fn=\(fn)"
            + " autorepeat=\(sample.isAutorepeat) synthetic=\(sample.userData == SyntheticEvents.stamp) ts=\(sample.timestamp)"
    }

    static func run(_ mode: Mode, remap: FnRemap) async {
        switch mode {
        case let .hotkeyLog(seconds):
            Log.probe.info("hotkey-log for \(seconds, format: .fixed(precision: 0), privacy: .public) s, no remap")
            await observe(source: .fnFlag, seconds: seconds)
        case let .tapCycle(cycles):
            await cycleTaps(cycles)
        case .emulation:
            await EmulationSelfTest.run(remap: remap)
        case .guardToggle:
            await FnGuardSelfTest.run(remap: remap)
        case let .globeProbe(seconds):
            Log.probe.info("globe-probe for \(seconds, format: .fixed(precision: 0), privacy: .public) s; mapping before: \(remap.currentDescription(), privacy: .public)")
            let outcome = remap.apply()
            Log.probe.info("remap apply: \(String(describing: outcome), privacy: .public); mapping now: \(remap.currentDescription(), privacy: .public)")
            if outcome == .applied || outcome == .alreadyApplied {
                remap.installSignalHandlers()
                await observe(source: .remapped(keyCode: FnRemapMapping.fnDestinationKeyCode), seconds: seconds)
            }
            let restored = remap.restore()
            Log.probe.info("remap restore: \(String(describing: restored), privacy: .public); mapping after: \(remap.currentDescription(), privacy: .public)")
            Log.probe.info("verified mapping restored: \(!remap.isApplied, privacy: .public)")
        }
        NSApp.terminate(nil)
    }

    /// Installs and tears down the active key tap on the real tap thread, the path a press and release take.
    /// Each teardown hands a release block to that thread, so the waits give it time to run (and trap, if broken).
    private static func cycleTaps(_ cycles: Int) async {
        let service = HotkeyService()
        do {
            try service.start()
        } catch {
            Log.probe.error("tap-cycle: taps not started: \(String(describing: error), privacy: .public)")
            return
        }
        Log.probe.info("tap-cycle: flags tap up, \(cycles, privacy: .public) cycles")
        for cycle in 1...cycles {
            let installed = service.cycleKeyTapForSelfTest()
            Log.probe.info("tap-cycle \(cycle, privacy: .public): key tap installed=\(installed, privacy: .public), torn down")
            try? await Task.sleep(for: .milliseconds(250))
        }
        service.stop()
        try? await Task.sleep(for: .milliseconds(500))
        Log.probe.info("tap-cycle: finished, taps stopped, no trap")
    }

    private static func observe(source: HotkeySource, seconds: Double) async {
        let service = HotkeyService(options: .init(source: source, observesKeys: true))
        service.sampleObserver = { sample in Log.probe.info("\(describe(sample), privacy: .public)") }
        do {
            try service.start()
        } catch {
            Log.probe.error("taps not started: \(String(describing: error), privacy: .public)")
            return
        }
        let outputs = Task { @MainActor in
            for await event in service.events {
                Log.probe.info("processor output: \(String(describing: event), privacy: .public)")
            }
        }
        try? await Task.sleep(for: .seconds(seconds))
        service.stop()
        outputs.cancel()
        Log.probe.info("probe finished, taps stopped")
    }
}
