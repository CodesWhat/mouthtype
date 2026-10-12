// Adapted from Parrot (https://github.com/humanitas-labs/parrot, 0eb4708), MIT License, Copyright (c) 2026 Humanitas Labs.
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import MouthtypeCore

/// Wires the event taps into the gesture state machine and reports `HotkeyEvent`s on the main actor.
///
/// Tap 1 (flags, listen-only) is always on. Tap 2 (keys, active) exists only while a recording is in
/// progress, so the tap that could break typing lives for seconds, not hours. Fn remap mode and the
/// probes keep tap 2 on permanently: the remap has to swallow its destination key (and stands in for the Fn combos
/// it broke), the probes log keys.
@MainActor
public final class HotkeyService {
    public struct Options: Sendable {
        public var source: HotkeySource
        public var configuration: GestureConfiguration
        /// Keep the key tap on while idle so key events can be logged. Diagnostics only.
        public var observesKeys: Bool

        public init(source: HotkeySource = .fnFlag, configuration: GestureConfiguration = .default, observesKeys: Bool = false) {
            self.source = source
            self.configuration = configuration
            self.observesKeys = observesKeys
        }
    }

    public enum StartError: Error, Equatable {
        case accessibilityMissing
        case tapCreateFailed
    }

    public let events: AsyncStream<HotkeyEvent>
    public private(set) var health: HotkeyHealth = .off {
        didSet { if health != oldValue { onHealthChange?(health) } }
    }
    public var onHealthChange: (@MainActor (HotkeyHealth) -> Void)?
    /// Every sample either tap delivers, before it reaches the processor. For the probes.
    public var sampleObserver: (@MainActor (TapSample) -> Void)?

    private struct Slot {
        var tap: EventTap?
        var recovery = TapRecovery()
        var retry: Task<Void, Never>?
    }

    static let monitorInterval: Duration = .seconds(1)
    static let watchdogEveryTicks = 5

    private var options: Options
    private let otherKeysHeldProbe: @MainActor ([UInt16]) -> Bool
    private let eventSink: AsyncStream<HotkeyEvent>.Continuation
    private var messages: AsyncStream<TapMessage>
    private var messageSink: AsyncStream<TapMessage>.Continuation
    let shared = TapShared()
    private let emulator = KeyEmulator()
    private var engine: GestureEngine
    private var mapper: HotkeyInputMapper
    private var thread: TapThread?
    private var slots: [TapRole: Slot] = [:]
    private var secureInput = false
    private var consumer: Task<Void, Never>?
    private var monitor: Task<Void, Never>?

    public convenience init(options: Options = Options()) {
        self.init(options: options, otherKeysHeld: HotkeyService.liveKeysHeld)
    }

    init(options: Options, otherKeysHeld: @escaping @MainActor ([UInt16]) -> Bool) {
        self.options = options
        otherKeysHeldProbe = otherKeysHeld
        engine = GestureEngine(configuration: options.configuration)
        mapper = HotkeyInputMapper(source: options.source)
        (events, eventSink) = AsyncStream.makeStream(of: HotkeyEvent.self)
        (messages, messageSink) = AsyncStream.makeStream(of: TapMessage.self)
    }

    public var source: HotkeySource { options.source }

    /// For the self-test: whether the key tap exists right now.
    var keyTapInstalled: Bool { slots[.keys]?.tap != nil }

    private var keyTapStaysOn: Bool {
        if options.observesKeys { return true }
        if case .remapped = options.source { return true }
        return false
    }

    private var swallowedKey: UInt16? {
        if case let .remapped(code) = options.source { return code }
        return nil
    }

    // MARK: - Lifecycle

    /// Creates the always-on tap. Call only after Accessibility is granted, so macOS has no reason to raise an Input Monitoring prompt.
    public func start() throws {
        guard AXIsProcessTrusted() else { throw StartError.accessibilityMissing }
        guard slots[.flags]?.tap == nil else { return }
        let thread = TapThread()
        self.thread = thread
        // A stream whose consumer was cancelled is finished, so each run gets its own.
        (messages, messageSink) = AsyncStream.makeStream(of: TapMessage.self)
        guard let flagsTap = makeTap(.flags) else {
            thread.stop()
            self.thread = nil
            throw StartError.tapCreateFailed
        }
        slots[.flags] = Slot(tap: flagsTap)
        if keyTapStaysOn {
            guard let keyTap = makeTap(.keys) else {
                stop()
                throw StartError.tapCreateFailed
            }
            slots[.keys] = Slot(tap: keyTap)
        }

        let messages = self.messages
        consumer = Task { [weak self] in
            for await message in messages {
                guard let self else { return }
                self.handle(message)
            }
        }
        monitor = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.monitorInterval)
                guard let self, !Task.isCancelled else { return }
                tick += 1
                self.monitorTick(runWatchdog: tick % Self.watchdogEveryTicks == 0)
            }
        }
        refreshHealth()
        Log.hotkey.info("tap created, health \(self.health.statusText, privacy: .public)")
    }

    public func stop() {
        consumer?.cancel()
        monitor?.cancel()
        consumer = nil
        monitor = nil
        for slot in slots.values {
            slot.retry?.cancel()
            slot.tap?.teardown()
        }
        slots = [:]
        thread?.stop()
        thread = nil
        messageSink.finish()
        shared.reset()
        engine = GestureEngine(configuration: options.configuration)
        mapper = HotkeyInputMapper(source: options.source)
        health = .off
    }

    /// Moves the live taps to another hotkey source (the Fn remap toggled) without a relaunch. A recording in
    /// progress is cancelled, since the key that would end it is about to mean something else.
    public func switchSource(_ source: HotkeySource) throws {
        guard source != options.source else { return }
        let wasRunning = thread != nil
        let interrupted = engine.isRecording
        stop()
        options.source = source
        mapper = HotkeyInputMapper(source: source)
        if interrupted { eventSink.yield(.cancelled(reason: .inputLost)) }
        if wasRunning { try start() }
    }

    /// Ends a locked recording that something other than the key stopped (the menu, the safety cap), so the next press starts fresh.
    public func releaseLock() {
        guard engine.isLocked else { return }
        engine.endLock()
        mapper.lockedRecording = false
        setRecording(false)
    }

    private func makeTap(_ role: TapRole) -> EventTap? {
        guard let thread else { return nil }
        let remapped = role == .keys && swallowedKey != nil
        let context = TapContext(
            role: role, sink: messageSink, swallowedKey: role == .keys ? swallowedKey : nil, shared: shared,
            emulator: remapped ? emulator : nil, tracksFnFlag: swallowedKey == nil, idleKeysReported: options.observesKeys
        )
        return EventTap(role: role, context: context, runLoop: thread.runLoop)
    }

    // MARK: - Samples

    private func handle(_ message: TapMessage) {
        switch message {
        case let .sample(_, sample): process(sample)
        case let .disabled(role): noteDisabled(role)
        }
    }

    func process(_ sample: TapSample) {
        sampleObserver?(sample)
        if isLockChord(sample) {
            if let gesture = engine.lockFromChord() { dispatch(gesture, nanos: sample.timestamp) }
            return
        }
        var excluded: [UInt16] = []
        if let swallowedKey { excluded.append(swallowedKey) }
        let probe = otherKeysHeldProbe
        guard let mapped = mapper.map(sample, otherKeysHeld: { probe(excluded) }) else { return }
        guard let gesture = engine.process(mapped.keyEvent, now: Self.date(nanos: mapped.timestampNanos)) else { return }
        dispatch(gesture, nanos: mapped.timestampNanos)
    }

    /// Space while the hotkey is held and a recording is in progress: the hands-free toggle.
    private func isLockChord(_ sample: TapSample) -> Bool {
        sample.kind == .keyDown && !sample.isAutorepeat && sample.keyCode == FnCombos.spaceKeyCode
            && sample.userData != SyntheticEvents.stamp && mapper.hotkeyHeld && engine.isRecording && !engine.isLocked
    }

    private func dispatch(_ gesture: GestureEvent, nanos: UInt64) {
        defer { mapper.lockedRecording = engine.isLocked }
        switch gesture {
        case .pressed:
            setRecording(true)
            eventSink.yield(.pressed(at: nanos))
        case let .locked(trigger):
            eventSink.yield(.locked(at: nanos, trigger: trigger))
            refreshHealth()
        case .released:
            setRecording(false)
            eventSink.yield(.released(at: nanos))
        case let .cancelled(reason):
            setRecording(false)
            eventSink.yield(.cancelled(reason: reason))
        case let .discarded(reason):
            setRecording(false)
            eventSink.yield(.discarded(reason: reason))
        }
    }

    private func setRecording(_ recording: Bool) {
        if recording {
            if slots[.keys]?.tap == nil, let keyTap = makeTap(.keys) {
                slots[.keys] = Slot(tap: keyTap)
            }
            shared.recording.store(true, ordering: .relaxed)
        } else if keyTapStaysOn {
            shared.recording.store(false, ordering: .relaxed)
        } else if let slot = slots[.keys] {
            shared.recording.store(false, ordering: .relaxed)
            slot.retry?.cancel()
            slot.tap?.teardown()
            slots[.keys] = nil
        }
        refreshHealth()
    }

    /// Only differences between these dates matter to the gesture engine; `nanos` is a `CGEvent.timestamp`.
    /// Diagnostics (`--tap-cycle-selftest`): installs the active key tap the way a press does, then tears it down
    /// the way a release does, without any key event. Returns whether the tap came up.
    func cycleKeyTapForSelfTest() -> Bool {
        setRecording(true)
        let installed = slots[.keys]?.tap != nil
        setRecording(false)
        return installed
    }

    nonisolated static func date(nanos: UInt64) -> Date {
        Date(timeIntervalSinceReferenceDate: Double(nanos) / 1_000_000_000)
    }

    // MARK: - Recovery

    private func noteDisabled(_ role: TapRole) {
        guard slots[role]?.tap != nil, slots[role]?.retry == nil else { return }
        let delay = slots[role]!.recovery.disabled(at: Date())
        if delay == 0 {
            reenable(role, reason: "disabled")
        } else {
            scheduleRetry(role, after: delay)
        }
    }

    private func reenable(_ role: TapRole, reason: String) {
        slots[role]?.retry = nil
        guard let tap = slots[role]?.tap else { return }
        tap.enable()
        guard tap.isEnabled else {
            scheduleRetry(role, after: slots[role]!.recovery.enableFailed())
            return
        }
        slots[role]!.recovery.enabled(at: Date())
        Log.hotkey.info("\(String(describing: role), privacy: .public) tap re-enabled (\(reason, privacy: .public))")
        refreshHealth()
        resync()
    }

    private func scheduleRetry(_ role: TapRole, after delay: TimeInterval) {
        Log.hotkey.warning("\(String(describing: role), privacy: .public) tap disabled, retrying in \(delay, format: .fixed(precision: 0), privacy: .public) s")
        slots[role]?.retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.reenable(role, reason: "retry")
        }
        refreshHealth()
    }

    /// While a tap was off the hotkey may have been released unseen. Only a missed release is acted on:
    /// a press missed meanwhile doesn't start a recording halfway through.
    private func resync() {
        let flags = CGEventSource.flagsState(.combinedSessionState).rawValue
        var destinationDown = false
        if case let .remapped(code) = options.source {
            destinationDown = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code))
        }
        guard let sample = Self.resyncSample(
            source: options.source,
            hotkeyHeld: mapper.hotkeyHeld,
            currentFlags: flags,
            destinationKeyDown: destinationDown,
            timestampNanos: HostClock.now()
        ) else { return }
        shared.hotkeyHeld.store(false, ordering: .relaxed)
        Log.hotkey.info("resyncing a missed hotkey release")
        process(sample)
    }

    nonisolated static func resyncSample(source: HotkeySource, hotkeyHeld: Bool, currentFlags: UInt64, destinationKeyDown: Bool, timestampNanos: UInt64) -> TapSample? {
        guard hotkeyHeld else { return nil }
        switch source {
        case .fnFlag:
            guard currentFlags & CGEventFlags.maskSecondaryFn.rawValue == 0 else { return nil }
            return TapSample(kind: .flagsChanged, keyCode: ModifierState.fnKeyCode, flags: currentFlags, timestamp: timestampNanos)
        case let .remapped(code):
            guard !destinationKeyDown else { return nil }
            return TapSample(kind: .keyUp, keyCode: code, flags: currentFlags, timestamp: timestampNanos)
        }
    }

    // MARK: - Health

    private func monitorTick(runWatchdog: Bool) {
        if runWatchdog {
            for (role, slot) in slots where slot.retry == nil {
                if let tap = slot.tap, !tap.isEnabled { noteDisabled(role) }
            }
        }
        if !engine.isRecording { secureInput = IsSecureEventInputEnabled() }
        refreshHealth()
    }

    private func refreshHealth() {
        health = HotkeyHealth.resolve(
            tapPresent: slots[.flags]?.tap != nil,
            recovering: slots.values.contains { $0.retry != nil },
            secureInput: secureInput,
            recording: engine.isRecording
        )
    }

    // MARK: - Held keys

    /// True when a non-modifier key is down, so a press made while typing is refused.
    nonisolated static func liveKeysHeld(excluding: [UInt16]) -> Bool {
        (0..<128).contains { code in
            let code = UInt16(code)
            return !ModifierState.isModifierKeyCode(code)
                && !excluding.contains(code)
                && CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code))
        }
    }
}
