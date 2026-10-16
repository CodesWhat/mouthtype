import AppKit
import CoreGraphics
import MouthtypeCore
import Testing
@testable import MouthtypeMac

@Suite struct DictationShortcutTests {
    static let control = CGEventFlags.maskControl.rawValue
    static let option = CGEventFlags.maskAlternate.rawValue
    static let command = CGEventFlags.maskCommand.rawValue

    func sample(_ kind: TapSample.Kind, _ key: UInt16, _ flags: UInt64 = 0, _ time: UInt64 = 0) -> TapSample {
        TapSample(kind: kind, keyCode: key, flags: flags, timestamp: time)
    }

    @Test func aPlainKeyAndACombinationHaveBalancedHoldEdges() {
        for mods in [UInt64(0), Self.control | Self.option] {
            let shortcut = DictationShortcut(keyCode: 40, modifiers: mods, keyName: "K")
            var matcher = ShortcutMatcher()
            #expect({ !matcher.update(sample(.keyDown, 0, mods), shortcut: shortcut) }())
            #expect({ matcher.update(sample(.keyDown, 40, mods), shortcut: shortcut) }())
            #expect({ !matcher.update(sample(.keyUp, 40, mods), shortcut: shortcut) }())
        }
    }

    @Test func aMissingOrExtraModifierDoesNotStartTheShortcut() {
        let shortcut = DictationShortcut(keyCode: 40, modifiers: Self.control, keyName: "K")
        for flags in [UInt64(0), Self.control | Self.command] {
            var matcher = ShortcutMatcher()
            #expect({ !matcher.update(sample(.keyDown, 40, flags), shortcut: shortcut) }())
        }
    }

    @Test func releasingAModifierEndsTheHoldWithoutRearmingAStillHeldKey() {
        let shortcut = DictationShortcut(keyCode: 40, modifiers: Self.control, keyName: "K")
        var matcher = ShortcutMatcher()
        #expect({ matcher.update(sample(.keyDown, 40, Self.control), shortcut: shortcut) }())
        #expect({ !matcher.update(sample(.flagsChanged, 59), shortcut: shortcut) }())
        #expect({ !matcher.update(sample(.flagsChanged, 59, Self.control), shortcut: shortcut) }())
        #expect({ !matcher.update(sample(.keyUp, 40, Self.control), shortcut: shortcut) }())
        #expect({ matcher.update(sample(.keyDown, 40, Self.control), shortcut: shortcut) }())
    }

    @Test func aRightModifierAndAModifierOnlyCombinationWork() {
        let shortcut = DictationShortcut(keyCode: 61, modifiers: Self.control, keyName: "Right Option")
        var matcher = ShortcutMatcher()
        #expect({ !matcher.update(sample(.flagsChanged, 59, Self.control), shortcut: shortcut) }())
        #expect({ matcher.update(sample(.flagsChanged, 61, Self.control | Self.option), shortcut: shortcut) }())
        #expect({ !matcher.update(sample(.flagsChanged, 59, Self.option), shortcut: shortcut) }())
        #expect({ !matcher.update(sample(.flagsChanged, 61), shortcut: shortcut) }())
        #expect({ !matcher.update(sample(.flagsChanged, 58, Self.option), shortcut: shortcut) }())
    }

    @Test func anUnrelatedModifierChordMustFullyReleaseBeforeStarting() {
        let shortcut = DictationShortcut(keyCode: 61, keyName: "Right Option")
        var matcher = ShortcutMatcher()
        let values = [sample(.flagsChanged, 55, Self.command), sample(.flagsChanged, 61, Self.command | Self.option),
            sample(.flagsChanged, 55, Self.option), sample(.flagsChanged, 61), sample(.flagsChanged, 61, Self.option)]
            .map { matcher.update($0, shortcut: shortcut) }
        #expect(values == [false, false, false, false, true])
    }

    @Test func customKeysDriveExistingHoldDoubleTapAndEscapeGestures() {
        var mapper = HotkeyInputMapper(source: .shortcut(DictationShortcut(keyCode: 40, modifiers: Self.control, keyName: "K")))
        var engine = GestureEngine()
        var events: [GestureEvent] = []
        for s in [sample(.keyDown, 40, Self.control, 0), sample(.keyUp, 40, Self.control, 100),
                  sample(.keyDown, 40, Self.control, 200), sample(.keyUp, 40, Self.control, 300),
                  sample(.keyDown, 53, 0, 500)] {
            if let mapped = mapper.map(s, otherKeysHeld: { false }),
               let event = engine.process(mapped.keyEvent, now: Date(timeIntervalSinceReferenceDate: Double(s.timestamp) / 1000)) {
                events.append(event)
            }
            mapper.lockedRecording = engine.isLocked
        }
        #expect(events == [.pressed, .discarded(.tooShort), .pressed, .locked(.doubleTap), .cancelled(.escape)])
    }
}

@MainActor @Suite struct DictationShortcutSettingsTests {
    @Test func aFailedActivationDoesNotReplaceTheSavedShortcut() {
        let suite = "shortcut-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = DictationShortcut(keyCode: 61, keyName: "Right Option")
        ShortcutSettings.save(original, in: defaults)
        let replacement = DictationShortcut(keyCode: 40, keyName: "K")
        let error = ShortcutSettings.apply(replacement, in: defaults) { _ in "Input unavailable" }
        #expect(error == "Input unavailable" && ShortcutSettings.load(defaults) == original)
        #expect(ShortcutSettings.apply(replacement, in: defaults, activate: { _ in nil }) == nil)
        #expect(ShortcutSettings.load(defaults) == replacement)
    }

    @Test func invalidPreferencesFallBackAndCannotOverwriteASavedBinding() {
        let suite = "shortcut-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not JSON".utf8), forKey: ShortcutSettings.preferenceKey)
        #expect(ShortcutSettings.load(defaults) == nil)
        let original = DictationShortcut(keyCode: 61, keyName: "Right Option")
        ShortcutSettings.save(original, in: defaults)
        #expect(!ShortcutSettings.save(DictationShortcut(keyCode: 65535, keyName: "Bad"), in: defaults))
        #expect(ShortcutSettings.load(defaults) == original)
    }
    @Test func aShortcutSurvivesReloadAndResetRestoresFn() throws {
        let suite = "shortcut-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let shortcut = DictationShortcut(keyCode: 40, modifiers: DictationShortcutTests.control, keyName: "K")
        ShortcutSettings.save(shortcut, in: defaults)
        #expect(ShortcutSettings.load(defaults) == shortcut)
        ShortcutSettings.save(nil, in: defaults)
        #expect(ShortcutSettings.load(defaults) == nil)
    }
}
