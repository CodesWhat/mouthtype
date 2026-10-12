import AppKit
import ApplicationServices
import Foundation
import QuartzCore

/// Walks the pill through its states so it can be looked at: recording on a synthetic level curve for 3 s, locked
/// for 2 s, processing for 2 s, a short message, a long one, then hidden. Runs from `--pill-demo [classic|hifi]`
/// (no skin uses the saved one). `--pill-slowmo N` slows the animations N times, and `--pill-click-test` stretches
/// the locked phase and clicks both controls with synthetic mouse events.
public enum PillDemo {
    struct Options {
        var skin: PillSkinKind?
        var slowmo: Float = 1
        var clickTest = false
    }

    static let flag = "--pill-demo"

    static func options(in arguments: [String]) -> Options? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        var options = Options()
        if index + 1 < arguments.count { options.skin = PillSkinKind(rawValue: arguments[index + 1]) }
        if let slow = arguments.firstIndex(of: "--pill-slowmo"), slow + 1 < arguments.count {
            options.slowmo = Float(arguments[slow + 1]) ?? 1
        }
        options.clickTest = arguments.contains("--pill-click-test")
        return options
    }

    @MainActor
    static func run(controller: PillController, options: Options) async {
        let original = controller.levelSource
        let start = CACurrentMediaTime()
        controller.levelSource = { syntheticLevel(at: CACurrentMediaTime() - start) }
        controller.slowAnimations(by: options.slowmo)
        controller.onControl = { control in Log.app.info("pill-demo control \(String(describing: control), privacy: .public)") }
        Log.app.info("pill-demo skin \(controller.skinKind.rawValue, privacy: .public) slowmo \(options.slowmo, privacy: .public)")

        try? await Task.sleep(for: .seconds(options.clickTest ? 2.5 : 0.2))
        mark("recording", controller)
        controller.showRecording()
        try? await Task.sleep(for: .seconds(3 * Double(options.slowmo.squareRoot())))

        mark("locked", controller)
        controller.showHandsFree()
        if options.clickTest {
            try? await Task.sleep(for: .seconds(2))
            await clickTest(controller)
            try? await Task.sleep(for: .seconds(1))
        } else {
            try? await Task.sleep(for: .seconds(2 * Double(options.slowmo.squareRoot())))
        }
        controller.levelSource = original

        mark("processing", controller)
        controller.showProcessing()
        try? await Task.sleep(for: .seconds(2 * Double(options.slowmo.squareRoot())))

        mark("message", controller)
        controller.showMessage("Too short", duration: 3)
        try? await Task.sleep(for: .seconds(3.5 * Double(options.slowmo.squareRoot())))

        mark("error", controller)
        controller.showMessage("Microphone access needed", isError: true, duration: 3)
        try? await Task.sleep(for: .seconds(3.5 * Double(options.slowmo.squareRoot())))

        mark("long", controller)
        controller.showMessage("Secure field, not pasted. Copied to the clipboard instead.", duration: 2.5)
        try? await Task.sleep(for: .seconds(8))
        controller.hide()
        Log.app.info("pill-demo hidden")
    }

    @MainActor
    private static func mark(_ phase: String, _ controller: PillController) {
        Log.app.info("pill-demo \(phase, privacy: .public) window \(controller.panel.windowNumber, privacy: .public)")
    }

    /// Hovers and clicks cancel, stop, and the empty middle of the pill, logging the frontmost app around it.
    @MainActor
    private static func clickTest(_ controller: PillController) async {
        func frontmost() -> String { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none" }
        let before = frontmost()
        Log.app.info("pill-demo click-test frontmost before \(before, privacy: .public)")
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let origin = controller.panel.frame.origin
        let frames = controller.skin.controlFrames
        // Quartz points are top-left based; the panel's are bottom-left.
        func quartz(_ rect: CGRect) -> CGPoint { CGPoint(x: origin.x + rect.midX, y: screenHeight - (origin.y + rect.midY)) }
        var targets: [(String, CGPoint)] = []
        if let cancel = frames[.cancel] { targets.append(("cancel", quartz(cancel))) }
        if let stop = frames[.stop] { targets.append(("stop", quartz(stop))) }
        let middle = CGRect(x: controller.panel.contentView?.bounds.midX ?? 0, y: PillGeometry.verticalMargin + 14, width: 0, height: 0)
        targets.append(("middle", quartz(middle)))
        for (name, point) in targets {
            CGWarpMouseCursorPosition(point)
            post(.mouseMoved, at: point)
            try? await Task.sleep(for: .milliseconds(400))
            let at = NSEvent.mouseLocation
            Log.app.info("pill-demo click-test pointer \(Int(at.x), privacy: .public),\(Int(at.y), privacy: .public) panel \(Int(origin.x), privacy: .public),\(Int(origin.y), privacy: .public) frames \(String(describing: frames), privacy: .public)")
            Log.app.info("pill-demo click-test over \(name, privacy: .public) ignoresMouseEvents \(controller.panel.ignoresMouseEvents, privacy: .public)")
            CGWarpMouseCursorPosition(point)
            post(.leftMouseDown, at: point)
            try? await Task.sleep(for: .milliseconds(150))
            post(.leftMouseUp, at: point)
            try? await Task.sleep(for: .milliseconds(400))
            let after = frontmost()
            Log.app.info("pill-demo click-test \(name, privacy: .public) frontmost after \(after, privacy: .public)")
        }
        post(.mouseMoved, at: CGPoint(x: 5, y: 5))
    }

    private static func post(_ type: CGEventType, at point: CGPoint) {
        let button: CGMouseButton = .left
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)?
            .post(tap: .cghidEventTap)
    }

    /// Syllable-like bursts under a slower swell, with a quiet gap at the start and end.
    static func syntheticLevel(at t: TimeInterval) -> Float {
        let swell = 0.5 + 0.5 * sin(t * 1.6)
        let syllables = abs(sin(t * 7.3)) * abs(sin(t * 2.9 + 1))
        let gate: Double = (t < 0.3 || t > 4.8) ? 0 : 1
        return Float(min(1, 0.15 + 0.85 * swell * syllables) * gate)
    }
}
