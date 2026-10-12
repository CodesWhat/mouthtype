import Foundation
import QuartzCore

/// Walks the pill through its states so it can be looked at: recording on a synthetic level curve for 3 s, locked
/// for 2 s, processing for 2 s, a short message, a long scrolling one, then hidden. Runs from `--pill-demo`.
public enum PillDemo {
    @MainActor
    public static func run(controller: PillController) async {
        let original = controller.levelSource
        let start = CACurrentMediaTime()
        controller.levelSource = { syntheticLevel(at: CACurrentMediaTime() - start) }
        Log.app.info("pill-demo recording")
        controller.showRecording()
        try? await Task.sleep(for: .seconds(3))

        Log.app.info("pill-demo locked")
        controller.showHandsFree()
        try? await Task.sleep(for: .seconds(2))
        controller.levelSource = original

        Log.app.info("pill-demo processing")
        controller.showProcessing()
        try? await Task.sleep(for: .seconds(2))

        Log.app.info("pill-demo message")
        controller.showMessage("Too short", duration: 2)
        try? await Task.sleep(for: .seconds(2.5))

        Log.app.info("pill-demo long message")
        controller.showMessage("Secure field, not pasted. Copied to the clipboard instead.", duration: 2.5)
        try? await Task.sleep(for: .seconds(8))
        controller.hide()
        Log.app.info("pill-demo hidden")
    }

    /// Syllable-like bursts under a slower swell, with a quiet gap at the start and end.
    static func syntheticLevel(at t: TimeInterval) -> Float {
        let swell = 0.5 + 0.5 * sin(t * 1.6)
        let syllables = abs(sin(t * 7.3)) * abs(sin(t * 2.9 + 1))
        let gate: Double = (t < 0.3 || t > 4.8) ? 0 : 1
        return Float(min(1, 0.15 + 0.85 * swell * syllables) * gate)
    }
}
