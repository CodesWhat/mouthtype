import CoreGraphics
import Foundation
import Testing
@testable import MouthtypeMac

@MainActor
@Suite struct PasteChordTests {
    @Test(arguments: PasteChord.allCases)
    func postsOnlyTheSelectedModifiersToTheCapturedPID(chord: PasteChord) {
        var flags: [CGEventFlags] = []
        var codes: [Int64] = []
        var destinations: [pid_t] = []
        var stamps: [Int64] = []
        let poster = SystemPasteEventPoster(stamp: 456, post: { event, pid in
            flags.append(event.flags)
            codes.append(event.getIntegerValueField(.keyboardEventKeycode))
            destinations.append(pid)
            stamps.append(event.getIntegerValueField(.eventSourceUserData))
        })
        let expected: CGEventFlags
        switch chord {
        case .commandV: expected = .maskCommand
        case .commandShiftV: expected = [.maskCommand, .maskShift]
        case .controlShiftV: expected = [.maskControl, .maskShift]
        }
        #expect(poster.postPaste(keyCode: 42, targetPID: 321, chord: chord))
        #expect(flags == [expected, expected])
        #expect(codes == [42, 42] && destinations == [321, 321] && stamps == [456, 456])
    }

    @Test func shortcutIsSavedPerAppAndDefaultRemovesOnlyThatOverride() throws {
        let name = "PasteChordTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(PasteSettings.chord(for: nil, defaults: defaults) == .commandV)
        #expect(PasteSettings.chord(for: "com.example.one", defaults: defaults) == .commandV)
        PasteSettings.setChord(.controlShiftV, bundleID: "com.example.one", defaults: defaults)
        PasteSettings.setChord(.commandShiftV, bundleID: "com.example.two", defaults: defaults)
        #expect(PasteSettings.chord(for: "com.example.one", defaults: defaults) == .controlShiftV)
        #expect(PasteSettings.chord(for: "com.example.two", defaults: defaults) == .commandShiftV)
        PasteSettings.setChord(.commandV, bundleID: "com.example.one", defaults: defaults)
        #expect(PasteSettings.chord(for: "com.example.one", defaults: defaults) == .commandV)
        #expect(PasteSettings.chord(for: "com.example.two", defaults: defaults) == .commandShiftV)
    }
    @Test func invalidStoredShortcutsFallBackWithoutChangingOtherAppEntries() throws {
        let name = "PasteChordTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["com.example.one": "unknown-chord", "com.example.two": 123], forKey: PasteSettings.chordKey)
        #expect(PasteSettings.chord(for: "com.example.one", defaults: defaults) == .commandV)
        #expect(PasteSettings.chord(for: "com.example.two", defaults: defaults) == .commandV)
        PasteSettings.setChord(.controlShiftV, bundleID: "com.example.one", defaults: defaults)
        #expect(defaults.dictionary(forKey: PasteSettings.chordKey)?["com.example.two"] as? Int == 123)
        #expect(PasteSettings.chord(for: "com.example.one", defaults: defaults) == .controlShiftV)
    }

}
