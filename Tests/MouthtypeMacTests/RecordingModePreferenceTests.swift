import Foundation
import CoreGraphics
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor @Suite struct RecordingModePreferenceTests {
    private func preferences() -> (UserDefaults, String) {
        let name = "RecordingModeTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func holdIsDefaultAndMalformedPreferencesStayIntact() {
        let (defaults, name) = preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(RecordingModePreference.current(defaults) == .hold)
        #expect(defaults.object(forKey: "recordingMode") == nil)
        for value in ["unknown", "Toggle", 17, Data([1, 2])] as [Any] {
            defaults.set(value, forKey: "recordingMode")
            #expect(RecordingModePreference.current(defaults) == .hold)
            #expect((defaults.object(forKey: "recordingMode") as? NSObject)?.isEqual(value) == true)
        }
    }

    @Test func modeRoundTripsWithoutChangingShortcut() {
        let (defaults, name) = preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let shortcut = DictationShortcut(keyCode: 58, keyName: "Option")
        ShortcutSettings.save(shortcut, in: defaults)
        for mode in RecordingMode.allCases {
            RecordingModePreference.set(mode, in: defaults)
            #expect(RecordingModePreference.current(defaults) == mode)
            #expect(defaults.string(forKey: "recordingMode") == mode.rawValue)
            #expect(ShortcutSettings.load(defaults) == shortcut)
        }
    }

    @Test func changingModeActivatesBeforeSavingAndRefreshNeverActivates() {
        let (defaults, name) = preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        var activated: [RecordingMode] = []
        let model = SettingsModel(
            defaults: defaults,
            onRecordingModeChanged: { mode in
                #expect(RecordingModePreference.current(defaults) == .hold)
                activated.append(mode)
                return nil
            })
        #expect(model.recordingMode == .hold && model.recordingModeError == nil)
        model.refresh()
        #expect(activated.isEmpty)
        model.setRecordingMode(.toggle)
        #expect(activated == [.toggle])
        #expect(model.recordingMode == .toggle && model.recordingModeError == nil)
        #expect(RecordingModePreference.current(defaults) == .toggle)
        RecordingModePreference.set(.hold, in: defaults)
        model.refresh()
        #expect(model.recordingMode == .hold && activated == [.toggle])
    }

    @Test func instructionsMatchModeAndModifiedCapsLockBehavior() {
        let (defaults, name) = preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let model = SettingsModel(defaults: defaults)
        #expect(model.recordingInstructions.contains("Hold"))
        model.setRecordingMode(.toggle)
        #expect(model.recordingInstructions.contains("Press"))
        #expect(model.recordingInstructions.contains("again"))
        #expect(model.recordingInstructions.contains("Escape cancels."))
        let shortcut = DictationShortcut(keyCode: 57, modifiers: CGEventFlags.maskAlternate.rawValue, keyName: "Caps Lock")
        ShortcutSettings.save(shortcut, in: defaults)
        model.refresh()
        model.setRecordingMode(.hold)
        #expect(model.recordingMode == .hold)
        #expect(model.shortcut == "⌥Caps Lock")
        #expect(model.recordingInstructions.contains("Caps Lock always uses a toggle"))
        #expect(model.recordingInstructions.contains("Escape cancels."))
        ShortcutSettings.save(DictationShortcut(keyCode: 53, keyName: "Escape"), in: defaults)
        model.refresh()
        model.setRecordingMode(.toggle)
        #expect(!model.recordingInstructions.contains("Escape cancels."))
        #expect(model.recordingInstructions.contains("Cancel Dictation in the menu"))
    }

    @Test func failedActivationKeepsSavedModeAndRetryClearsError() {
        let (defaults, name) = preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        RecordingModePreference.set(.toggle, in: defaults)
        let activation = RecordingModeActivationState()
        let model = SettingsModel(defaults: defaults, onRecordingModeChanged: { _ in activation.error })
        model.setRecordingMode(.hold)
        #expect(model.recordingMode == .toggle)
        #expect(RecordingModePreference.current(defaults) == .toggle)
        #expect(model.recordingModeError == "The input listener could not change mode.")
        activation.error = nil
        model.setRecordingMode(.hold)
        #expect(model.recordingMode == .hold && model.recordingModeError == nil)
        #expect(RecordingModePreference.current(defaults) == .hold)
    }
}

@MainActor private final class RecordingModeActivationState {
    var error: String? = "The input listener could not change mode."
}
