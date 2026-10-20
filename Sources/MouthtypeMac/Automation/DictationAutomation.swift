import Foundation

/// The dictation verbs a URL can send, applied in the order they arrived.
enum DictationAutomationStep: Equatable {
    case start, stop, toggle, cancel
}

extension DictationController {
    /// Queues a URL command behind the ones before it. A start suspends while the capture comes up, and a stop or
    /// cancel that follows it has to see that recording, not run ahead and find nothing to stop.
    func enqueueAutomation(_ step: DictationAutomationStep) {
        let previous = automationTail
        automationTail = Task { [self] in
            await previous?.value
            switch step {
            case .start: await startHandsFree()
            case .stop: stopHandsFree()
            case .toggle: await toggleHandsFree()
            case .cancel: await cancelHandsFree()
            }
        }
    }

    /// Starts a hands-free recording the way the toggle shortcut does: a press, then the lock. Does nothing while
    /// recording or while another start is under way, and the press path still refuses when the app is busy,
    /// quitting or the engine isn't ready.
    func startHandsFree() async {
        guard phase != .recording, !isStartReserved else { return }
        await handle(.pressed(at: DispatchTime.now().uptimeNanoseconds))
        guard phase == .recording else { return }
        await handle(.locked(at: DispatchTime.now().uptimeNanoseconds, trigger: .toggle))
        if isHandsFree { onAutomationLock?() }
    }

    /// Stops a hands-free recording, or starts one when idle. A held-key recording is left alone, same as start.
    func toggleHandsFree() async {
        if isHandsFree {
            stopHandsFree()
        } else {
            await startHandsFree()
        }
    }
}
