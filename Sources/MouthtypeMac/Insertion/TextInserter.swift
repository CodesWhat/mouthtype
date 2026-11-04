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
    /// When the paste is re-read, from the moment the chord was posted. The third read catches a slow target (an IDE, a
    /// remote desktop) well inside the clipboard's field hold, so its clipboard goes back as soon as the text shows.
    static let verifyOffsets: [TimeInterval] = [0.15, 0.35, 0.65, 1.0]

    /// How long after a paste its last character still stands in for an unreadable text-before-cursor.
    static let continuationWindow: TimeInterval = 5 * 60

    private let chunkedPaste: @MainActor (String?) -> Bool
    private let focus: FocusReading
    private let clipboard: PasteboardSession
    private let keys: PasteKeyResolving
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    /// Monotonic, so a wall-clock jump (sleep/wake, NTP) can neither expire nor stretch a deadline.
    private let now: @MainActor () -> ContinuousClock.Instant
    /// How many real key presses and clicks have happened, or nil when that isn't known.
    private let inputGeneration: @MainActor () -> UInt64?
    private let observeBoundary: @MainActor (PasteBoundaryDiagnostic) -> Void
    private let restrictedToPID: pid_t?
    /// Whether the user opted this app (by bundle ID) into "Press Return after inserting".
    private let sendsReturn: @MainActor (String) -> Bool
    /// A Return waiting on the read-back's verdict for one delivery.
    private struct ArmedReturn {
        var generation: Int
        var pid: pid_t
        var bundleID: String
        var element: FocusedElement
        /// The real key and click count right after the paste, and when the paste went out.
        var input: UInt64
        var pastedAt: ContinuousClock.Instant
    }
    /// How long after the paste chord a Return may still go out.
    static let returnWindow: TimeInterval = 2
    /// How long after the paste an unconfirmed send (a terminal) waits before its Return.
    static let unconfirmedSendDelay: TimeInterval = 0.25
    /// The pending unconfirmed send, so a new recording or delivery can cancel it. Tests await it.
    private(set) var unconfirmedSend: Task<Void, Never>?
    private var pasteStamp: (generation: Int, input: UInt64?, at: ContinuousClock.Instant)?
    private var armedReturn: ArmedReturn?
    /// The newest read-back verdict, so a send armed after it arrived still sees it.
    private var lastVerdict: PasteVerification?
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
        var date: ContinuousClock.Instant
        /// The input count right after the paste; nil when unknown.
        var inputGeneration: UInt64?
    }

    /// `syntheticStamp` goes on every event we post (`eventSourceUserData`), so the app's own taps can recognise them.
    public init(syntheticStamp: Int64, inputGeneration: @escaping @MainActor () -> UInt64?, restrictedToPID: pid_t? = nil) {
        self.observeBoundary = { Log.app.info("paste boundary: \($0.metadata, privacy: .public)") }
        self.sendsReturn = { SendAfterInsertSettings().isEnabled(bundleID: $0) }
        self.chunkedPaste = { PasteSettings.chunksEnabled($0) }
        self.now = { ContinuousClock.now }
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
        now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }, inputGeneration: @escaping @MainActor () -> UInt64? = { 0 },
        restrictedToPID: pid_t? = nil, chunkedPaste: @escaping @MainActor (String?) -> Bool = { _ in false },
        sendsReturn: @escaping @MainActor (String) -> Bool = { _ in false },
        observeBoundary: @escaping @MainActor (PasteBoundaryDiagnostic) -> Void = { Log.app.info("paste boundary: \($0.metadata, privacy: .public)") }
    ) {
        self.observeBoundary = observeBoundary
        self.sendsReturn = sendsReturn
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
        armedReturn = nil
        cancelUnconfirmedSend()
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

    func websiteHostReader(for snapshot: FocusSnapshot) -> (@Sendable () -> String?)? { focus.websiteHostReader(for: snapshot) }

    func snapshotApplication() -> FocusSnapshot {
        focus.snapshotApplication()
    }

    public func snapshotFocus() -> FocusSnapshot {
        focus.snapshot()
    }

    /// The text around the cursor in the focused field, for the cleanup pass. Nil for a secure field or when the app
    /// won't say. The text is used for one cleanup run and neither stored nor logged.
    public func insertionContext() -> InsertionContext? {
        let now = focus.recheck()
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
            let deadline = now() + .seconds(PasteboardSession.receiptCap)
            for _ in 0..<400 {
                guard deliveryActive, now() < deadline else { break }
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
            let blockedBySecureInput = secureInput && !now.isSecure
            now.isSecure = now.isSecure || secureInput
            return DeliveryResult(
                method: .none, outcome: .secureDiscard, focusMoved: moved, target: now, finalText: "",
                secureInputBlocked: blockedBySecureInput)
        }
        guard !closing else {
            return DeliveryResult(
                method: .none, outcome: .failed("Mouthtype is quitting"),
                focusMoved: false, target: nil, finalText: text)
        }
        guard !deliveryActive else {
            return DeliveryResult(
                method: .none, outcome: .failed("Another paste is still in progress"),
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
            clipboard.holdsPaste(previous)
        {
            let settled = await waitForPreviousPaste(previous)
            if Task.isCancelled {
                lastText = text
                return DeliveryResult(
                    method: .none, outcome: .failed("Paste canceled"),
                    focusMoved: moved, target: now, finalText: text)
            }
            var checked = focus.snapshot()
            let checkedSecureInput = focus.isSecureInputEnabled
            if DeliveryDecision.decide(now: checked, secureInput: checkedSecureInput) == .discardSecure {
                let blockedBySecureInput = checkedSecureInput && !checked.isSecure
                checked.isSecure = checked.isSecure || checkedSecureInput
                return DeliveryResult(
                    method: .none, outcome: .secureDiscard,
                    focusMoved: moved || now.hasChanged(to: checked), target: checked, finalText: "",
                    secureInputBlocked: blockedBySecureInput)
            }
            lastText = text
            guard checked.pid == now.pid, checked.bundleID == now.bundleID, checked.element == now.element else {
                return DeliveryResult(
                    method: .none, outcome: .failed("Focus changed before paste"),
                    focusMoved: true, target: checked, finalText: text)
            }
            guard settled else {
                return DeliveryResult(
                    method: .none, outcome: .failed("The previous paste has not settled. Copy this result after the app responds."),
                    focusMoved: moved, target: checked, finalText: text)
            }
            now = checked
            secureInput = checkedSecureInput
        }
        deliveryGeneration += 1
        let generation = deliveryGeneration
        lastVerdict = nil
        cancelVerification()

        switch DeliveryDecision.decide(now: now, secureInput: secureInput) {
        case .discardSecure:
            let blockedBySecureInput = secureInput && !now.isSecure
            now.isSecure = now.isSecure || secureInput
            Log.app.info("secure field focused; transcript discarded")
            return DeliveryResult(
                method: .none, outcome: .secureDiscard, focusMoved: moved, target: now, finalText: "",
                secureInputBlocked: blockedBySecureInput)
        case .clipboardOnly:
            lastText = text
            clipboard.copy(text)
            Log.app.info("nothing frontmost; transcript left on the clipboard")
            return DeliveryResult(method: .clipboardOnly, outcome: .unknown, focusMoved: moved, target: now, finalText: text)
        case .paste:
            if now.focusOwnerDiffersFromFrontmost {
                return leaveOnClipboard(text, because: "focus belongs to another process than the frontmost app", moved: moved, target: now)
            }
            if PasteTargetPolicy.refuses(role: now.role, textSettable: now.isTextSettable) {
                lastText = text
                clipboard.copy(text)
                Log.app.info("focused \(now.role ?? "element", privacy: .public) can't take text; transcript left on the clipboard")
                return DeliveryResult(method: .clipboardOnly, outcome: .unknown, focusMoved: moved, target: now, finalText: text)
            }
            let reliableReadBack = PasteTargetPolicy.unchangedProvesFailure(bundleID: now.bundleID)
            // Read fresh here: the cleanup pass awaited since its read, and the field can change without any key or click.
            var axReads = now.element != nil
            var before = now.element.map { element in focus.prePaste { focus.textBeforeCursor(of: element) } } ?? .unknown
            var continuation = PasteBoundaryDiagnostic.Continuation.notNeeded
            if !reliableReadBack || before == .unknown {
                continuation = continuationCheck(for: now)
                if let preceding = continuation.character { before = .character(preceding) }
            }
            let spaced = Spacing.spaced(text, before: before)
            observeBoundary(
                PasteBoundaryDiagnostic(
                    before: before, continuation: continuation, original: text, spaced: spaced, target: now
                ))
            let keyCode = keys.pasteKeyCode()
            // Accessibility reads can wait on another app. Recheck before borrowing the clipboard or posting keys.
            // The baseline only feeds the read-back, so it is read only when someone is listening for the verdict.
            let fieldBefore =
                onVerified != nil && PasteTargetPolicy.supportsReadBack(bundleID: now.bundleID)
                ? now.element.map { element in focus.prePaste { focus.readField(of: element) } } : nil
            axReads = axReads || fieldBefore != nil
            // With the field's text in hand the read-back can tell when the target has taken the paste, so the
            // clipboard waits for that instead of trusting the first read of the promise, which may be a sync's.
            let holdForField = fieldBefore?.value != nil
            let checkedSecureInput = focus.isSecureInputEnabled
            var checked = now
            if axReads {
                let light = focus.prePaste { focus.recheck() }
                let steady =
                    light.pid == now.pid && light.bundleID == now.bundleID && light.element == now.element
                    && !light.isSecure && !light.focusOwnerDiffersFromFrontmost && !checkedSecureInput
                // Anything unsteady gets the full read, so the guards and the reported target see the whole snapshot.
                if !steady {
                    checked = focus.snapshot()
                    // The full read can only add detail. A secure field or owner mismatch the light read saw stands
                    // even if the full read's secure or ancestry lookups fail.
                    checked.isSecure = checked.isSecure || light.isSecure
                    if light.focusOwnerDiffersFromFrontmost {
                        checked.focusedOwnerPID = light.focusedOwnerPID
                        checked.focusedApplicationPID = light.focusedApplicationPID
                    }
                }
            }
            if DeliveryDecision.decide(now: checked, secureInput: checkedSecureInput) == .discardSecure {
                let blockedBySecureInput = checkedSecureInput && !checked.isSecure
                checked.isSecure = checked.isSecure || checkedSecureInput
                return DeliveryResult(
                    method: .none, outcome: .secureDiscard,
                    focusMoved: moved || now.hasChanged(to: checked), target: checked, finalText: "",
                    secureInputBlocked: blockedBySecureInput)
            }
            if checked.focusOwnerDiffersFromFrontmost {
                return leaveOnClipboard(
                    text, because: "focus moved to another process during paste preparation",
                    moved: moved || now.hasChanged(to: checked), target: checked)
            }
            lastText = text
            guard checked.pid == now.pid, checked.bundleID == now.bundleID, checked.element == now.element else {
                Log.app.info("focus changed during paste preparation; no paste or clipboard write")
                return DeliveryResult(
                    method: .none, outcome: .failed("Focus changed before paste"),
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
                    return DeliveryResult(
                        method: .clipboardOnly, outcome: .failed("Long paste cannot be split safely"),
                        focusMoved: moved, target: now, finalText: spaced)
                }
                guard await pasteInParts(parts, transcript: spaced, keyCode: keyCode, target: now) else {
                    lastPaste = nil
                    return DeliveryResult(
                        method: .paste, outcome: .partialPaste,
                        focusMoved: moved, target: now, finalText: spaced)
                }
            } else if !clipboard.paste(spaced, keyCode: keyCode, targetPID: now.pid, holdForField: holdForField) {
                clipboard.copy(spaced)
                Log.app.error("could not post the paste event; transcript left on the clipboard")
                return DeliveryResult(
                    method: .clipboardOnly, outcome: .failed("paste event could not be posted"),
                    focusMoved: moved, target: now, finalText: spaced
                )
            }
            let afterInput = inputGeneration()
            pasteStamp = (generation, afterInput, self.now())
            if let pid = now.pid, let last = spaced.last {
                lastPaste = LastPaste(
                    pid: pid, bundleID: now.bundleID, element: now.element, finalCharacter: last, date: self.now(),
                    inputGeneration: afterInput
                )
            }
            startVerification(
                generation: generation, pasted: spaced, target: now, lease: clipboard.pasteGeneration,
                baseline: fieldBefore.map {
                    PasteVerifier.Baseline(
                        reading: $0, input: afterInput,
                        unchangedProvesFailure: reliableReadBack && !split)
                }
            )
            return DeliveryResult(
                method: .paste, outcome: .unknown, focusMoved: moved, target: now, finalText: spaced,
                verificationID: generation, transcriptStaysOnClipboard: clipboard.transcriptStays
            )
        }
    }

    private func leaveOnClipboard(_ text: String, because reason: String, moved: Bool, target: FocusSnapshot) -> DeliveryResult {
        lastText = text
        clipboard.copy(text)
        Log.app.info("\(reason, privacy: .public); transcript left on the clipboard")
        return DeliveryResult(method: .clipboardOnly, outcome: .unknown, focusMoved: moved, target: target, finalText: text)
    }

    private func waitForPreviousPaste(_ lease: Int, deadline suppliedDeadline: ContinuousClock.Instant? = nil) async -> Bool {
        let generation = batchGeneration
        let deadline = suppliedDeadline ?? now() + .seconds(PasteboardSession.receiptCap)
        func mayContinue() -> Bool {
            !Task.isCancelled && batchGeneration == generation && now() < deadline
                && (clipboard.holdsPaste(lease) || clipboard.wasRestored(lease))
        }
        // A paste into a readable field keeps the clipboard until the field shows its text; the receipts settling is not
        // the end of the lease while that hold is on. Bounded by the same deadline.
        func holdLifted() async throws -> Bool {
            // The hold lifts by `fieldHoldCap` at the latest; the poll bound is that, with room, so a hold that never
            // lifts can't keep this waiting.
            let polls = Int(((PasteboardSession.fieldHoldCap + 0.5) / 0.02).rounded(.up))
            for _ in 0..<polls where clipboard.fieldHeld {
                guard mayContinue() else { return false }
                try await sleep(0.02)
            }
            return mayContinue()
        }
        do {
            let polls = Int((PasteboardSession.receiptCap / 0.02).rounded(.up))
            for _ in 0..<polls {
                guard mayContinue() else { return false }
                if clipboard.wasRestored(lease) {
                    return clipboard.firstReceiptMs != nil || clipboard.hadEarlyRead || clipboard.fieldConfirmed
                }
                if clipboard.firstReceiptMs != nil {
                    for _ in 0..<40 {
                        guard mayContinue() else { return false }
                        if clipboard.wasRestored(lease) { return true }
                        let reads = clipboard.readCount
                        try await sleep(PasteboardSession.receiptSettle)
                        guard mayContinue() else { return false }
                        if clipboard.readCount == reads { return try await holdLifted() }
                    }
                    return false
                }
                if clipboard.hadEarlyRead {
                    try await sleep(PasteboardSession.unobservedDelay)
                    return try await holdLifted()
                }
                try await sleep(0.02)
            }
        } catch { return false }
        return false
    }

    private func pasteInParts(_ parts: [String], transcript: String, keyCode: CGKeyCode, target: FocusSnapshot) async -> Bool {
        clipboard.beginBatch()
        defer {
            clipboard.finishBatch()
        }
        let input = inputGeneration()
        let generation = batchGeneration
        // The injected clock, so a stalled main thread in a test can't spend the budget.
        let deadline = now() + .seconds(8)
        func mayContinue() -> Bool {
            let current = focus.snapshot()
            return !Task.isCancelled && generation == batchGeneration && now() < deadline
                && input != nil && inputGeneration() == input && !focus.isSecureInputEnabled && !current.isSecure
                && !current.focusOwnerDiffersFromFrontmost
                && current.pid == target.pid && current.bundleID == target.bundleID
                && current.windowTitle == target.windowTitle && current.element == target.element
        }
        for part in parts {
            guard mayContinue(), clipboard.paste(part, keyCode: keyCode, targetPID: target.pid, transcript: transcript) else { return false }
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
    private func startVerification(
        generation: Int, pasted: String, target: FocusSnapshot, lease: Int, baseline: PasteVerifier.Baseline?
    ) {
        let offsets = Self.verifyOffsets
        let startedAt = now()
        verification = Task { [weak self] in
            var observations: [PasteVerifier.Observation] = []
            for offset in offsets {
                guard let current = self?.now() else { return }
                let remaining = current.duration(to: startedAt + .seconds(offset)).components
                let delay = max(0, Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18)
                do { try await self?.sleep(delay) } catch { return }
                guard let self, !Task.isCancelled, self.deliveryGeneration == generation else { return }
                // Without a trustworthy field baseline there is nothing to compare with; wait the last read out
                // so the receipt is in.
                guard let baseline else { continue }
                let observation = self.observe(target)
                observations.append(observation)
                if PasteVerifier.confirms(observation, baseline: baseline, pasted: pasted) {
                    self.clipboard.fieldShowedPaste(generation: lease)
                    break
                }
            }
            guard let self, !Task.isCancelled, self.deliveryGeneration == generation else { return }
            let verdict = PasteVerifier.judge(baseline: baseline, pasted: pasted, observations: observations, expected: offsets.count)
            Log.app.info("paste read-back: \(verdict.storeOutcome, privacy: .public)")
            let verification = PasteVerification(id: generation, verdict: verdict, receiptMs: self.clipboard.firstReceiptMs)
            self.lastVerdict = verification
            self.onVerified?(verification)
            self.returnAfterVerdict(verification)
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
        let age = last.date.duration(to: now())
        guard age >= .zero, age <= .seconds(Self.continuationWindow) else { return .outsideWindow }
        guard let recorded = last.inputGeneration, let current = inputGeneration() else { return .inputUnavailable }
        guard current == recorded else { return .inputChanged }
        return .available(last.finalCharacter)
    }

    /// Pastes the last delivered transcript again, at the current focus. Nil when nothing was delivered yet.
    public func pasteLast() async -> DeliveryResult? {
        guard let lastText else { return nil }
        return await deliver(lastText, startFocus: nil)
    }

    /// Queues a Return for the app `result` was just pasted into, when the user opted that app in. It goes out only
    /// when the read-back reports that this delivery's text landed; any other verdict, or none, sends nothing.
    /// Called only by the controller after a normal dictation take, never by `deliver`, so Paste Last, the
    /// self-tests and every other delivery can't reach it.
    func armReturn(after result: DeliveryResult) {
        guard result.method == .paste, result.outcome == .unknown else { return skipReturn("the delivery was not a clean paste") }
        guard !result.finalText.isEmpty else { return skipReturn("nothing was delivered") }
        guard let target = result.target, let pid = target.pid, pid > 0, let bundleID = target.bundleID else {
            return skipReturn("the paste target is unknown")
        }
        guard sendsReturn(bundleID) else { return skipReturn("the app is not opted in") }
        guard let element = target.element else { return skipReturn("the paste target has no focused element") }
        guard let generation = result.verificationID, generation == deliveryGeneration, !closing else {
            return skipReturn("a newer delivery replaced this paste")
        }
        guard !Task.isCancelled else { return skipReturn("the take was cancelled") }
        guard let stamp = pasteStamp, stamp.generation == generation, let input = stamp.input else {
            return skipReturn("user input can't be tracked")
        }
        let armed = ArmedReturn(
            generation: generation, pid: pid, bundleID: bundleID, element: element, input: input, pastedAt: stamp.at)
        guard PasteTargetPolicy.confirmsPaste(bundleID: bundleID) else { return armUnconfirmedSend(armed) }
        armedReturn = armed
        if let verdict = lastVerdict, verdict.id == generation { returnAfterVerdict(verdict) }
    }

    /// A new recording drops any Return still waiting on a verdict.
    func cancelPendingReturn() {
        armedReturn = nil
        cancelUnconfirmedSend()
    }

    private func cancelUnconfirmedSend() {
        unconfirmedSend?.cancel()
        unconfirmedSend = nil
    }

    /// A terminal can't confirm the paste, so its Return goes out a beat after the paste instead of after a verdict.
    /// Never stored in `armedReturn`, so a verdict can't send it a second time.
    private func armUnconfirmedSend(_ armed: ArmedReturn) {
        cancelUnconfirmedSend()
        unconfirmedSend = Task { [weak self] in
            guard let self else { return }
            let remaining = Self.unconfirmedSendDelay - Self.seconds(self.now() - armed.pastedAt)
            if remaining > 0 { do { try await self.sleep(remaining) } catch { return } }
            guard !Task.isCancelled, self.deliveryGeneration == armed.generation else {
                return self.skipReturn("the take was cancelled or replaced")
            }
            self.unconfirmedSend = nil
            if let reason = self.returnBlocker(armed) { return self.skipReturn(reason) }
            guard self.clipboard.pressReturn(targetPID: armed.pid) else { return self.skipReturn("the Return event could not be posted") }
            Log.app.info("send after insert: pressed Return without confirmation")
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    private func skipReturn(_ reason: String) {
        Log.app.info("send after insert skipped: \(reason, privacy: .public)")
    }

    /// Runs when a read-back ends, or when a send is armed after it did.
    private func returnAfterVerdict(_ verification: PasteVerification) {
        guard let armed = armedReturn, armed.generation == verification.id else { return }
        armedReturn = nil
        guard verification.verdict == .confirmed else {
            return skipReturn("the read-back said \(verification.verdict.storeOutcome)")
        }
        if let reason = returnBlocker(armed) { return skipReturn(reason) }
        guard clipboard.pressReturn(targetPID: armed.pid) else { return skipReturn("the Return event could not be posted") }
        Log.app.info("send after insert: pressed Return")
    }

    /// Why a Return must not go out now, or nil when every guard holds. Shared by the confirmed and unconfirmed paths
    /// so they can't drift; the verdict check is the confirmed path's own.
    private func returnBlocker(_ armed: ArmedReturn) -> String? {
        guard armed.generation == deliveryGeneration, !closing, !deliveryActive, !Task.isCancelled else {
            return "the take was cancelled or replaced"
        }
        // The Accessibility reads can stall on another app, so the deadline and the input count come after them.
        let fresh = focus.snapshot()
        guard !fresh.isSecure, !focus.isSecureInputEnabled else { return "a secure field or secure input is active" }
        guard fresh.pid == armed.pid, fresh.bundleID == armed.bundleID, fresh.element == armed.element,
            !fresh.focusOwnerDiffersFromFrontmost
        else { return "focus moved after the paste" }
        guard now() <= armed.pastedAt.advanced(by: .seconds(Self.returnWindow)) else { return "the send window passed" }
        // Matching text in the field doesn't show the user left it alone; a key or click since the paste does.
        // The very last read, so a key pressed during any read above counts.
        guard inputGeneration() == armed.input else { return "the user typed or clicked after the paste" }
        return nil
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
    /// Posts one plain Return, with no modifiers. False when the events could not be created.
    func postReturn(targetPID: pid_t?) -> Bool
}

extension PasteEventPosting {
    func postReturn(targetPID: pid_t?) -> Bool { false }
}

@MainActor
final class SystemPasteEventPoster: PasteEventPosting {
    private let stamp: Int64
    private let targetPID: pid_t?
    private let post: @MainActor (CGEvent, pid_t) -> Void

    init(
        stamp: Int64, targetPID: pid_t? = nil,
        post: @escaping @MainActor (CGEvent, pid_t) -> Void = { event, pid in event.postToPid(pid) }
    ) {
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

    /// Same private source, stamp and destination as the paste, with the flags cleared so a held Shift or Command
    /// can't turn the Return into a newline or a different shortcut.
    func postReturn(targetPID requestedPID: pid_t?) -> Bool {
        guard let destination = targetPID ?? requestedPID, destination > 0 else { return false }
        let source = CGEventSource(stateID: .privateState)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: Self.returnKeyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: Self.returnKeyCode, keyDown: false)
        else { return false }
        for event in [down, up] {
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: stamp)
            post(event, destination)
        }
        return true
    }

    /// kVK_Return.
    static let returnKeyCode: CGKeyCode = 0x24
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
    /// The pasteboard also carried a file promise, which was left out: its provider lives in the app that copied, and
    /// a copy of its metadata put back later would be a promise nothing can keep.
    var droppedFilePromise = false
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
///
/// A read of the promise is evidence the target has the text, not proof: a clipboard sync (a VM's, Barrier's, an
/// older clipboard manager's) can read within 50 ms while a slow target (an IDE, Excel, a remote desktop) reads at
/// 300 ms or later, and a restore timed off the sync's read makes the target paste the user's previous clipboard. So
/// a paste into a field whose text can be read back holds the restore until the read-back has seen the text in the
/// field, for at most `fieldHoldCap` past the chord; a paste nobody could read back restores off the receipt alone.
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
    /// How long past the chord a paste into a readable field may keep the clipboard while the field has not shown the
    /// text. Covers the last read-back (`TextInserter.verifyOffsets`) with room for the read itself; after that no more
    /// evidence is coming, and a field that rewrites the text beyond recognition must not cost the user their clipboard
    /// for longer than it takes them to reach for Cmd+V.
    static let fieldHoldCap: TimeInterval = 1.2

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

    /// The user's clipboard while a restore is pending. Nil during a lease that has nothing to put back.
    private var saved: PasteboardSnapshot?
    /// Our paste is on the clipboard and its lease has not ended. Kept apart from `saved`: a lease over a clipboard
    /// that can't be put back still has to run its course before the next paste may replace the promise.
    private var leased = false
    /// The change count right after our last write.
    private var ourChangeCount = 0
    /// Bumped on every write; only the latest scheduled restore runs.
    private var generation = 0
    /// Bumped on every receipt; of the settle timers, only the latest runs.
    private var receiptCount = 0
    private var receipts: PasteReceipts?
    private var holdingRestore = false
    private var restoredGeneration: Int?
    /// The current paste keeps the clipboard until the field shows its text, or `fieldHoldCap`.
    private var fieldHold = false
    /// A restore came due while the field hold was on; it runs the moment the hold lifts.
    private var restoreDeferred = false
    /// The read-back saw the current paste in the field.
    private var fieldShowed = false
    /// What stays on the clipboard if the lease ends with nothing to put back: the whole transcript, not the part
    /// last pasted.
    private var leaseTranscript = ""

    init(pasteboard: PasteboardAccess, poster: PasteEventPosting, schedule: @escaping Schedule = PasteboardSession.mainSchedule) {
        self.pasteboard = pasteboard
        self.poster = poster
        self.schedule = schedule
    }

    var isRestorePending: Bool { saved != nil }

    /// The current lease leaves the transcript on the clipboard: what was there can't be put back.
    var transcriptStays: Bool { leased && saved == nil }

    /// The field hold is still on: the clipboard stays until the field shows the text or `fieldHoldCap`.
    var fieldHeld: Bool { fieldHold }
    /// The field showed the current paste, whatever the target did or didn't read.
    var fieldConfirmed: Bool { fieldShowed }

    func pressReturn(targetPID: pid_t?) -> Bool { poster.postReturn(targetPID: targetPID) }

    var pasteGeneration: Int { generation }
    var readCount: Int { receipts?.readCount ?? 0 }
    var hadEarlyRead: Bool { receipts?.hadEarlyRead ?? false }

    func holdsPaste(_ expected: Int) -> Bool {
        generation == expected && leased && pasteboard.changeCount == ourChangeCount
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
    ///
    /// `holdForField` is for a field whose text could be read before the paste: the restore then waits for
    /// `fieldShowedPaste` (or `fieldHoldCap`) on top of the receipt, since the first read of the promise may be a
    /// clipboard sync's and not the target's.
    ///
    /// A clipboard holding only a file promise (a copied Photos picture, a Mail attachment) has nothing that can be
    /// put back; the paste goes ahead, the lease runs as usual, and the transcript stays on the clipboard after it.
    func paste(_ text: String, keyCode: CGKeyCode, targetPID: pid_t?, holdForField: Bool = false, transcript: String? = nil) -> Bool {
        // Snapshot what someone else put there, or what was left to stay. Never our own promise mid-lease: the parts
        // of a long paste share the one snapshot taken before the first.
        if pasteboard.changeCount != ourChangeCount || (!leased && saved == nil) {
            let snapshot = pasteboard.snapshot()
            if snapshot.items.isEmpty, snapshot.droppedFilePromise {
                Log.app.info("clipboard holds only a file promise, which can't be put back; the transcript will stay")
                saved = nil
            } else {
                if snapshot.droppedFilePromise { Log.app.info("clipboard carried a file promise; the rest of it comes back") }
                saved = snapshot
            }
        }
        generation += 1
        restoredGeneration = nil
        receiptCount = 0
        leased = true
        fieldHold = holdForField
        restoreDeferred = false
        fieldShowed = false
        leaseTranscript = transcript ?? text
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
        if holdForField {
            schedule(Self.fieldHoldCap) { [weak self] in
                self?.liftFieldHold(generation: current, fieldShowedPaste: false)
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
        guard expected == generation, leased else { return }
        // A read after the restore came due means the target is still taking the text; the next confirm waits it out.
        restoreDeferred = false
        receiptCount += 1
        let count = receiptCount
        schedule(Self.receiptSettle) { [weak self] in
            self?.restore(ifGeneration: expected, receiptCount: count)
        }
    }

    /// The read-back saw the pasted text in the field: the target has it, and the clipboard can go back.
    func fieldShowedPaste(generation expected: Int) {
        liftFieldHold(generation: expected, fieldShowedPaste: true)
    }

    /// Ends the field hold. A restore that came due meanwhile runs now; otherwise the field showing the text is itself
    /// a receipt, with the usual settle, for the rare target whose read never called back.
    private func liftFieldHold(generation expected: Int, fieldShowedPaste: Bool) {
        guard expected == generation else { return }
        if fieldShowedPaste { fieldShowed = true }
        guard fieldHold else { return }
        fieldHold = false
        if restoreDeferred {
            restoreDeferred = false
            restore(ifGeneration: expected)
        } else if fieldShowedPaste {
            schedule(Self.receiptSettle) { [weak self] in
                self?.restore(ifGeneration: expected)
            }
        }
    }

    /// Puts `text` on the clipboard to stay. Drops any pending restore, which would otherwise overwrite it.
    func copy(_ text: String) {
        saved = nil
        leased = false
        fieldHold = false
        restoreDeferred = false
        generation += 1
        restoredGeneration = nil
        receipts = nil
        pasteboard.write(text, markers: Self.concealedMarkers)
        ourChangeCount = pasteboard.changeCount
    }

    /// The app is quitting: whatever the field has or hasn't shown, the clipboard goes back now.
    func restoreForTermination() {
        holdingRestore = false
        fieldHold = false
        restoreDeferred = false
        restore(ifGeneration: generation)
        saved = nil
        leased = false
        generation += 1
        receipts = nil
        restoredGeneration = nil
    }

    private func restore(ifGeneration expected: Int, receiptCount expectedCount: Int? = nil) {
        guard !holdingRestore, expected == generation, leased else { return }
        if let expectedCount, expectedCount != receiptCount { return }
        if fieldHold {
            restoreDeferred = true
            return
        }
        leased = false
        let snapshot = saved
        saved = nil
        guard pasteboard.changeCount == ourChangeCount else {
            Log.app.info("clipboard changed during paste; not restoring")
            return
        }
        if let snapshot {
            pasteboard.restore(snapshot)
            ourChangeCount = pasteboard.changeCount
        } else {
            // Nothing to put back: the promise would die with the app or the next snapshot, so the transcript becomes
            // real data (kept out of history) and the notice stays true.
            pasteboard.write(leaseTranscript, markers: Self.concealedMarkers)
            ourChangeCount = pasteboard.changeCount
        }
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

    /// The types `NSFilePromiseProvider` writes (Photos, Mail and Safari image copies carry them), the URL a receiver
    /// adds once it has taken the files, and the pre-10.12 promise type. An ordinary Finder copy is `public.file-url`
    /// and `NSFilenamesPboardType`; an image copy is `public.tiff` or `public.png`. Neither is here.
    static let filePromiseTypes: Set<String> = [
        "com.apple.pasteboard.promised-file-url", "com.apple.pasteboard.promised-file-content-type",
        "com.apple.pasteboard.promised-file-name", "com.apple.pasteboard.promised-suggested-file-name",
        "com.apple.pasteboard.NSFilePromiseID", "com.apple.NSFilePromiseItemMetaData",
        "Apple files promise pasteboard type",
    ]

    /// Every type of every item, except a file promise's: its files are written by the copying app on demand, into a
    /// folder the receiver names, so there is nothing to read now and nothing a restore could offer later. The other
    /// representations riding with it (the image bytes, a URL) still come back.
    func snapshot() -> PasteboardSnapshot {
        var dropped = false
        let items = (pasteboard.pasteboardItems ?? []).compactMap { item -> [PasteboardRepresentation]? in
            let kept = item.types.filter { !Self.filePromiseTypes.contains($0.rawValue) }
            if kept.count < item.types.count { dropped = true }
            let representations = kept.compactMap { type in
                item.data(forType: type).map { PasteboardRepresentation(type: type.rawValue, data: $0) }
            }
            return representations.isEmpty && kept.count < item.types.count ? nil : representations
        }
        return PasteboardSnapshot(items: items, droppedFilePromise: dropped)
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
