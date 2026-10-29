import AppKit
import ApplicationServices
import Foundation
import MouthtypeCore

/// "Names on screen". On unless the user turned it off; an unset key reads as on, an explicit off stays off.
enum ContextNamesSetting {
    static let key = "useContextNames"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static func set(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}

/// Asks an Electron app to expose its text over Accessibility. Chromium builds its tree lazily, so Slack, VS Code and
/// Discord give nothing until a client sets `AXManualAccessibility` on the application element. The flag is set once per
/// app process, and an app that doesn't support it just ignores it.
final class ElectronAccessibility: @unchecked Sendable {
    static let shared = ElectronAccessibility()

    private let lock = NSLock()
    private var handled = Set<pid_t>()
    private var enabledInstants: [pid_t: ContinuousClock.Instant] = [:]
    private let now: @Sendable () -> ContinuousClock.Instant
    private let isElectron: @Sendable (pid_t) -> Bool
    /// Sets the flag; true when the app answered (accepted or unsupported), false when it timed out and should be retried.
    private let setFlag: @Sendable (pid_t) -> Bool

    init(
        isElectron: @escaping @Sendable (pid_t) -> Bool = ElectronAccessibility.systemIsElectron,
        setFlag: @escaping @Sendable (pid_t) -> Bool = ElectronAccessibility.systemSetFlag,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.isElectron = isElectron
        self.setFlag = setFlag
        self.now = now
    }

    /// Sets the flag when `pid` is an Electron app not handled yet. Returns whether it set it on this call.
    @discardableResult
    func enableIfNeeded(pid: pid_t?) -> Bool {
        guard let pid, pid > 0 else { return false }
        guard lock.withLock({ !handled.contains(pid) }) else { return false }
        let electron = isElectron(pid)
        let done = electron ? setFlag(pid) : true
        let setAt = now()
        guard done else { return false }
        let inserted = lock.withLock {
            let inserted = handled.insert(pid).inserted
            if inserted, electron { enabledInstants[pid] = setAt }
            return inserted
        }
        return inserted && electron
    }

    /// When the flag was set for `pid`, or nil when it never was (not Electron, failed, or not tried yet).
    func enabledAt(pid: pid_t) -> ContinuousClock.Instant? {
        lock.withLock { enabledInstants[pid] }
    }

    static func systemIsElectron(_ pid: pid_t) -> Bool {
        guard let bundle = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return false }
        return FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
    }

    static func systemSetFlag(_ pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        let result = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return result != .cannotComplete
    }
}

/// Starts the per-dictation gather of names from the focused field's text and the window title. Everything is read in
/// memory for that one dictation, nothing is stored or logged, and the work runs under `EditorHints.defaultDeadline`.
@MainActor
enum ContextNamesGatherer {
    /// What the focused app can give, injected so tests need no Accessibility. The readers block, so they run off the
    /// main thread, and the cursor read takes the instant it must finish by.
    struct Readers: Sendable {
        var cursorText: @Sendable (_ focus: FocusSnapshot, _ deadline: ContinuousClock.Instant) -> InsertionContext?
        var enableManualAccessibility: @Sendable (_ pid: pid_t?) -> Void

        static let system = Readers(
            cursorText: { EditorAccessibility.namesContext(focus: $0, deadline: $1) },
            enableManualAccessibility: { ElectronAccessibility.shared.enableIfNeeded(pid: $0) }
        )
    }

    /// Allows one cursor read at a time, apart from the editor hints' own.
    static let gate = EditorHints.ReadGate()

    /// Nil, with no reader called, unless the switch and the saved-word boost are both on, and the field isn't secure
    /// or a terminal. Nothing is read here: the focus taken at dictation start goes to the detached gather.
    static func start(
        enabled: Bool, boostEnabled: Bool, focus: FocusSnapshot, readers: Readers,
        deadline: Duration = EditorHints.defaultDeadline, readGate: EditorHints.ReadGate = gate
    ) -> Task<[VocabularyBias.Term], Never>? {
        guard enabled, boostEnabled, !focus.isSecure, EditorHintsSurface.of(bundleID: focus.bundleID) != .terminal else { return nil }
        return Task.detached {
            await gather(focus: focus, readers: readers, deadline: deadline, readGate: readGate)
        }
    }

    /// The names for one dictation. The window title is always used; the cursor read only if it answers inside
    /// `deadline`, so a stuck app costs its own source and never delays the dictation.
    nonisolated static func gather(
        focus: FocusSnapshot, readers: Readers, deadline: Duration, readGate: EditorHints.ReadGate
    ) async -> [VocabularyBias.Term] {
        guard !focus.isSecure else { return [] }
        let limit = ContinuousClock.now + deadline
        var context: InsertionContext?
        if readGate.acquire() {
            context = await EditorHints.runBlocking(until: limit, ifNotStarted: { readGate.release() }) {
                defer { readGate.release() }
                readers.enableManualAccessibility(focus.pid)
                return readers.cursorText(focus, limit)
            }
        }
        return ContextNames.terms(
            before: context?.before, after: context?.after, windowTitle: focus.windowTitle,
            excluding: [focus.appName].compactMap { $0 })
    }

    /// One task over the editor hints and the names, editor names first, or nil when neither is running.
    static func merge(
        _ first: Task<[VocabularyBias.Term], Never>?, _ second: Task<[VocabularyBias.Term], Never>?
    ) -> Task<[VocabularyBias.Term], Never>? {
        guard let first else { return second }
        guard let second else { return first }
        return Task {
            let editor = await first.value
            let names = await second.value
            var seen = Set(editor.map { $0.text.lowercased() })
            return editor + names.filter { seen.insert($0.text.lowercased()).inserted }
        }
    }
}
