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
    private var started = false
    private(set) var isActive = false
    /// Another app keeps rewriting the key mapping, so the remap was given up for this run.
    private(set) var conflict = false

    init(remap: FnRemap, preferences: UserDefaults = .standard, guardian: (any FnGuarding)? = nil) {
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

    /// Re-checks that the remap is still in the HID mapping and repairs it if something else removed it. When it
    /// can't be repaired the coordinator falls back to the plain Fn flag; the caller moves the service to `source`.
    /// Returns false when that fallback happened.
    func verify() -> Bool {
        guard isActive else { return true }
        switch remap.apply() {
        case .applied, .alreadyApplied:
            return true
        case .repaired:
            Log.hotkey.notice("fn remap was removed by something else and has been reapplied")
            // What the remap displaces may have changed, and the guard only knows what it was started with.
            guardian?.stop()
            guardian?.start(restoring: remap.displacedEntry)
            return true
        case .conflict:
            conflict = true
            return fallBackToFnFlag()
        case .failed, .restored, .clean:
            Log.hotkey.error("fn remap was lost and could not be repaired, using the plain Fn key")
            return fallBackToFnFlag()
        }
    }

    /// Stays remapped until the removal is confirmed: if the restore fails our entry may still be installed,
    /// and the remapped source is the one that works with it. The next tick tries again.
    private func fallBackToFnFlag() -> Bool {
        !deactivate()
    }

    /// Takes the remap off. Stays active, and says so, if the HID system won't let it go.
    @discardableResult
    func deactivate() -> Bool {
        switch remap.restore() {
        case .restored, .clean:
            isActive = false
            guardian?.stop()
            return true
        case .applied, .alreadyApplied, .repaired, .conflict:
            return false
        case let .failed(reason):
            Log.hotkey.error("fn remap restore failed: \(reason, privacy: .public)")
            return false
        }
    }

    private func activate() -> Bool {
        let outcome = remap.apply()
        switch outcome {
        case .applied, .alreadyApplied, .repaired:
            remap.installSignalHandlers()
            // A running guard keeps what it was started with, so a repair must replace it.
            if outcome == .repaired { guardian?.stop() }
            guardian?.start(restoring: remap.displacedEntry)
            conflict = false
            isActive = true
            return true
        case let .failed(reason):
            Log.hotkey.error("fn remap not applied: \(reason, privacy: .public)")
            return false
        case .restored, .clean, .conflict:
            return false
        }
    }
}
