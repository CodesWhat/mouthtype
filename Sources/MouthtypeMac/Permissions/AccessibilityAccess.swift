import ApplicationServices
import Foundation

/// Accessibility trust: prompts once, then polls until it is granted. The event taps are created only after
/// that, so macOS has no reason to raise an Input Monitoring prompt.
@MainActor
public final class AccessibilityAccess {
    static let promptedKey = "AccessibilityPrompted"
    static let pollInterval: Duration = .seconds(1)

    public private(set) var isGranted: Bool
    /// Called on the main actor whenever the grant changes, and once from `start()` with the current state.
    public var onChange: (@MainActor (Bool) -> Void)?

    private let defaults: UserDefaults
    private let probe: @MainActor () -> Bool
    private var polling: Task<Void, Never>?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        probe = { AXIsProcessTrusted() }
        isGranted = AXIsProcessTrusted()
    }

    init(defaults: UserDefaults, probe: @escaping @MainActor () -> Bool) {
        self.defaults = defaults
        self.probe = probe
        isGranted = probe()
    }

    /// Shows the system prompt the first time only; after that the menu line opens the pane.
    public func start() {
        isGranted = probe()
        onChange?(isGranted)
        guard !isGranted else { return }
        if !defaults.bool(forKey: Self.promptedKey) {
            defaults.set(true, forKey: Self.promptedKey)
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            Log.permissions.info("accessibility prompt shown")
        }
        poll()
    }

    public func stop() {
        polling?.cancel()
        polling = nil
    }

    private func poll() {
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, !Task.isCancelled else { return }
                if self.tick() { return }
            }
        }
    }

    /// One poll. Returns true once granted.
    func tick() -> Bool {
        let granted = probe()
        if granted != isGranted {
            isGranted = granted
            onChange?(granted)
        }
        return granted
    }

    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    public static func statusText(granted: Bool) -> String {
        granted ? "Accessibility: allowed" : "Accessibility: needed"
    }
}
