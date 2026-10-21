import FnRemapKit
import Foundation

/// Decides, from the `remapFnKey` preference and what the HID system accepts, which hotkey source the taps run:
/// the remapped key (default) or the plain Fn flag. The caller moves the live service to the source returned.
@MainActor
final class FnRemapCoordinator {
    static let preferenceKey = "remapFnKey"

    static func isPreferred(_ preferences: UserDefaults = .standard) -> Bool {
        preferences.object(forKey: preferenceKey) as? Bool ?? true
    }

    private let remap: FnRemap
    private let preferences: UserDefaults
    private let guardian: (any FnGuarding)?
    private let requestTermination: (@MainActor () -> Void)?
    private var started = false
    private(set) var isActive = false

    init(remap: FnRemap, preferences: UserDefaults = .standard, guardian: (any FnGuarding)? = nil, requestTermination: (@MainActor () -> Void)? = nil) {
        self.requestTermination = requestTermination
        self.remap = remap
        self.preferences = preferences
        self.guardian = guardian
    }

    var preferred: Bool { Self.isPreferred(preferences) }

    /// What the menu checkbox shows: the preference until input has started, the real state after.
    var menuChecked: Bool { started ? isActive : preferred }

    var source: HotkeySource { isActive ? .remapped(keyCode: FnRemapMapping.fnDestinationKeyCode) : .fnFlag }

    /// At launch, once Accessibility is granted: applies the remap if preferred, and falls back to the Fn flag if that fails.
    func initialSource() -> HotkeySource {
        started = true
        if preferred, !activate() { Log.hotkey.error("fn remap unavailable, using the plain Fn key") }
        return source
    }

    /// The menu toggle. Returns the source the running service should switch to.
    func setEnabled(_ enabled: Bool) -> HotkeySource {
        guard started else {
            preferences.set(enabled, forKey: Self.preferenceKey)
            return source
        }
        if enabled {
            if activate() { preferences.set(true, forKey: Self.preferenceKey) }
        } else {
            preferences.set(false, forKey: Self.preferenceKey)
            deactivate()
        }
        return source
    }

    /// Takes the remap off. Stays active, and says so, if the HID system won't let it go.
    @discardableResult
    func deactivate() -> Bool {
        switch remap.restore() {
        case .restored, .clean:
            isActive = false
            guardian?.stop()
            return true
        case .applied, .alreadyApplied:
            return false
        case let .failed(reason):
            Log.hotkey.error("fn remap restore failed: \(reason, privacy: .public)")
            return false
        }
    }

    private func activate() -> Bool {
        switch remap.apply() {
        case .applied, .alreadyApplied:
            remap.installSignalHandlers(requestTermination: requestTermination)
            guardian?.start()
            isActive = true
            return true
        case let .failed(reason):
            Log.hotkey.error("fn remap not applied: \(reason, privacy: .public)")
            return false
        case .restored, .clean:
            return false
        }
    }
}
