import Foundation
import MouthtypeCore
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
            #expect(model.modelEntries.last?.state == .available)
            model.turnOnNames()
            #expect(VocabularyBoostSetting.isEnabled(defaults))
            #expect(ContextNamesSetting.isEnabled(defaults))
            #expect(defaults.object(forKey: ContextNamesSetting.key) as? Bool == true)
            #expect(changes() == [true])
            #expect(model.modelEntries.last?.state == .preparing)
        }
    }

    @Test func turningOnRestoresNamesOnScreenAfterItWasOff() {
        make { model, defaults, _ in
            ContextNamesSetting.set(false, in: defaults)
            model.turnOnNames()
            #expect(ContextNamesSetting.isEnabled(defaults))
        }
    }

    @Test func aBoostThatIsAlreadyOnShowsItsStatusInsteadOfADownloadButton() {
        make { model, defaults, _ in
            VocabularyBoostSetting.set(true, in: defaults)
            #expect(model.modelEntries.last?.state != .available)
        }
    }

    @Test func theModelsPageListsSpeechBothCleanupModelsAndNames() {
        let listing = ModelsListing(models: [
            CleanupModelStatus(level: .light, name: "S1-mini", sizeMB: 1447, status: .available, selected: true),
            CleanupModelStatus(level: .medium, name: "Gemma 4 E4B", sizeMB: 5150, status: .done, selected: false),
        ])
        let model = SetupModel(diagnostics: SettingsDiagnostics(), engine: EngineHost(), cleanup: listing, defaults: UserDefaults(suiteName: "SetupNamesTests-\(UUID().uuidString)")!)
        let entries = model.modelEntries
        #expect(entries.map(\.id) == [.speech, .cleanup(.light), .cleanup(.medium), .names])
        #expect(entries.map(\.title) == ["Speech model", "Fast cleanup", "Thorough cleanup", "Names model"])
        #expect(entries.map(\.state) == [.preparing, .available, .ready, .available])
        #expect(entries.allSatisfy { $0.detail.count <= 70 && !$0.detail.contains("\u{2014}") && !$0.detail.contains("\u{2026}") })
    }

    @Test func continuingFromTheModelsPageMovesToTheFinalCard() {
        make { model, _, _ in
            #expect(!model.modelsReviewed)
            model.finishModels()
            #expect(model.modelsReviewed)
        }
    }
}

@MainActor private final class ModelsListing: CleanupModelListing {
    var models: [CleanupModelStatus]
    init(models: [CleanupModelStatus]) { self.models = models }
    func cleanupModels() -> [CleanupModelStatus] { models }
    func downloadCleanupModel(_ level: CleanupLevel) {}
    func cancelCleanupDownload(_ level: CleanupLevel) {}
}
