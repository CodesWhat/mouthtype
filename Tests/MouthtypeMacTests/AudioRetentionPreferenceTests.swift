import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@Suite struct AudioRetentionPreferenceTests {
    @Test func absentAndUnknownValuesKeepBalancedWithoutOverwritingSavedValues() throws {
        let name = "AudioRetentionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AudioRetentionPreference.load(defaults) == AudioRetentionPolicy())
        defaults.set("future-choice", forKey: AudioRetentionPreference.ageKey)
        defaults.set(true, forKey: AudioRetentionPreference.sizeKey)
        #expect(AudioRetentionPreference.load(defaults) == AudioRetentionPolicy())
        #expect(defaults.string(forKey: AudioRetentionPreference.ageKey) == "future-choice")
        #expect(defaults.object(forKey: AudioRetentionPreference.sizeKey) as? Bool == true)
    }

    @Test func independentControlsRoundTripAndPreserveUnrelatedPreferences() throws {
        let name = "AudioRetentionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("untouched", forKey: "other-setting")
        AudioRetentionPreference.setAge(.noAgeLimit, in: defaults)
        AudioRetentionPreference.setSize(.gb10, in: defaults)
        #expect(AudioRetentionPreference.load(defaults) == AudioRetentionPolicy(age: .noAgeLimit, size: .gb10))
        AudioRetentionPreference.setAge(.days14, in: defaults)
        #expect(AudioRetentionPreference.load(defaults) == AudioRetentionPolicy(age: .days14, size: .gb10))
        #expect(defaults.string(forKey: "other-setting") == "untouched")
    }
}
