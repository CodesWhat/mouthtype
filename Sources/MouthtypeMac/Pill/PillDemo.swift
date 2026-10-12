import AppKit
import ApplicationServices
import Foundation
import QuartzCore

/// Walks the pill through its states so it can be looked at: recording on a synthetic level curve for 3 s, locked
/// for 2 s, processing for 2 s, a one-line message, a two-line one, an error and a long one, then each delivery card
/// in turn, then hidden. Runs from `--pill-demo [classic|hifi]` (no skin uses the saved one). `--pill-slowmo N`
/// slows the animations N times, `--pill-click-test` stretches the locked phase and clicks both controls with
/// synthetic mouse events, and `--card-click-test` clicks a card's Copy and Undo the same way. `-textFont <name>`
/// overrides the text font for the run without saving it.
public enum PillDemo {
    struct Options {
        var skin: PillSkinKind?
        var slowmo: Float = 1
        var clickTest = false
        var cardClickTest = false
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
        options.cardClickTest = arguments.contains("--card-click-test")
        return options
    }

    @MainActor
    static func run(
        controller: PillController, cards: DeliveryCardController, presenter: DeliveryCardPresenter, options: Options
    ) async {
        if options.cardClickTest {
            await cardClickTest(cards: cards, presenter: presenter)
            return
        }
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

        let scale = Double(options.slowmo.squareRoot())
        mark("message", controller)
        controller.showMessage("Too short", duration: 3)
        try? await Task.sleep(for: .seconds(3.5 * scale))

        mark("two-line", controller)
        controller.showMessage(PillMessage("Microphone disconnected", detail: "14 seconds saved to history"), duration: 3)
        try? await Task.sleep(for: .seconds(3.5 * scale))

        mark("error", controller)
        controller.showMessage(DictationController.microphoneAccessMessage, duration: 3)
        try? await Task.sleep(for: .seconds(3.5 * scale))

        mark("long", controller)
        controller.showMessage(PillMessage(
            "The speech engine stopped responding while it was finishing the last dictation",
            detail: "Restart Mouthtype to try again, and the audio will still be saved in history", isError: true
        ), duration: 3.5)
        try? await Task.sleep(for: .seconds(4 * scale))

        for (name, card) in [
            ("card-secure", DeliveryCard.secure(sample)), ("card-nowhere", .nowhere(sample)),
            ("card-failed", .pasteFailed(longSample)), ("card-cancelled", .cancelled()),
        ] {
            controller.hide()
            Log.app.info("pill-demo \(name, privacy: .public) window \(cards.panel.windowNumber, privacy: .public)")
            presenter.present(card)
            // The pill's window id is logged too, for the shots that want the pair.
            mark(name, controller)
            try? await Task.sleep(for: .seconds(card.countdown == nil ? 4 : 3))
            if card.countdown != nil { Log.app.info("pill-demo \(name, privacy: .public) countdown still running") }
            try? await Task.sleep(for: .seconds(card.countdown == nil ? 0 : 2.5))
            presenter.dismiss()
            try? await Task.sleep(for: .seconds(0.5))
        }
        Log.app.info("pill-demo hidden")
    }

    static let sample = "Can you move the standup to three thirty and send Priya the updated agenda before the end of the day, thanks."
    static let longSample = sample + " Also remind everyone that the quarterly numbers are due Friday, and ask Marcus whether the vendor call is still on for Monday morning. If it is not, push the review to Tuesday and tell the team. One more thing, the budget sheet needs the new line items before it goes out, and Dana should confirm the travel dates with the venue by Wednesday at the latest."

    /// Clicks Copy on a failure card and Undo on a cancelled one with synthetic mouse events while another app is
    /// frontmost, logging what fired, the clipboard and the frontmost app.
    @MainActor
    private static func cardClickTest(cards: DeliveryCardController, presenter: DeliveryCardPresenter) async {
        func frontmost() -> String { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none" }
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        func quartz(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: screenHeight - point.y) }
        /// Brings Finder forward, clicks, and logs whether the click moved the frontmost app.
        func click(_ step: String, at point: CGPoint) async {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
            try? await Task.sleep(for: .milliseconds(600))
            let before = frontmost()
            CGWarpMouseCursorPosition(point)
            post(.mouseMoved, at: point)
            try? await Task.sleep(for: .milliseconds(400))
            post(.leftMouseDown, at: point)
            try? await Task.sleep(for: .milliseconds(150))
            post(.leftMouseUp, at: point)
            try? await Task.sleep(for: .milliseconds(300))
            let after = frontmost()
            Log.app.info("card-click-test \(step, privacy: .public) frontmost before \(before, privacy: .public) after \(after, privacy: .public) unchanged \(before == after, privacy: .public)")
        }
        presenter.onUndo = { Log.app.info("card-click-test undo fired") }
        presenter.onDismissed = { card in Log.app.info("card-click-test dismissed \(String(describing: card.kind), privacy: .public)") }
        try? await Task.sleep(for: .seconds(1))

        presenter.present(.pasteFailed(sample))
        try? await Task.sleep(for: .seconds(1))
        if let copy = cards.screenCenter(of: .copy) {
            await click("copy", at: quartz(copy))
            Log.app.info("card-click-test copy shows copied \(presenter.state?.copied == true, privacy: .public)")
        }
        try? await Task.sleep(for: .seconds(1.3))
        Log.app.info("card-click-test after copy card visible \(presenter.state != nil, privacy: .public)")

        presenter.present(.cancelled())
        try? await Task.sleep(for: .seconds(1))
        if let undo = cards.screenCenter(of: .undo) {
            await click("undo", at: quartz(undo))
            Log.app.info("card-click-test after undo card visible \(presenter.state != nil, privacy: .public)")
        }

        presenter.present(.pasteFailed(sample))
        try? await Task.sleep(for: .seconds(1))
        await click("dismiss", at: quartz(cards.dismissScreenCenter))
        Log.app.info("card-click-test after dismiss card visible \(presenter.state != nil, privacy: .public)")
        try? await Task.sleep(for: .seconds(0.5))
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
