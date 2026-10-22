import AppKit
import CoreGraphics
import Testing
@testable import MouthtypeMac

@MainActor @Suite struct ShortcutRecorderTests {
    let control = CGEventFlags.maskControl.rawValue
    let option = CGEventFlags.maskAlternate.rawValue

    func event(_ kind: TapSample.Kind, _ code: UInt16, _ flags: UInt64 = 0) -> TapSample {
        TapSample(kind: kind, keyCode: code, flags: flags, timestamp: 0)
    }

    @Test func capturesACombinationOnlyAfterAllKeysAreReleased() {
        let recorder = ShortcutRecorder(saved: nil)
        recorder.begin()
        recorder.receive(event(.flagsChanged, 59, control))
        recorder.receive(event(.keyDown, 40, control), keyName: "K")
        #expect(!recorder.canSave)
        recorder.receive(event(.keyUp, 40, control))
        #expect(recorder.isRecording)
        recorder.receive(event(.flagsChanged, 59))
        #expect(recorder.canSave && !recorder.isRecording)
        #expect(recorder.draft == DictationShortcut(keyCode: 40, modifiers: control, keyName: "K"))
    }

    @Test func recordsASidedModifierOnlyComboInEitherPressOrder() {
        for reverse in [false, true] {
            let recorder = ShortcutRecorder(saved: nil)
            recorder.begin()
            recorder.receive(event(.flagsChanged, reverse ? 61 : 59, reverse ? option : control))
            recorder.receive(event(.flagsChanged, reverse ? 59 : 61, control | option))
            recorder.receive(event(.flagsChanged, reverse ? 59 : 61, reverse ? option : control))
            recorder.receive(event(.flagsChanged, reverse ? 61 : 59))
            let expected =
                reverse
                ? DictationShortcut(keyCode: 59, modifiers: option, keyName: "Left Control")
                : DictationShortcut(keyCode: 61, modifiers: control, keyName: "Right Option")
            #expect(recorder.draft == expected && recorder.canSave)
        }
    }

    @Test func escapeAndSpaceCanBeTheChosenKey() {
        for (code, name) in [(UInt16(53), "Escape"), (49, "Space")] {
            let recorder = ShortcutRecorder(saved: nil)
            recorder.begin()
            recorder.receive(event(.keyDown, code), keyName: name)
            recorder.receive(event(.keyUp, code))
            #expect(recorder.draft?.keyCode == code && recorder.canSave)
        }
    }

    @Test func cancelRestoresTheOriginalAndResetSelectsFn() {
        let original = DictationShortcut(keyCode: 61, keyName: "Right Option")
        let recorder = ShortcutRecorder(saved: original)
        recorder.begin()
        recorder.receive(event(.keyDown, 40), keyName: "K")
        recorder.cancelRecording()
        #expect(recorder.draft == original && !recorder.canSave)
        recorder.useDefault()
        #expect(recorder.draft == nil && recorder.canSave)
    }

    @Test func aSaveErrorKeepsTheDraftForRetry() {
        let recorder = ShortcutRecorder(saved: nil)
        recorder.useDefault()
        #expect(!recorder.save { _ in "The input listener could not start." })
        #expect(recorder.error == "The input listener could not start." && recorder.canSave)
        #expect(recorder.save { _ in nil })
    }

    @Test func capsLockIsNamedAndReadyWithoutAMissingKeyUp() {
        let recorder = ShortcutRecorder(saved: nil)
        recorder.begin()
        recorder.receive(event(.flagsChanged, 57, CGEventFlags.maskAlphaShift.rawValue))
        #expect(recorder.draft?.isCapsLock == true && recorder.canSave)
        #expect(recorder.hint.contains("toggle"))
    }

    @Test func modifiersAlreadyHeldWhenCaptureStartsMustAlsoRelease() {
        let recorder = ShortcutRecorder(saved: nil)
        recorder.begin()
        recorder.receive(event(.keyDown, 40, control), keyName: "K")
        recorder.receive(event(.keyUp, 40, control))
        #expect(!recorder.canSave)
        recorder.receive(event(.flagsChanged, 59))
        #expect(recorder.canSave)
    }

    private func keyEvent(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = [], in window: NSWindow) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    @Test func sheetCapturesCommandQBeforeMenuShortcutsAndCanRenderOffscreen() throws {
        _ = NSApplication.shared
        var closed = 0
        let sheet = ShortcutRecorderSheet(saved: nil, apply: { _ in nil }, onClose: { closed += 1 })
        let window = sheet.window
        sheet.recorder.begin()
        #expect(window.performKeyEquivalent(with: try keyEvent("q", code: 12, flags: .command, in: window)))
        #expect(sheet.recorder.draft?.keyCode == 12)
        sheet.recorder.cancelRecording()
        let view = try #require(window.contentView)
        view.layoutSubtreeIfNeeded()
        #expect(view.bounds.width == 520 && view.bounds.height == 330)
        if let path = ProcessInfo.processInfo.environment["MOUTHTYPE_SHORTCUT_SNAPSHOT"] {
            view.appearance = NSAppearance(named: .aqua)
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor(calibratedWhite: 0.96, alpha: 1).cgColor
            view.displayIfNeeded()
            let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            try #require(image.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
        sheet.close()
        sheet.close()
        #expect(closed == 1)
    }

    @Test func escapeCancelsTheSheetWithoutSavingAndReleasesCapture() throws {
        _ = NSApplication.shared
        var closed = 0
        var applied: [DictationShortcut?] = []
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        let sheet = ShortcutRecorderSheet(
            saved: nil,
            apply: {
                applied.append($0); return nil
            }, onClose: { closed += 1 })
        sheet.present(over: parent)
        // Mid-recording, Escape is a shortcut candidate like any other key and does not close the sheet.
        sheet.recorder.begin()
        #expect(sheet.window.performKeyEquivalent(with: try keyEvent("\u{1b}", code: 53, in: sheet.window)))
        #expect(closed == 0)
        sheet.recorder.cancelRecording()
        // Idle, Escape presses Cancel.
        #expect(sheet.window.performKeyEquivalent(with: try keyEvent("\u{1b}", code: 53, in: sheet.window)))
        #expect(closed == 1)
        #expect(applied.isEmpty)
        #expect(!sheet.recorder.isRecording)
        let stray = try keyEvent("k", code: 40, in: sheet.window)
        #expect(!sheet.capture(stray))
        parent.close()
    }

    @Test func closingTheSheetWhileRecordingStopsCapture() {
        _ = NSApplication.shared
        var closed = 0
        let sheet = ShortcutRecorderSheet(saved: nil, apply: { _ in nil }, onClose: { closed += 1 })
        sheet.recorder.begin()
        #expect(sheet.recorder.isRecording)
        sheet.close()
        #expect(!sheet.recorder.isRecording && closed == 1)
    }
}

@Suite struct CustomShortcutTapTests {
    @Test func aReleasedComboStillConsumesItsKeyUpAndRepeats() {
        let shortcut = DictationShortcut(keyCode: 40, modifiers: DictationShortcutTests.control, keyName: "K")
        let up = TapSample(kind: .keyUp, keyCode: 40, flags: 0, timestamp: 0)
        #expect(
            TapPolicy.decide(
                up, role: .keys, recording: false, swallowedKey: nil, pending: .shortcut,
                shortcut: shortcut) == TapDecision(swallow: true, deliver: true))
        let typed = TapSample(kind: .keyDown, keyCode: 40, flags: 0, timestamp: 0)
        let decision = TapPolicy.decide(typed, role: .keys, recording: false, swallowedKey: nil, shortcut: shortcut)
        #expect(!decision.swallow)
        #expect(TapPolicy.countsAsUserInput(typed, decision: decision, swallowedKey: nil))
        let trigger = TapPolicy.decide(typed, role: .keys, recording: false, swallowedKey: nil, shortcut: shortcut, shortcutHeld: true)
        #expect(trigger.swallow && !TapPolicy.countsAsUserInput(typed, decision: trigger, swallowedKey: nil))
        #expect(TapPolicy.pendingChange(for: typed, decision: trigger, shortcutKey: 40) == .set(.shortcut))
    }
}

@MainActor @Suite struct CustomShortcutServiceTests {
    private func events(_ service: HotkeyService, count: Int) async -> [HotkeyEvent] {
        let collector = Task { @MainActor in
            var received: [HotkeyEvent] = []
            for await event in service.events {
                received.append(event)
                if received.count == count { break }
            }
            return received
        }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { collector.cancel() }
        }
        let received = await collector.value
        deadline.cancel()
        return received
    }
    @Test(.timeLimit(.minutes(1))) func spaceItselfDoesNotLockAndCapsLockToggles() async {
        for code in [UInt16(49), 57] {
            let shortcut = DictationShortcut(keyCode: code, keyName: code == 49 ? "Space" : "Caps Lock")
            let service = HotkeyService(options: .init(source: .shortcut(shortcut)), otherKeysHeld: { _ in false })
            defer { service.stop() }
            let kind: TapSample.Kind = code == 57 ? .flagsChanged : .keyDown
            service.process(TapSample(kind: kind, keyCode: code, flags: code == 57 ? CGEventFlags.maskAlphaShift.rawValue : 0, timestamp: 0))
            service.process(TapSample(kind: code == 57 ? .flagsChanged : .keyUp, keyCode: code, flags: 0, timestamp: 1_000_000_000))
            let expected: [HotkeyEvent] =
                code == 57
                ? [.pressed(at: 0), .locked(at: 0, trigger: .fnSpace), .released(at: 1_000_000_000)]
                : [.pressed(at: 0), .released(at: 1_000_000_000)]
            #expect(await events(service, count: expected.count) == expected)
        }
    }

    @Test(.timeLimit(.minutes(1))) func capsLockCanStartAgainImmediatelyAfterEscape() async {
        let service = HotkeyService(options: .init(source: .shortcut(DictationShortcut(keyCode: 57, keyName: "Caps Lock"))), otherKeysHeld: { _ in false })
        defer { service.stop() }
        service.process(TapSample(kind: .flagsChanged, keyCode: 57, flags: CGEventFlags.maskAlphaShift.rawValue, timestamp: 0))
        service.process(TapSample(kind: .keyDown, keyCode: 53, flags: 0, timestamp: 100))
        service.process(TapSample(kind: .flagsChanged, keyCode: 57, flags: 0, timestamp: 200))
        #expect(
            await events(service, count: 5) == [
                .pressed(at: 0), .locked(at: 0, trigger: .fnSpace),
                .cancelled(reason: .escape), .pressed(at: 200), .locked(at: 200, trigger: .fnSpace),
            ])
    }
}
