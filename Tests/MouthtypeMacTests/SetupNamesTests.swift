import Foundation
import Testing

@testable import MouthtypeMac

@MainActor @Suite struct SetupNamesTests {
    private func make(
        _ body: (SetupModel, UserDefaults, () -> [Bool]) -> Void
    ) {
        let name = "SetupNamesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var changes: [Bool] = []
        let model = SetupModel(
            diagnostics: SettingsDiagnostics(), engine: EngineHost(), defaults: defaults,
            onBoostSavedWordsChanged: { changes.append($0) })
        body(model, defaults, { changes })
    }

    @Test func turningOnSetsBothSettingsAndStartsTheBoostDownload() {
        make { model, defaults, changes in
            #expect(model.offersNames)
            model.turnOnNames()
            #expect(VocabularyBoostSetting.isEnabled(defaults))
            #expect(ContextNamesSetting.isEnabled(defaults))
            #expect(defaults.object(forKey: ContextNamesSetting.key) as? Bool == true)
            #expect(changes() == [true])
            #expect(model.namesChoice == .turnedOn)
            #expect(model.offersNames)
        }
    }

    @Test func turningOnRestoresNamesOnScreenAfterItWasOff() {
        make { model, defaults, _ in
            ContextNamesSetting.set(false, in: defaults)
            model.turnOnNames()
            #expect(ContextNamesSetting.isEnabled(defaults))
        }
    }

    @Test func notNowChangesNothing() {
        make { model, defaults, changes in
            ContextNamesSetting.set(false, in: defaults)
            model.skipNames()
            #expect(!VocabularyBoostSetting.isEnabled(defaults))
            #expect(!ContextNamesSetting.isEnabled(defaults))
            #expect(changes().isEmpty)
            #expect(!model.offersNames)
        }
    }

    @Test func noOfferWhenBoostIsAlreadyOn() {
        make { model, defaults, _ in
            VocabularyBoostSetting.set(true, in: defaults)
            #expect(!model.offersNames)
        }
    }
}
