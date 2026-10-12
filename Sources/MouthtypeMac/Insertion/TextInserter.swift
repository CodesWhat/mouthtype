// Adapted from Parrot (https://github.com/humanitas-labs/parrot, 0eb4708), MIT License, Copyright (c) 2026 Humanitas Labs.
import AppKit
import CoreGraphics
import Foundation

/// Inserts a transcript at the cursor by borrowing the clipboard: write it, post Cmd+V, restore the user's clipboard.
///
/// Call everything on the main actor. `snapshotFocus()` at dictation start, `deliver` when the text is ready.
@MainActor
public final class TextInserter {
    /// How long the target app gets to read the clipboard before it is restored.
    static let restoreDelay: TimeInterval = 0.25

    /// How long after a paste its last character still stands in for an unreadable text-before-cursor.
    static let continuationWindow: TimeInterval = 5 * 60

    private let focus: FocusReading
    private let clipboard: PasteboardSession
    private let now: @MainActor () -> Date
    private var lastText: String?
    private var lastPaste: LastPaste?

    /// What the last successful paste put in the field and where.
    private struct LastPaste {
        var pid: pid_t
        var bundleID: String?
        var element: FocusedElement?
        var finalCharacter: Character
        var date: Date
    }

    /// `syntheticStamp` goes on every event we post (`eventSourceUserData`), so the app's own taps can recognise them.
    public init(syntheticStamp: Int64) {
        self.now = { Date() }
        self.focus = AccessibilityFocusReader()
        self.clipboard = PasteboardSession(
            pasteboard: SystemPasteboard(.general),
            poster: SystemPasteEventPoster(stamp: syntheticStamp),
            restoreDelay: Self.restoreDelay
        )
    }

    init(focus: FocusReading, pasteboard: PasteboardAccess, poster: PasteEventPosting, schedule: @escaping PasteboardSession.Schedule, now: @escaping @MainActor () -> Date = { Date() }) {
        self.now = now
        self.focus = focus
        self.clipboard = PasteboardSession(
            pasteboard: pasteboard, poster: poster, restoreDelay: Self.restoreDelay, schedule: schedule
        )
    }

    public func snapshotFocus() -> FocusSnapshot {
        focus.snapshot()
    }

    /// Pastes `text` into whatever has focus now. `startFocus` only decides `focusMoved`.
    public func deliver(_ text: String, startFocus: FocusSnapshot?) async -> DeliveryResult {
        guard !text.isEmpty else {
            return DeliveryResult(method: .none, outcome: .unknown, focusMoved: false, target: nil, finalText: "")
        }
        var now = focus.snapshot()
        let secureInput = focus.isSecureInputEnabled
        let moved = startFocus?.hasChanged(to: now) ?? false

        switch DeliveryDecision.decide(now: now, secureInput: secureInput) {
        case .discardSecure:
            now.isSecure = now.isSecure || secureInput
            Log.app.info("secure field focused; transcript discarded")
            return DeliveryResult(method: .none, outcome: .secureDiscard, focusMoved: moved, target: now, finalText: "")
        case .clipboardOnly:
            lastText = text
            clipboard.copy(text)
            Log.app.info("nothing frontmost; transcript left on the clipboard")
            return DeliveryResult(method: .clipboardOnly, outcome: .unknown, focusMoved: moved, target: now, finalText: text)
        case .paste:
            lastText = text
            var before = now.element.map { focus.textBeforeCursor(of: $0) } ?? .unknown
            if case .unknown = before, let preceding = continuationCharacter(for: now) {
                before = .character(preceding)
            }
            let spaced = Spacing.spaced(text, before: before)
            guard clipboard.paste(spaced) else {
                clipboard.copy(spaced)
                Log.app.error("could not post the paste event; transcript left on the clipboard")
                return DeliveryResult(
                    method: .clipboardOnly, outcome: .failed("paste event could not be posted"),
                    focusMoved: moved, target: now, finalText: spaced
                )
            }
            if let pid = now.pid, let last = spaced.last {
                lastPaste = LastPaste(
                    pid: pid, bundleID: now.bundleID, element: now.element, finalCharacter: last, date: self.now()
                )
            }
            return DeliveryResult(method: .paste, outcome: .unknown, focusMoved: moved, target: now, finalText: spaced)
        }
    }

    /// The last character we pasted, when the text before the cursor can't be read (Electron terminals expose no
    /// Accessibility text) and the last paste went to the same app recently. Known limit: if the user typed or moved
    /// the cursor between dictations in such an app we can't know, and may add a space that isn't needed.
    private func continuationCharacter(for target: FocusSnapshot) -> Character? {
        guard let last = lastPaste, let pid = target.pid, last.pid == pid, last.bundleID == target.bundleID else { return nil }
        if let element = last.element, let other = target.element, element != other { return nil }
        let age = now().timeIntervalSince(last.date)
        guard age >= 0, age <= Self.continuationWindow else { return nil }
        return last.finalCharacter
    }

    /// Pastes the last delivered transcript again, at the current focus. Nil when nothing was delivered yet.
    public func pasteLast() async -> DeliveryResult? {
        guard let lastText else { return nil }
        return await deliver(lastText, startFocus: nil)
    }

    /// Puts the last delivered transcript on the clipboard to stay. False when nothing was delivered yet.
    public func copyLast() -> Bool {
        guard let lastText else { return false }
        clipboard.copy(lastText)
        return true
    }
}

// MARK: - Posting the paste

@MainActor
protocol PasteEventPosting: AnyObject {
    /// False when the events could not be created.
    func postPaste() -> Bool
}

@MainActor
final class SystemPasteEventPoster: PasteEventPosting {
    /// Where every synthesized event is posted. `.cgSessionEventTap` enters where hardware events enter the login
    /// session, so the event reaches the focused app exactly as a key press would.
    static let postLocation: CGEventTapLocation = .cgSessionEventTap

    /// Virtual keycode for V on ANSI layouts (kVK_ANSI_V).
    private static let keycodeV: CGKeyCode = 9

    private let stamp: Int64

    init(stamp: Int64) {
        self.stamp = stamp
    }

    /// From a private source with its flags set explicitly. An event with a nil source inherits the modifiers the
    /// user is holding, so a held Control or Fn would turn the paste into a different shortcut.
    func postPaste() -> Bool {
        let source = CGEventSource(stateID: .privateState)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: Self.keycodeV, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: Self.keycodeV, keyDown: false)
        else { return false }
        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: stamp)
            event.post(tap: Self.postLocation)
        }
        return true
    }
}

// MARK: - Clipboard

/// One representation of one pasteboard item.
struct PasteboardRepresentation: Equatable {
    var type: String
    var data: Data
}

/// Every representation of every item on a pasteboard, so text, images and copied Finder files all come back.
struct PasteboardSnapshot: Equatable {
    var items: [[PasteboardRepresentation]]
}

@MainActor
protocol PasteboardAccess: AnyObject {
    var changeCount: Int { get }
    func snapshot() -> PasteboardSnapshot
    func restore(_ snapshot: PasteboardSnapshot)
    /// Replaces the contents with `text`, plus an empty entry of each marker type on the same item.
    func write(_ text: String, markers: [String])
}

/// Borrows the clipboard for a paste and gives it back.
///
/// `paste` saves the clipboard, writes the text, posts Cmd+V and restores the saved clipboard after the delay. A
/// second paste before that restore keeps the first snapshot, so the user's own clipboard comes back, not an earlier
/// transcript. If anything else writes the clipboard during the window, that write wins and nothing is restored.
@MainActor
final class PasteboardSession {
    /// nspasteboard.org markers: clipboard managers skip items carrying these.
    static let transientMarkers = [
        "org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType", "org.nspasteboard.AutoGeneratedType",
    ]
    /// A clipboard fallback is meant to stay, but is still kept out of history.
    static let concealedMarkers = ["org.nspasteboard.ConcealedType", "org.nspasteboard.AutoGeneratedType"]

    typealias Schedule = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void

    static let mainSchedule: Schedule = { delay, work in
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            work()
        }
    }

    private let pasteboard: PasteboardAccess
    private let poster: PasteEventPosting
    private let restoreDelay: TimeInterval
    private let schedule: Schedule

    /// The user's clipboard while a restore is pending.
    private var saved: PasteboardSnapshot?
    /// The change count right after our last write.
    private var ourChangeCount = 0
    /// Bumped on every write; only the latest scheduled restore runs.
    private var generation = 0

    init(
        pasteboard: PasteboardAccess, poster: PasteEventPosting, restoreDelay: TimeInterval,
        schedule: @escaping Schedule = PasteboardSession.mainSchedule
    ) {
        self.pasteboard = pasteboard
        self.poster = poster
        self.restoreDelay = restoreDelay
        self.schedule = schedule
    }

    var isRestorePending: Bool { saved != nil }

    /// False when the paste event could not be posted; the clipboard then still holds `text` and no restore is scheduled.
    func paste(_ text: String) -> Bool {
        if saved == nil {
            saved = pasteboard.snapshot()
        }
        pasteboard.write(text, markers: Self.transientMarkers)
        ourChangeCount = pasteboard.changeCount
        generation += 1
        guard poster.postPaste() else { return false }
        let current = generation
        schedule(restoreDelay) { [weak self] in
            self?.restore(ifGeneration: current)
        }
        return true
    }

    /// Puts `text` on the clipboard to stay. Drops any pending restore, which would otherwise overwrite it.
    func copy(_ text: String) {
        saved = nil
        generation += 1
        pasteboard.write(text, markers: Self.concealedMarkers)
        ourChangeCount = pasteboard.changeCount
    }

    private func restore(ifGeneration expected: Int) {
        guard expected == generation, let snapshot = saved else { return }
        saved = nil
        guard pasteboard.changeCount == ourChangeCount else {
            Log.app.info("clipboard changed during paste; not restoring")
            return
        }
        pasteboard.restore(snapshot)
    }
}

@MainActor
final class SystemPasteboard: PasteboardAccess {
    private let pasteboard: NSPasteboard

    init(_ pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    func snapshot() -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                item.data(forType: type).map { PasteboardRepresentation(type: type.rawValue, data: $0) }
            }
        }
        return PasteboardSnapshot(items: items)
    }

    func restore(_ snapshot: PasteboardSnapshot) {
        pasteboard.clearContents()
        let items = snapshot.items.map { representations -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for representation in representations {
                item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    func write(_ text: String, markers: [String]) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        for marker in markers {
            item.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
        }
        pasteboard.writeObjects([item])
    }
}
