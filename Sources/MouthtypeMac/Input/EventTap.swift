// Adapted from Parrot (https://github.com/humanitas-labs/parrot, 0eb4708), MIT License, Copyright (c) 2026 Humanitas Labs.
import CoreGraphics
import Foundation

/// The thread the taps' run loop sources live on, so a busy main thread can't get a tap disabled for being slow.
final class TapThread: @unchecked Sendable {
    private final class Box: @unchecked Sendable {
        var runLoop: CFRunLoop?
    }

    let runLoop: CFRunLoop
    private let thread: Thread

    init() {
        let box = Box()
        let ready = DispatchSemaphore(value: 0)
        thread = Thread {
            let current = CFRunLoopGetCurrent()
            box.runLoop = current
            // A run loop with no sources returns at once; this one keeps it alive until stop().
            var context = CFRunLoopSourceContext()
            if let keepAlive = CFRunLoopSourceCreate(nil, 0, &context) {
                CFRunLoopAddSource(current, keepAlive, .defaultMode)
            }
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "com.codeswhat.mouthtype.event-taps"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        runLoop = box.runLoop!
    }

    func stop() {
        CFRunLoopStop(runLoop)
    }
}

private struct ReleaseBox: @unchecked Sendable {
    let retained: Unmanaged<TapContext>
    init(_ retained: Unmanaged<TapContext>) { self.retained = retained }
    func release() { retained.release() }
}

/// One CGEvent tap on the tap thread. The callback copies fields and hands them off; it does nothing else.
@MainActor
final class EventTap {
    let role: TapRole
    let context: TapContext
    private let runLoop: CFRunLoop
    private let port: CFMachPort
    private let source: CFRunLoopSource
    private let retainedContext: Unmanaged<TapContext>

    /// `countsInput` widens the listen-only flag tap to presses and clicks, which only bump a counter.
    init?(role: TapRole, context: TapContext, runLoop: CFRunLoop, countsInput: Bool = false) {
        let mask: CGEventMask
        let options: CGEventTapOptions
        switch role {
        case .flags:
            var flagsMask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue
            if countsInput {
                flagsMask |= Self.pointerMask
                if context.countsKeys { flagsMask |= 1 << CGEventType.keyDown.rawValue }
            }
            mask = flagsMask
            options = .listenOnly
        case .keys:
            mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            options = .defaultTap
        }
        let retained = Unmanaged.passRetained(context)
        // .cgSessionEventTap is the level for an Accessibility-granted user process; .cghidEventTap needs root.
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: options,
                eventsOfInterest: mask,
                callback: tapCallback,
                userInfo: retained.toOpaque()
            ),
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        else {
            retained.release()
            return nil
        }
        self.role = role
        self.context = context
        self.runLoop = runLoop
        self.port = port
        self.source = source
        retainedContext = retained
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    static let pointerMask: CGEventMask =
        (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
        | (1 << CGEventType.otherMouseDown.rawValue)

    var isEnabled: Bool { CGEvent.tapIsEnabled(tap: port) }

    func enable() {
        CGEvent.tapEnable(tap: port, enable: true)
    }

    func teardown() {
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        // Release on the tap thread, behind any callback still running there.
        Self.releaseOnTapThread(retainedContext, runLoop: runLoop)
    }

    /// Nonisolated on purpose: a block formed inside this `@MainActor` class would inherit main-actor isolation,
    /// and Swift 6 would assert that executor when the block runs on the tap thread, trapping. The block here
    /// is `@Sendable` and captures only a `Sendable` box.
    nonisolated private static func releaseOnTapThread(_ retained: Unmanaged<TapContext>, runLoop: CFRunLoop) {
        let box = ReleaseBox(retained)
        let block: @Sendable () -> Void = { box.release() }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }
}

private func tapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let context = Unmanaged<TapContext>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        context.sink.yield(.disabled(context.role))
        return Unmanaged.passUnretained(event)
    }
    if TapPolicy.isPointerDown(type) {
        if event.getIntegerValueField(.eventSourceUserData) != SyntheticEvents.stamp {
            context.shared.userInput.wrappingAdd(1, ordering: .relaxed)
        }
        return Unmanaged.passUnretained(event)
    }
    if context.role == .flags, type == .keyDown {
        if let sample = TapSample(type: type, event: event) { context.countPassiveKey(sample) }
        return Unmanaged.passUnretained(event)
    }
    guard let sample = TapSample(type: type, event: event) else { return Unmanaged.passUnretained(event) }
    let shared = context.shared
    if sample.userData == SyntheticEvents.stamp { shared.stampedSeen.wrappingAdd(1, ordering: .relaxed) }
    let pending = context.role == .keys && sample.kind != .flagsChanged ? shared.pending.withLock { $0[sample.keyCode] } : nil
    let decision = TapPolicy.decide(
        sample,
        role: context.role,
        recording: shared.recording.load(ordering: .relaxed),
        swallowedKey: context.swallowedKey,
        hotkeyHeld: shared.hotkeyHeld.load(ordering: .relaxed),
        pending: pending,
        idleKeysReported: context.idleKeysReported
    )
    if let held = TapPolicy.holdChange(sample, swallowedKey: context.swallowedKey, tracksFnFlag: context.tracksFnFlag) {
        shared.hotkeyHeld.store(held, ordering: .relaxed)
    }
    if let combo = decision.replacement, let emulator = context.emulator,
       emulator.post(combo, keyDown: sample.kind == .keyDown, originalFlags: sample.flags, autorepeat: sample.isAutorepeat) {
        shared.emulated.wrappingAdd(1, ordering: .relaxed)
    }
    if context.role == .keys {
        switch TapPolicy.pendingChange(for: sample, decision: decision) {
        case .none: break
        case let .set(value): shared.pending.withLock { $0[sample.keyCode] = value }
        case .clear: shared.pending.withLock { $0[sample.keyCode] = nil }
        }
    }
    if TapPolicy.countsAsUserInput(sample, decision: decision, swallowedKey: context.swallowedKey) {
        shared.userInput.wrappingAdd(1, ordering: .relaxed)
    }
    if decision.swallow { shared.swallowed.wrappingAdd(1, ordering: .relaxed) }
    if decision.deliver { context.sink.yield(.sample(context.role, sample)) }
    return decision.swallow ? nil : Unmanaged.passUnretained(event)
}
