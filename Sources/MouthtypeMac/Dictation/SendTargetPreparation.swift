import Foundation

/// Gets a press-Return app ready to confirm a paste. Electron apps (the Claude desktop app, Slack, Discord) build their
/// Accessibility tree only after a client sets `AXManualAccessibility`, and they debounce it by about two seconds. Setting
/// it when the recording starts lets that pass while the user talks, so the read-back after the paste can see the field.
enum SendTargetPreparation {
    /// True when the focused app is on the press-Return list, has a real pid, and isn't in a password field.
    static func shouldEnable(focus: FocusSnapshot, isListed: (String) -> Bool) -> Bool {
        guard !focus.isSecure, let pid = focus.pid, pid > 0, let bundleID = focus.bundleID else { return false }
        return isListed(bundleID)
    }

    /// The system behavior: checks the saved list, then sets the flag off the main actor because the set can block on a
    /// hung app. `ElectronAccessibility` skips non-Electron apps and apps it already handled.
    @MainActor
    static func prepareSystem(_ focus: FocusSnapshot) {
        let settings = SendAfterInsertSettings()
        guard shouldEnable(focus: focus, isListed: { settings.isEnabled(bundleID: $0) }), let pid = focus.pid else { return }
        Task.detached(priority: .userInitiated) {
            ElectronAccessibility.shared.enableIfNeeded(pid: pid)
        }
    }
}
