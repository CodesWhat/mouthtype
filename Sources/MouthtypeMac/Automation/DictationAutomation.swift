import Foundation

extension DictationController {
    /// Starts a hands-free recording the way the toggle shortcut does: a press, then the lock. Does nothing while
    /// recording, and the press path still refuses when the app is busy, quitting or the engine isn't ready.
    func startHandsFree() async {
        guard phase != .recording else { return }
        await handle(.pressed(at: DispatchTime.now().uptimeNanoseconds))
        guard phase == .recording else { return }
        await handle(.locked(at: DispatchTime.now().uptimeNanoseconds, trigger: .toggle))
    }

    /// Stops a hands-free recording, or starts one when idle.
    func toggleHandsFree() async {
        if isHandsFree {
            stopHandsFree()
        } else {
            await startHandsFree()
        }
    }
}
