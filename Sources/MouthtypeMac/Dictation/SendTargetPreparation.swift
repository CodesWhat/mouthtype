import ApplicationServices
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
    /// hung app. `ElectronAccessibility` skips non-Electron apps and apps it already handled. The handle lets the paste
    /// wait for the tree to come up; nil when the app isn't one to prepare.
    @MainActor
    static func prepareSystem(_ focus: FocusSnapshot) -> SendTargetReadiness? {
        let settings = SendAfterInsertSettings()
        guard shouldEnable(focus: focus, isListed: { settings.isEnabled(bundleID: $0) }), let pid = focus.pid else { return nil }
        let enable = Task.detached(priority: .userInitiated) {
            _ = ElectronAccessibility.shared.enableIfNeeded(pid: pid)
        }
        return SendTargetReadiness(
            pid: pid, enable: enable,
            enabledAt: { ElectronAccessibility.shared.enabledAt(pid: $0) },
            probe: SendTargetReadiness.systemProbe
        )
    }
}

/// Lets a take's paste wait, briefly, for a just-enabled Electron app to build its Accessibility tree. Electron debounces
/// `AXManualAccessibility` by about two seconds, so on the first short take after opening the app the paste would
/// otherwise land before the field can be read back and the Return would be skipped.
struct SendTargetReadiness: Sendable {
    /// How long after the flag was set the wait gives up.
    static let settleLimit: Duration = .milliseconds(2500)
    static let pollInterval: Duration = .milliseconds(100)

    let pid: pid_t
    private let enable: Task<Void, Never>
    private let enabledAt: @Sendable (pid_t) -> ContinuousClock.Instant?
    private let probe: @Sendable (pid_t) -> Bool
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) async throws -> Void

    init(
        pid: pid_t, enable: Task<Void, Never>,
        enabledAt: @escaping @Sendable (pid_t) -> ContinuousClock.Instant?,
        probe: @escaping @Sendable (pid_t) -> Bool,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.pid = pid
        self.enable = enable
        self.enabledAt = enabledAt
        self.probe = probe
        self.now = now
        self.sleep = sleep
    }

    /// Returns at once unless `pid` is an Electron app whose flag was set less than `settleLimit` ago. Otherwise polls
    /// off the main actor until the focused element is readable, the limit passes, or the caller is cancelled.
    func waitUntilReady() async {
        let poll = Task.detached(priority: .userInitiated) { await self.poll() }
        await withTaskCancellationHandler {
            await poll.value
        } onCancel: {
            poll.cancel()
        }
    }

    private func poll() async {
        await enable.value
        guard let setAt = enabledAt(pid) else { return }
        let deadline = setAt + Self.settleLimit
        while !Task.isCancelled, now() < deadline {
            if probe(pid) { return }
            do { try await sleep(Self.pollInterval) } catch { return }
        }
    }

    /// True when the app answers for its focused element, which an Electron app does only once its tree exists.
    static func systemProbe(_ pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success
    }
}
