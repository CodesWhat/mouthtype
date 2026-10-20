// Adapted from Parrot (https://github.com/humanitas-labs/parrot, 0eb4708), MIT License, Copyright (c) 2026 Humanitas Labs.
import AppKit
import CoreGraphics
import Foundation
import MouthtypeCore

/// Inserts a transcript at the cursor by borrowing the clipboard: write it, post Cmd+V, restore the user's clipboard.
///
/// Call everything on the main actor. `snapshotFocus()` at dictation start, `deliver` when the text is ready.
@MainActor
public final class TextInserter {
    /// When the paste is re-read, from the moment the chord was posted.
    static let verifyOffsets: [TimeInterval] = [0.15, 0.35, 1.0]

    /// How long after a paste its last character still stands in for an unreadable text-before-cursor.
    static let continuationWindow: TimeInterval = 5 * 60

    private let chunkedPaste: @MainActor (String?) -> Bool
    private let focus: FocusReading
    private let clipboard: PasteboardSession
    private let keys: PasteKeyResolving
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let now: @MainActor () -> Date
    /// How many real key presses and clicks have happened, or nil when that isn't known.
    private let inputGeneration: @MainActor () -> UInt64?
    private let observeBoundary: @MainActor (PasteBoundaryDiagnostic) -> Void
    private let restrictedToPID: pid_t?
    private var deliveryActive = false
    private var closing = false
    private var termination: Task<Void, Never>?
    private var batchGeneration = 0
    private var lastText: String?
    private var lastPaste: LastPaste?
    /// Bumped by every delivery. A verification that finds it moved on is stale and says nothing.
    private var deliveryGeneration = 0
    private var verification: Task<Void, Never>?
    private var onVerified: (@MainActor (PasteVerification) -> Void)?

    /// What the last successful paste put in the field and where.
    private struct LastPaste {
        var pid: pid_t
        var bundleID: String?
        var element: FocusedElement?
        var finalCharacter: Character
        var date: Date
        /// The input count right after the paste; nil when unknown.
        var inputGeneration: UInt64?
    }

    /// `syntheticStamp` goes on every event we post (`eventSourceUserData`), so the app's own taps can recognise them.
    public init(syntheticStamp: Int64, inputGeneration: @escaping @MainActor () -> UInt64?, restrictedToPID: pid_t? = nil) {
        self.observeBoundary = { Log.app.info("paste boundary: \($0.metadata, privacy: .public)") }
        self.chunkedPaste = { PasteSettings.chunksEnabled($0) }
        self.now = { Date() }
        self.inputGeneration = inputGeneration
        self.restrictedToPID = restrictedToPID
        self.focus = AccessibilityFocusReader()
        self.keys = SystemPasteKeyResolver()
        self.sleep = { try await Task.sleep(for: .seconds($0)) }
        self.clipboard = PasteboardSession(
            pasteboard: SystemPasteboard(.general),
            poster: SystemPasteEventPoster(stamp: syntheticStamp, targetPID: restrictedToPID)
        )
    }

    init(
        focus: FocusReading, pasteboard: PasteboardAccess, poster: PasteEventPosting, keys: PasteKeyResolving,
        schedule: @escaping PasteboardSession.Schedule, sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in },
        now: @escaping @MainActor () -> Date = { Date() }, inputGeneration: @escaping @MainActor () -> UInt64? = { 0 },
        restrictedToPID: pid_t? = nil, chunkedPaste: @escaping @MainActor (String?) -> Bool = { _ in false },
        observeBoundary: @escaping @MainActor (PasteBoundaryDiagnostic) -> Void = { Log.app.info("paste boundary: \($0.metadata, privacy: .public)") }
    ) {
        self.observeBoundary = observeBoundary
        self.chunkedPaste = chunkedPaste
        self.now = now
        self.inputGeneration = inputGeneration
        self.restrictedToPID = restrictedToPID
        self.focus = focus
        self.keys = keys
        self.sleep = sleep
        self.clipboard = PasteboardSession(pasteboard: pasteboard, poster: poster, schedule: schedule)
    }

    /// Who hears how each paste's read-back ended. One listener; the controller.
    func observeVerification(_ handler: @escaping @MainActor (PasteVerification) -> Void) {
        onVerified = handler
    }

    /// A new dictation ends the last paste's read-back. Its row keeps "unknown".
    func cancelVerification() {
        batchGeneration += 1
        verification?.cancel()
        verification = nil
    }

    /// Returns when the current read-back has ended. For tests and the self-test.
    func waitForVerification() async {
        await verification?.value
    }

    /// Whether the user's clipboard is still waiting to be put back.
    var isRestorePending: Bool { clipboard.isRestorePending }

    /// The last transcript handed to `deliver`, whether or not it landed.
    var lastDelivered: String? { lastText }

    func restoreLast(from store: TranscriptStore) throws {
        lastText = try store.lastTranscript()
    }

    func websiteHost(for snapshot: FocusSnapshot) -> String? { focus.websiteHost(for: snapshot) }

    func editorDocumentURL(for snapshot: FocusSnapshot) -> URL? { focus.editorDocumentURL(for: snapshot) }

    func snapshotApplication() -> FocusSnapshot {
        focus.snapshotApplication()
    }

    public func snapshotFocus() -> FocusSnapshot {
        focus.snapshot()
    }

    /// The text around the cursor in the focused field, for the cleanup pass. Nil for a secure field or when the app
    /// won't say. The text is used for one cleanup run and neither stored nor logged.
    public func insertionContext() -> InsertionContext? {
        let now = focus.snapshot()
        guard !now.isSecure, !focus.isSecureInputEnabled, let element = now.element else { return nil }
        return focus.insertionContext(of: element)
    }

    func clipboardText() -> String? {
        clipboard.currentString()
    }

    func prepareForTermination() async {
        if let termination { await termination.value; return }
        closing = true
        batchGeneration += 1
        cancelVerification()
        let work = Task {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(PasteboardSession.receiptCap))
            for _ in 0..<400 {
                guard deliveryActive, clock.now < deadline else { break }
                do { try await sleep(0.02) } catch { break }
            }
            if !deliveryActive, clipboard.holdsPaste(clipboard.pasteGeneration) {
                _ = await waitForPreviousPaste(clipboard.pasteGeneration, deadline: deadline)
            }
            clipboard.restoreForTermination()
        }
        termination = work
        await work.value
    }

    /// Pastes `text` into whatever has focus now. `startFocus` only decides `focusMoved`.
    ///
    /// Automatic pastes wait for the preceding clipboard lease; long pastes also wait between parts.
    /// The read-back runs after this returns and never posts a paste again.
    public func deliver(_ text: String, startFocus: FocusSnapshot?) async -> DeliveryResult {
        guard !text.isEmpty else {
            return DeliveryResult(method: .none, outcome: .unknown, focusMoved: false, target: nil, finalText: "")
        }
        var now = focus.snapshot()
        var secureInput = focus.isSecureInputEnabled
        let moved = startFocus?.hasChanged(to: now) ?? false
        if DeliveryDecision.decide(now: now, secureInput: secureInput) == .discardSecure {
            now.isSecure = now.isSecure || secureInput
            return DeliveryResult(method: .none, outcome: .secureDiscard, focusMoved: moved, target: now, finalText: "")
        }
        guard !closing else {
            return DeliveryResult(method: .none, outcome: .failed("Mouthtype is quitting"),
                                  focusMoved: false, target: nil, finalText: text)
        }
        guard !deliveryActive else {
            return DeliveryResult(method: .none, outcome: .failed("Another paste is still in progress"),
                                  focusMoved: false, target: nil, finalText: text)
        }
        deliveryActive = true
        defer { deliveryActive = false }
        if let restrictedToPID, now.pid != restrictedToPID {
            Log.app.error("self-test focus moved; no paste or clipboard write")
            return DeliveryResult(method: .none, outcome: .failed("self-test focus moved"), focusMoved: true, target: nil, finalText: "")
        }
        let previous = clipboard.pasteGeneration
        if DeliveryDecision.decide(now: now, secureInput: secureInput) != .discardSecure,
           clipboard.holdsPaste(previous) {
            let settled = await waitForPreviousPaste(previous)
            if Task.isCancelled {
                lastText = text
                return DeliveryResult(method: .none, outcome: .failed("Paste canceled"),
                                      focusMoved: moved, target: now, finalText: text)
            }
            var checked = focus.snapshot()
            let checkedSecureInput = focus.isSecureInputEnabled
            if DeliveryDecision.decide(now: checked, secureInput: checkedSecureInput) == .discardSecure {
                checked.isSecure = checked.isSecure || checkedSecureInput
                return DeliveryResult(method: .none, outcome: .secureDiscard,
                                      focusMoved: moved || now.hasChanged(to: checked), target: checked, finalText: "")
            }
            lastText = text
            guard checked.pid == now.pid, checked.bundleID == now.bundleID, checked.element == now.element else {
                return DeliveryResult(method: .none, outcome: .failed("Focus changed before paste"),
                                      focusMoved: true, target: checked, finalText: text)
            }
            guard settled else {
                return DeliveryResult(method: .none, outcome: .failed("The previous paste has not settled. Copy this result after the app responds."),
                                      focusMoved: moved, target: checked, finalText: text)
            }
            now = checked
            secureInput = checkedSecureInput
        }
        deliveryGeneration += 1
        let generation = deliveryGeneration
        cancelVerification()

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
            if PasteTargetPolicy.refuses(role: now.role, textSettable: now.isTextSettable) {
                lastText = text
                clipboard.copy(text)
                Log.app.info("focused \(now.role ?? "element", privacy: .public) can't take text; transcript left on the clipboard")
                return DeliveryResult(method: .clipboardOnly, outcome: .unknown, focusMoved: moved, target: now, finalText: text)
            }
            let reliableReadBack = PasteTargetPolicy.unchangedProvesFailure(bundleID: now.bundleID)
            var before = now.element.map { focus.textBeforeCursor(of: $0) } ?? .unknown
            var continuation = PasteBoundaryDiagnostic.Continuation.notNeeded
            if !reliableReadBack || before == .unknown {
                continuation = continuationCheck(for: now)
                if let preceding = continuation.character { before = .character(preceding) }
            }
            let spaced = Spacing.spaced(text, before: before)
            observeBoundary(PasteBoundaryDiagnostic(
                before: before, continuation: continuation, original: text, spaced: spaced, target: now
            ))
            let keyCode = keys.pasteKeyCode()
            // Accessibility reads can wait on another app. Recheck before borrowing the clipboard or posting keys.
            let fieldBefore = PasteTargetPolicy.supportsReadBack(bundleID: now.bundleID)
                ? now.element.map { focus.readField(of: $0) } : nil
            var checked = focus.snapshot()
            let checkedSecureInput = focus.isSecureInputEnabled
            if DeliveryDecision.decide(now: checked, secureInput: checkedSecureInput) == .discardSecure {
                checked.isSecure = checked.isSecure || checkedSecureInput
                return DeliveryResult(method: .none, outcome: .secureDiscard,
                                      focusMoved: moved || now.hasChanged(to: checked), target: checked, finalText: "")
            }
            lastText = text
            guard checked.pid == now.pid, checked.bundleID == now.bundleID, checked.element == now.element else {
                Log.app.info("focus changed during paste preparation; no paste or clipboard write")
                return DeliveryResult(method: .none, outcome: .failed("Focus changed before paste"),
                                      focusMoved: true, target: checked, finalText: text)
            }
            guard let keyCode else {
                clipboard.copy(spaced)
                Log.app.error("no key types v in this keyboard layout; transcript left on the clipboard")
                return DeliveryResult(
                    method: .clipboardOnly, outcome: .failed("no paste key in this keyboard layout"),
                    focusMoved: moved, target: now, finalText: spaced
                )
            }
            let split = chunkedPaste(now.bundleID) && spaced.utf8.count > PasteChunks.byteLimit
            if split {
                guard let parts = PasteChunks.parts(spaced), inputGeneration() != nil else {
                    clipboard.copy(spaced)
                    return DeliveryResult(method: .clipboardOnly, outcome: .failed("Long paste cannot be split safely"),
                                          focusMoved: moved, target: now, finalText: spaced)
                }
                guard await pasteInParts(parts, keyCode: keyCode, target: now) else {
                    lastPaste = nil
                    return DeliveryResult(method: .paste, outcome: .partialPaste,
                                          focusMoved: moved, target: now, finalText: spaced)
                }
            } else if !clipboard.paste(spaced, keyCode: keyCode, targetPID: now.pid) {
                clipboard.copy(spaced)
                Log.app.error("could not post the paste event; transcript left on the clipboard")
                return DeliveryResult(
                    method: .clipboardOnly, outcome: .failed("paste event could not be posted"),
                    focusMoved: moved, target: now, finalText: spaced
                )
            }
            let afterInput = inputGeneration()
            if let pid = now.pid, let last = spaced.last {
                lastPaste = LastPaste(
                    pid: pid, bundleID: now.bundleID, element: now.element, finalCharacter: last, date: self.now(),
                    inputGeneration: afterInput
                )
            }
            startVerification(
                generation: generation, pasted: spaced, target: now,
                baseline: fieldBefore.map { PasteVerifier.Baseline(reading: $0, input: afterInput,
                    unchangedProvesFailure: reliableReadBack && !split) }
            )
            return DeliveryResult(
                method: .paste, outcome: .unknown, focusMoved: moved, target: now, finalText: spaced,
                verificationID: generation
            )
        }
    }

    private func waitForPreviousPaste(_ lease: Int, deadline suppliedDeadline: ContinuousClock.Instant? = nil) async -> Bool {
        let generation = batchGeneration
        let clock = ContinuousClock()
        let deadline = suppliedDeadline ?? clock.now.advanced(by: .seconds(PasteboardSession.receiptCap))
        func mayContinue() -> Bool {
            !Task.isCancelled && batchGeneration == generation && clock.now < deadline
                && (clipboard.holdsPaste(lease) || clipboard.wasRestored(lease))
        }
        do {
            let polls = Int((PasteboardSession.receiptCap / 0.02).rounded(.up))
            for _ in 0..<polls {
                guard mayContinue() else { return false }
                if clipboard.wasRestored(lease) {
                    return clipboard.firstReceiptMs != nil || clipboard.hadEarlyRead
                }
                if clipboard.firstReceiptMs != nil {
                    for _ in 0..<40 {
                        guard mayContinue() else { return false }
                        if clipboard.wasRestored(lease) { return true }
                        let reads = clipboard.readCount
                        try await sleep(PasteboardSession.receiptSettle)
                        guard mayContinue() else { return false }
                        if clipboard.readCount == reads { return true }
                    }
                    return false
                }
                if clipboard.hadEarlyRead {
                    try await sleep(PasteboardSession.unobservedDelay)
                    return mayContinue()
                }
                try await sleep(0.02)
            }
        } catch { return false }
        return false
    }

    private func pasteInParts(_ parts: [String], keyCode: CGKeyCode, target: FocusSnapshot) async -> Bool {
        clipboard.beginBatch()
        defer {
            clipboard.finishBatch()
        }
        let input = inputGeneration()
        let generation = batchGeneration
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(8))
        func mayContinue() -> Bool {
            let current = focus.snapshot()
            return !Task.isCancelled && generation == batchGeneration && clock.now < deadline
                && input != nil && inputGeneration() == input && !focus.isSecureInputEnabled && !current.isSecure
                && current.pid == target.pid && current.bundleID == target.bundleID
                && current.windowTitle == target.windowTitle && current.element == target.element
        }
        for part in parts {
            guard mayContinue(), clipboard.paste(part, keyCode: keyCode, targetPID: target.pid) else { return false }
            let lease = clipboard.pasteGeneration
            // A receipt only permits advancing the clipboard. It never proves the text was inserted.
            var read = false
            for _ in 0..<50 {
                guard mayContinue(), clipboard.holdsPaste(lease) else { return false }
                if clipboard.firstReceiptMs != nil { read = true; break }
                do { try await sleep(0.02) } catch { return false }
            }
            guard read else { return false }
            var settled = false
            for _ in 0..<40 {
                let reads = clipboard.readCount
                do { try await sleep(PasteboardSession.receiptSettle) } catch { return false }
                guard mayContinue(), clipboard.holdsPaste(lease) else { return false }
                if clipboard.readCount == reads { settled = true; break }
            }
            guard settled else { return false }
        }
        return true
    }

    /// Re-reads the field after the chord and reports. A task of its own so `deliver` doesn't wait for it.
    private func startVerification(generation: Int, pasted: String, target: FocusSnapshot, baseline: PasteVerifier.Baseline?) {
        let offsets = Self.verifyOffsets
        verification = Task { [weak self] in
            var observations: [PasteVerifier.Observation] = []
            var elapsed: TimeInterval = 0
            for offset in offsets {
                do { try await self?.sleep(offset - elapsed) } catch { return }
                elapsed = offset
                guard let self, !Task.isCancelled, self.deliveryGeneration == generation else { return }
                // Without a trustworthy field baseline there is nothing to compare with; wait the last read out
                // so the receipt is in.
                guard let baseline else { continue }
                let observation = self.observe(target)
                observations.append(observation)
                if PasteVerifier.confirms(observation, baseline: baseline, pasted: pasted) { break }
            }
            guard let self, !Task.isCancelled, self.deliveryGeneration == generation else { return }
            let verdict = PasteVerifier.judge(baseline: baseline, pasted: pasted, observations: observations, expected: offsets.count)
            Log.app.info("paste read-back: \(verdict.storeOutcome, privacy: .public)")
            self.onVerified?(PasteVerification(id: generation, verdict: verdict, receiptMs: self.clipboard.firstReceiptMs))
        }
    }

    private func observe(_ target: FocusSnapshot) -> PasteVerifier.Observation {
        let snapshot = focus.snapshot()
        guard let element = target.element, snapshot.pid == target.pid, snapshot.element == element, !snapshot.isSecure else {
            return PasteVerifier.Observation(reading: nil, focusSame: false, input: inputGeneration())
        }
        // The input count goes last, so a key pressed during the read counts.
        let reading = focus.readField(of: element)
        return PasteVerifier.Observation(reading: reading, focusSame: true, input: inputGeneration())
    }

    /// The last character we pasted, when the text before the cursor can't be read (Electron terminals expose no
    /// Accessibility text), the last paste went to the same app recently, and no key or click has happened since.
    /// When the input count is unknown the answer is no: a missing space is cheaper than a stray one.
    private func continuationCheck(for target: FocusSnapshot) -> PasteBoundaryDiagnostic.Continuation {
        guard let last = lastPaste else { return .noPreviousPaste }
        guard let pid = target.pid, last.pid == pid, last.bundleID == target.bundleID else { return .targetChanged }
        if let element = last.element, let other = target.element, element != other { return .elementChanged }
        let age = now().timeIntervalSince(last.date)
        guard age >= 0, age <= Self.continuationWindow else { return .outsideWindow }
        guard let recorded = last.inputGeneration, let current = inputGeneration() else { return .inputUnavailable }
        guard current == recorded else { return .inputChanged }
        return .available(last.finalCharacter)
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
    /// Posts Cmd plus `keyCode`. False when the events could not be created.
    func postPaste(keyCode: CGKeyCode, targetPID: pid_t?) -> Bool
}

@MainActor
final class SystemPasteEventPoster: PasteEventPosting {
    private let stamp: Int64
    private let targetPID: pid_t?
    private let post: @MainActor (CGEvent, pid_t) -> Void

    init(stamp: Int64, targetPID: pid_t? = nil,
         post: @escaping @MainActor (CGEvent, pid_t) -> Void = { event, pid in event.postToPid(pid) }) {
        self.stamp = stamp
        self.targetPID = targetPID
        self.post = post
    }

    /// From a private source with its flags set explicitly. An event with a nil source inherits the modifiers the
    /// user is holding, so a held Control or Fn would turn the paste into a different shortcut.
    func postPaste(keyCode: CGKeyCode, targetPID requestedPID: pid_t?) -> Bool {
        guard let destination = targetPID ?? requestedPID, destination > 0 else { return false }
        let source = CGEventSource(stateID: .privateState)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }
        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: stamp)
            post(event, destination)
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
    func currentString() -> String?
    func restore(_ snapshot: PasteboardSnapshot)
    /// Replaces the contents with `text`, plus an empty entry of each marker type on the same item.
    func write(_ text: String, markers: [String])
    /// Like `write`, but the text is a promise: `onRead` runs when something reads it, on whatever thread the
    /// pasteboard calls back on. Must be `@Sendable` and must not touch main-actor state directly.
    func writePromise(_ text: String, markers: [String], onRead: @escaping @Sendable () -> Void)
}

extension PasteboardAccess {
    func currentString() -> String? { nil }
}

/// The reads of one paste's promise, kept where the pasteboard's callback thread can reach them.
///
/// A read counts as a receipt only once the chord has been posted: a clipboard manager that reads the promise first
/// has already taken the data, so the target's own read will not call back, and the session falls back to a fixed
/// delay. A read after the chord is evidence the target read it, not proof; a clipboard manager can read late too.
final class PasteReceipts: @unchecked Sendable {
    private let lock = NSLock()
    private var armedAt: UInt64?
    private var firstAt: UInt64?
    private var early = 0
    private var reads = 0

    /// Called right after the chord was posted. Returns how many reads came before it.
    func arm() -> Int {
        lock.withLock {
            armedAt = DispatchTime.now().uptimeNanoseconds
            return early
        }
    }

    /// Called from the pasteboard's callback, on any thread. True when the read counts as a receipt.
    func read() -> Bool {
        lock.withLock {
            guard armedAt != nil else {
                early += 1
                return false
            }
            reads += 1
            if firstAt == nil { firstAt = DispatchTime.now().uptimeNanoseconds }
            return true
        }
    }

    var readCount: Int { lock.withLock { reads } }
    var hadEarlyRead: Bool { lock.withLock { early > 0 } }

    /// Chord to first counted read, in whole ms.
    var firstReceiptMs: Int? {
        lock.withLock {
            guard let armedAt, let firstAt else { return nil }
            return Int((Double(firstAt &- armedAt) / 1_000_000).rounded())
        }
    }
}

/// Borrows the clipboard for a paste and gives it back.
///
/// `paste` saves the clipboard, publishes the text as a promise, posts the chord and restores the saved clipboard
/// once the target has read it: 200 ms after the last read, or after a cap if nothing ever reads it. A second paste
/// before that restore keeps the first snapshot, so the user's own clipboard comes back, not an earlier transcript.
/// If anything else writes the clipboard during the window, that write wins and nothing is restored.
@MainActor
final class PasteboardSession {
    /// nspasteboard.org markers: clipboard managers skip items carrying these.
    static let transientMarkers = [
        "org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType", "org.nspasteboard.AutoGeneratedType",
    ]
    /// A clipboard fallback is meant to stay, but is still kept out of history.
    static let concealedMarkers = ["org.nspasteboard.ConcealedType", "org.nspasteboard.AutoGeneratedType"]

    /// How long after the last read the clipboard goes back.
    static let receiptSettle: TimeInterval = 0.2
    /// How long a paste nobody read keeps the clipboard.
    static let receiptCap: TimeInterval = 8
    /// The restore delay when a read came before the chord and so no receipt can follow.
    static let unobservedDelay: TimeInterval = 0.25

    typealias Schedule = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void

    static let mainSchedule: Schedule = { delay, work in
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            work()
        }
    }

    private let pasteboard: PasteboardAccess
    private let poster: PasteEventPosting
    private let schedule: Schedule

    /// The user's clipboard while a restore is pending.
    private var saved: PasteboardSnapshot?
    /// The change count right after our last write.
    private var ourChangeCount = 0
    /// Bumped on every write; only the latest scheduled restore runs.
    private var generation = 0
    /// Bumped on every receipt; of the settle timers, only the latest runs.
    private var receiptCount = 0
    private var receipts: PasteReceipts?
    private var holdingRestore = false
    private var restoredGeneration: Int?

    init(pasteboard: PasteboardAccess, poster: PasteEventPosting, schedule: @escaping Schedule = PasteboardSession.mainSchedule) {
        self.pasteboard = pasteboard
        self.poster = poster
        self.schedule = schedule
    }

    var isRestorePending: Bool { saved != nil }

    var pasteGeneration: Int { generation }
    var readCount: Int { receipts?.readCount ?? 0 }
    var hadEarlyRead: Bool { receipts?.hadEarlyRead ?? false }

    func holdsPaste(_ expected: Int) -> Bool {
        generation == expected && saved != nil && pasteboard.changeCount == ourChangeCount
    }

    func wasRestored(_ expected: Int) -> Bool {
        generation == expected && restoredGeneration == expected && pasteboard.changeCount == ourChangeCount
    }

    func beginBatch() { holdingRestore = true }

    func finishBatch() {
        holdingRestore = false
        let current = generation
        schedule(firstReceiptMs == nil ? Self.receiptCap : Self.receiptSettle) { [weak self] in
            self?.restore(ifGeneration: current)
        }
    }

    /// Chord to first read of the current paste, in ms; nil until something read it.
    var firstReceiptMs: Int? { receipts?.firstReceiptMs }

    /// The user's clipboard text. While a restore is pending and nothing else has written, the live pasteboard holds
    /// our own paste, so the saved snapshot is the truth; a write by anyone else wins, as it does in `restore`.
    func currentString() -> String? {
        if let saved, pasteboard.changeCount == ourChangeCount {
            let plain = NSPasteboard.PasteboardType.string.rawValue
            guard let data = saved.items.first?.first(where: { $0.type == plain })?.data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        return pasteboard.currentString()
    }

    /// False when the paste event could not be posted; the clipboard then still holds `text` and no restore is scheduled.
    func paste(_ text: String, keyCode: CGKeyCode, targetPID: pid_t?) -> Bool {
        if saved == nil || pasteboard.changeCount != ourChangeCount {
            saved = pasteboard.snapshot()
        }
        generation += 1
        restoredGeneration = nil
        receiptCount = 0
        let current = generation
        let receipts = PasteReceipts()
        self.receipts = receipts
        pasteboard.writePromise(text, markers: Self.transientMarkers, onRead: Self.readHandler(receipts, session: self, generation: current))
        ourChangeCount = pasteboard.changeCount
        guard poster.postPaste(keyCode: keyCode, targetPID: targetPID) else { return false }
        if receipts.arm() > 0 {
            Log.app.info("clipboard read before the paste chord; restoring on a fixed delay")
            schedule(Self.unobservedDelay) { [weak self] in
                self?.restore(ifGeneration: current)
            }
        } else {
            schedule(Self.receiptCap) { [weak self] in
                self?.restore(ifGeneration: current)
            }
        }
        return true
    }

    /// What the pasteboard runs when the promise is read. Nonisolated and `@Sendable` on purpose: the callback can
    /// arrive off the main thread, and a closure formed in this main-actor class would otherwise inherit its
    /// isolation and trap there. It stamps the read where any thread can, then hops to the main actor by name.
    nonisolated private static func readHandler(_ receipts: PasteReceipts, session: PasteboardSession, generation: Int) -> @Sendable () -> Void {
        { [weak session] in
            guard receipts.read() else { return }
            Task { @MainActor in session?.receiptArrived(generation: generation) }
        }
    }

    private func receiptArrived(generation expected: Int) {
        guard expected == generation, saved != nil else { return }
        receiptCount += 1
        let count = receiptCount
        schedule(Self.receiptSettle) { [weak self] in
            self?.restore(ifGeneration: expected, receiptCount: count)
        }
    }

    /// Puts `text` on the clipboard to stay. Drops any pending restore, which would otherwise overwrite it.
    func copy(_ text: String) {
        saved = nil
        generation += 1
        restoredGeneration = nil
        receipts = nil
        pasteboard.write(text, markers: Self.concealedMarkers)
        ourChangeCount = pasteboard.changeCount
    }

    func restoreForTermination() {
        holdingRestore = false
        restore(ifGeneration: generation)
        saved = nil
        generation += 1
        receipts = nil
        restoredGeneration = nil
    }

    private func restore(ifGeneration expected: Int, receiptCount expectedCount: Int? = nil) {
        guard !holdingRestore, expected == generation, let snapshot = saved else { return }
        if let expectedCount, expectedCount != receiptCount { return }
        saved = nil
        guard pasteboard.changeCount == ourChangeCount else {
            Log.app.info("clipboard changed during paste; not restoring")
            return
        }
        pasteboard.restore(snapshot)
        ourChangeCount = pasteboard.changeCount
        restoredGeneration = expected
    }
}

/// The promise itself: an object the pasteboard asks for the text when something reads it.
private final class PromiseProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let text: String
    private let onRead: @Sendable () -> Void
    private let lock = NSLock()
    private var ignoring = false

    init(text: String, onRead: @escaping @Sendable () -> Void) {
        self.text = text
        self.onRead = onRead
    }

    /// Our own reads of the clipboard are not the target's.
    func ignoringReads<T>(_ body: () -> T) -> T {
        lock.withLock { ignoring = true }
        defer { lock.withLock { ignoring = false } }
        return body()
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        item.setString(text, forType: type)
        let own = lock.withLock { ignoring }
        PasteCallbackProbe.shared.record(onMain: Thread.isMainThread)
        if !own { onRead() }
    }
}

/// Which thread the pasteboard called the promise back on, for the self-test and the log.
final class PasteCallbackProbe: @unchecked Sendable {
    static let shared = PasteCallbackProbe()
    private let lock = NSLock()
    private var last: Bool?

    func record(onMain: Bool) { lock.withLock { last = onMain } }
    var lastCallbackWasOnMain: Bool? { lock.withLock { last } }
}

@MainActor
final class SystemPasteboard: PasteboardAccess {
    private let pasteboard: NSPasteboard
    /// The pasteboard doesn't promise to keep its provider alive.
    private var provider: PromiseProvider?

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

    func currentString() -> String? {
        guard let provider else { return pasteboard.string(forType: .string) }
        return provider.ignoringReads { pasteboard.string(forType: .string) }
    }

    func restore(_ snapshot: PasteboardSnapshot) {
        pasteboard.clearContents()
        provider = nil
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
        provider = nil
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        for marker in markers {
            item.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
        }
        pasteboard.writeObjects([item])
    }

    func writePromise(_ text: String, markers: [String], onRead: @escaping @Sendable () -> Void) {
        pasteboard.clearContents()
        let provider = PromiseProvider(text: text, onRead: onRead)
        self.provider = provider
        let item = NSPasteboardItem()
        for marker in markers {
            item.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
        }
        item.setDataProvider(provider, forTypes: [.string])
        pasteboard.writeObjects([item])
    }
}

/// Only fixed categories and process IDs survive construction. No field or transcript text is retained.
struct PasteBoundaryDiagnostic: Equatable {
    enum Continuation {
        case notNeeded, noPreviousPaste, targetChanged, elementChanged, outsideWindow, inputUnavailable, inputChanged
        case available(Character)

        var character: Character? {
            if case let .available(character) = self { return character }
            return nil
        }

        var reason: String {
            switch self {
            case .notNeeded: "not-needed"
            case .noPreviousPaste: "no-previous-paste"
            case .targetChanged: "target-changed"
            case .elementChanged: "element-changed"
            case .outsideWindow: "outside-window"
            case .inputUnavailable: "input-unavailable"
            case .inputChanged: "input-changed"
            case .available: "available"
            }
        }
    }

    private let source: String
    private let preceding: String
    private let continuation: String
    private let separator: String
    private let frontmostPID: pid_t?
    private let focusedOwnerPID: pid_t?

    init(before: TextBeforeCursor, continuation: Continuation, original: String, spaced: String, target: FocusSnapshot) {
        source = continuation.character != nil ? "continuation" : (before == .unknown ? "unknown" : "accessibility")
        preceding = before.kind
        self.continuation = continuation.reason
        separator = spaced == original ? "none" : (spaced.hasPrefix("\n") ? "newline" : "space")
        frontmostPID = target.pid
        focusedOwnerPID = target.focusedOwnerPID
    }

    var metadata: String {
        "source=\(source) preceding=\(preceding) continuation=\(continuation) separator=\(separator) "
            + "frontmostPID=\(frontmostPID.map(String.init) ?? "unknown") focusedOwnerPID=\(focusedOwnerPID.map(String.init) ?? "unknown")"
    }
}
