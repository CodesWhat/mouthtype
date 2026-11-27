import CoreGraphics
import Foundation
import Testing
@testable import MouthtypeMac

@MainActor
private final class FakeTap: TapHandle {
    let role: TapRole
    let context: TapContext
    var isEnabled = true
    var enableCalls = 0
    var tornDown = false
    /// When false, `enable()` leaves the tap off, as when Secure Input undoes it.
    var enableWorks = true

    init(role: TapRole, context: TapContext) {
        self.role = role
        self.context = context
    }

    func enable() {
        enableCalls += 1
        if enableWorks { isEnabled = true }
    }

    func teardown() { tornDown = true }
}

@MainActor
private final class FakeSystem: HotkeySystem {
    var isProcessTrusted = true
    var isSecureInputEnabled = false
    var currentFlags: UInt64 = 0
    var keysDown: Set<UInt16> = []
    var refused: Set<TapRole> = []
    /// Refuses the first flag tap only when it asks to count input, as macOS does for a mask it won't allow.
    var refuseInputCounting = false
    private(set) var taps: [FakeTap] = []

    func isKeyDown(_ keyCode: UInt16) -> Bool { keysDown.contains(keyCode) }

    func makeTap(role: TapRole, context: TapContext, runLoop: CFRunLoop, countsInput: Bool) -> (any TapHandle)? {
        if refused.contains(role) { return nil }
        if role == .flags, countsInput, refuseInputCounting { return nil }
        let tap = FakeTap(role: role, context: context)
        taps.append(tap)
        return tap
    }

    func tap(_ role: TapRole) -> FakeTap? { taps.last { $0.role == role && !$0.tornDown } }
}

@MainActor @Suite struct HotkeyServiceLifecycleTests {
    private func make(
        _ source: HotkeySource = .fnFlag, mouse: MouseTrigger = .none, system: FakeSystem = FakeSystem()
    ) -> (HotkeyService, FakeSystem) {
        (HotkeyService(options: .init(source: source, mouseTrigger: mouse), otherKeysHeld: { _ in false }, system: system), system)
    }

    @Test func startWithoutAccessibilityThrowsAndInstallsNothing() {
        let (service, system) = make()
        system.isProcessTrusted = false
        #expect(throws: HotkeyService.StartError.accessibilityMissing) { try service.start() }
        #expect(system.taps.isEmpty)
        #expect(service.health == .off)
    }

    @Test func startInstallsOnlyTheFlagTapForFn() throws {
        let (service, system) = make()
        try service.start()
        defer { service.stop() }
        #expect(system.taps.map(\.role) == [.flags])
        #expect(service.health == .listening)
        #expect(service.keyTapInstalled == false)
        #expect(service.userInputGeneration != nil)
    }

    @Test func startIsIdempotent() throws {
        let (service, system) = make()
        try service.start()
        defer { service.stop() }
        try service.start()
        #expect(system.taps.count == 1)
    }

    @Test func refusedInputCountingFallsBackToThePlainFlagTap() throws {
        let (service, system) = make()
        system.refuseInputCounting = true
        try service.start()
        defer { service.stop() }
        #expect(system.taps.count == 1)
        #expect(service.health == .listening)
        #expect(service.userInputGeneration == nil)
    }

    @Test func noFlagTapMeansStartFails() {
        let (service, system) = make()
        system.refused = [.flags]
        #expect(throws: HotkeyService.StartError.tapCreateFailed) { try service.start() }
        #expect(service.health == .off)
    }

    @Test func remapAndShortcutKeepTheKeyTapOn() throws {
        for source in [HotkeySource.remapped(keyCode: 80), .shortcut(DictationShortcut(keyCode: 49, keyName: "Space"))] {
            let (service, system) = make(source)
            try service.start()
            #expect(service.keyTapInstalled)
            #expect(system.taps.map(\.role) == [.flags, .keys])
            service.stop()
        }
    }

    @Test func aRefusedKeyTapTearsDownAndFails() {
        let (service, system) = make(.remapped(keyCode: 80))
        system.refused = [.keys]
        #expect(throws: HotkeyService.StartError.tapCreateFailed) { try service.start() }
        #expect(system.taps.allSatisfy { $0.tornDown })
        #expect(service.health == .off)
    }

    @Test func aMouseTriggerAddsTheMouseTapAndRefusalFails() throws {
        let trigger = MouseTrigger.allCases.first { $0 != .none }!
        let (service, system) = make(mouse: trigger)
        try service.start()
        #expect(system.taps.map(\.role) == [.flags, .mouse])
        service.stop()

        let (refusing, refusingSystem) = make(mouse: trigger)
        refusingSystem.refused = [.mouse]
        #expect(throws: HotkeyService.StartError.tapCreateFailed) { try refusing.start() }
    }

    @Test func stopTearsEveryTapDownAndGoesOff() throws {
        let (service, system) = make(.remapped(keyCode: 80))
        try service.start()
        service.stop()
        #expect(system.taps.allSatisfy { $0.tornDown })
        #expect(service.health == .off)
        #expect(service.keyTapInstalled == false)
    }

    @Test func keyTapExistsOnlyWhileRecordingForFn() {
        let (service, system) = make()
        #expect(service.cycleKeyTapForSelfTest() == false)
        #expect(system.taps.isEmpty)
        do {
            try service.start()
            #expect(service.cycleKeyTapForSelfTest())
            #expect(system.taps.map(\.role) == [.flags, .keys])
            #expect(system.taps.last?.tornDown == true)
            #expect(service.keyTapInstalled == false)
        } catch {
            Issue.record("start failed: \(error)")
        }
        service.stop()
    }

    @Test func switchingSourceRestartsTheTapsForTheNewSource() throws {
        let (service, system) = make()
        try service.start()
        try service.switchSource(.remapped(keyCode: 80))
        defer { service.stop() }
        #expect(service.source == .remapped(keyCode: 80))
        #expect(system.taps.first?.tornDown == true)
        #expect(system.tap(.flags) != nil)
        #expect(service.keyTapInstalled)
    }

    @Test func switchingToTheSameSourceChangesNothing() throws {
        let (service, system) = make()
        try service.start()
        defer { service.stop() }
        try service.switchSource(.fnFlag)
        #expect(system.taps.count == 1)
    }

    @Test func switchingRecordingModeRestoresTheOldOptionsWhenTheRestartFails() throws {
        let (service, system) = make()
        try service.start()
        system.refused = [.flags]
        #expect(throws: HotkeyService.StartError.tapCreateFailed) { try service.switchRecordingMode(.toggle) }
        #expect(service.health == .off)
        system.refused = []
        try service.start()
        try service.switchRecordingMode(.toggle)
        #expect(service.health == .listening)
        service.stop()
    }

    @Test func switchingMouseTriggerKeepsThePreviousOneOnFailure() throws {
        let trigger = MouseTrigger.allCases.first { $0 != .none }!
        let (service, system) = make()
        try service.start()
        system.refused = [.mouse]
        #expect(throws: HotkeyService.StartError.tapCreateFailed) { try service.switchMouseTrigger(trigger) }
        #expect(service.mouseTrigger == .none)
        system.refused = []
        try service.start()
        try service.switchMouseTrigger(trigger)
        #expect(service.mouseTrigger == trigger)
        #expect(system.tap(.mouse) != nil)
        service.stop()
    }

    // MARK: Recovery

    @Test func aDisabledTapIsReenabledAtOnce() async throws {
        let (service, system) = make()
        try service.start()
        defer { service.stop() }
        let tap = try #require(system.tap(.flags))
        tap.context.sink.yield(.disabled(.flags))
        await pollUntil { tap.enableCalls >= 1 }
        #expect(tap.enableCalls == 1)
        #expect(service.health == .listening)
    }

    @Test func aTapThatWontComeBackShowsRecovering() async throws {
        let (service, system) = make()
        var healths: [HotkeyHealth] = []
        service.onHealthChange = { healths.append($0) }
        try service.start()
        defer { service.stop() }
        let tap = try #require(system.tap(.flags))
        tap.enableWorks = false
        tap.isEnabled = false
        tap.context.sink.yield(.disabled(.flags))
        await pollUntil { service.health == .recovering }
        #expect(service.health == .recovering)
        #expect(healths.contains(.recovering))
    }

    @Test func aMissedFnReleaseIsResyncedAfterReenable() async throws {
        let (service, system) = make()
        try service.start()
        defer { service.stop() }
        var events: [HotkeyEvent] = []
        let collector = Task { for await event in service.events { events.append(event) } }
        defer { collector.cancel() }
        let fn = CGEventFlags.maskSecondaryFn.rawValue
        service.process(TapSample(kind: .flagsChanged, keyCode: 63, flags: fn, timestamp: 1_000_000_000))
        system.tap(.flags)?.context.shared.hotkeyHeld.store(true, ordering: .relaxed)
        let tap = try #require(system.tap(.flags))
        system.currentFlags = 0
        tap.context.sink.yield(.disabled(.flags))
        await pollUntil { events.contains { if case .released = $0 { true } else { false } } }
        #expect(events.contains { if case .released = $0 { true } else { false } })
    }

    // MARK: Health

    @Test func secureInputShowsOnTheWatchdogTickWhenIdle() async throws {
        let (service, system) = make()
        try service.start()
        defer { service.stop() }
        system.isSecureInputEnabled = true
        await pollUntil { service.health == .secureInputOn }
        #expect(service.health == .secureInputOn)
        system.isSecureInputEnabled = false
        await pollUntil { service.health == .listening }
        #expect(service.health == .listening)
    }
}
