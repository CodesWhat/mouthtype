import Foundation
import Testing
import MouthtypeCore

@testable import MouthtypeMac

@MainActor @Suite struct DictationLanguageSettingsModelTests {
    private func preferences() -> (UserDefaults, String) {
        let name = "DictationLanguageSettingsModelTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func languageChangesNotifyTheEngineAfterSavingTheChoice() {
        let (defaults, name) = preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        var seen: [DictationLanguageSetting] = []
        let model = SettingsModel(
            defaults: defaults,
            onDictationLanguageChanged: { choice in
                #expect(DictationLanguageSetting.load(defaults) == choice)
                seen.append(choice)
            })
        model.setDictationLanguage(.explicit(.hindi))
        model.setDictationLanguage(.explicit(.hindi))
        model.setDictationLanguage(.auto)
        #expect(seen == [.explicit(.hindi), .auto])
        DictationLanguageSetting.set(.explicit(.tamil), in: defaults)
        model.refresh()
        #expect(seen == [.explicit(.hindi), .auto, .explicit(.tamil)])
        model.refresh()
        #expect(seen.count == 3)
    }

    @Test func pickerListsAutoEnglishThenTheOtherLanguagesByName() {
        let choices = DictationLanguageSetting.pickerChoices
        #expect(choices.count == 29)
        #expect(choices[0].label == "Auto-detect" && choices[0].value == "auto")
        #expect(choices[1].label == "English" && choices[1].value == "en")
        let rest = choices.dropFirst(2).map(\.label)
        #expect(rest == rest.sorted())
        #expect(Set(choices.map(\.value)).count == 29)
        #expect(choices.allSatisfy { !$0.label.contains("\u{2014}") })
    }

    @Test func betaTagsMarkTheWeakerLanguagesOnly() {
        let labels = Dictionary(uniqueKeysWithValues: DictationLanguageSetting.pickerChoices.map { ($0.value, $0.label) })
        #expect(labels["lv"] == "Latvian (Beta)")
        #expect(labels["el"] == "Greek (Beta)")
        #expect(labels["de"] == "German")
        #expect(labels["en"] == "English")
        #expect(labels["ja"] == "Japanese (Beta)")
        #expect(labels["hi"] == "Hindi (Beta)")
        #expect(labels["ta"] == "Tamil (Beta)")
    }

    @Test func pickerValuesRoundTrip() {
        for choice in DictationLanguageSetting.pickerChoices {
            let setting = DictationLanguageSetting(pickerValue: choice.value)
            #expect(setting?.pickerValue == choice.value)
        }
        #expect(DictationLanguageSetting(pickerValue: "xx") == nil)
    }

    @Test func modelDefaultsToAutoAndSavesTheChoice() {
        let (defaults, name) = preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let model = SettingsModel(defaults: defaults)
        #expect(model.dictationLanguage == .auto)
        model.setDictationLanguage(.explicit(.german))
        #expect(model.dictationLanguage == .explicit(.german))
        #expect(DictationLanguageSetting.load(defaults) == .explicit(.german))
        model.setDictationLanguage(.auto)
        #expect(DictationLanguageSetting.load(defaults) == .auto)
    }

    @Test func refreshPicksUpAChangeMadeElsewhere() {
        let (defaults, name) = preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let model = SettingsModel(defaults: defaults)
        DictationLanguageSetting.set(.explicit(.polish), in: defaults)
        model.refresh()
        #expect(model.dictationLanguage == .explicit(.polish))
    }

    @Test func fastNoteShowsOnlyForFastUnderAnExplicitNonEnglishLanguage() {
        let (defaults, name) = preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let model = SettingsModel(defaults: defaults)
        model.setLevel(.light)
        #expect(!model.showsFastLanguageNote)
        model.setDictationLanguage(.explicit(.english))
        #expect(!model.showsFastLanguageNote)
        model.setDictationLanguage(.explicit(.french))
        #expect(model.showsFastLanguageNote)
        model.setLevel(.medium)
        #expect(!model.showsFastLanguageNote)
        #expect(!DictationLanguageSetting.fastEnglishOnlyNote.contains("\u{2014}"))
    }
}
