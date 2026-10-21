import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor
@Suite struct AutomationRouterTests {
    /// Records which action fired, by name, so a test can assert exactly one fired.
    @MainActor final class Recorder {
        var calls: [String] = []
        var actions: AutomationActions {
            AutomationActions(
                startDictation: { self.calls.append("start") },
                stopDictation: { self.calls.append("stop") },
                toggleDictation: { self.calls.append("toggle") },
                cancelDictation: { self.calls.append("cancel") },
                copyLast: { self.calls.append("copy-last") },
                pasteLast: { self.calls.append("paste-last") },
                open: { self.calls.append("open:\($0.rawValue)") }
            )
        }
    }

    func url(_ text: String) -> URL { URL(string: text)! }

    @Test func parsesEveryVerb() {
        let expected: [String: AutomationCommand] = [
            "start": .start, "stop": .stop, "toggle": .toggle, "cancel": .cancel,
            "copy-last": .copyLast, "paste-last": .pasteLast, "open": .open(.settings),
        ]
        #expect(Set(expected.keys) == Set(AutomationCommand.verbs))
        for (verb, command) in expected {
            #expect(AutomationURL.parse(url("mouthtype://\(verb)")) == .success(command))
            #expect(command.verb == verb)
        }
    }

    @Test func everyVerbReachesExactlyOneAction() {
        for verb in AutomationCommand.verbs {
            let recorder = Recorder()
            let router = AutomationRouter(actions: recorder.actions, isEnabled: { true })
            let outcome = router.handle(url("mouthtype://\(verb)"))
            guard case .performed = outcome else {
                Issue.record("\(verb) was not performed")
                continue
            }
            #expect(recorder.calls.count == 1, "\(verb): \(recorder.calls)")
        }
        // And no two verbs share an action.
        var seen = Set<String>()
        for verb in AutomationCommand.verbs {
            let recorder = Recorder()
            AutomationRouter(actions: recorder.actions, isEnabled: { true }).handle(url("mouthtype://\(verb)"))
            let name = recorder.calls[0].split(separator: ":").first.map(String.init) ?? ""
            #expect(seen.insert(name).inserted, "\(verb) shares an action")
        }
    }

    @Test func openTakesAPageByName() {
        for page in AutomationPage.allCases {
            #expect(AutomationURL.parse(url("mouthtype://open?page=\(page.rawValue)")) == .success(.open(page)))
        }
        #expect(AutomationURL.parse(url("mouthtype://open?page=Appearance")) == .success(.open(.appearance)))
        #expect(AutomationURL.parse(url("mouthtype://open?page=nope")) == .failure(.unknownPage("nope")))
    }

    @Test func rejectsUnknownAndMalformedURLs() {
        #expect(AutomationURL.parse(url("mouthtype://format-disk")) == .failure(.unknownVerb("format-disk")))
        #expect(AutomationURL.parse(url("mouthtype://")) == .failure(.unknownVerb("")))
        #expect(AutomationURL.parse(url("mouthtype://start/extra")) == .failure(.unexpectedPath))
        #expect(AutomationURL.parse(url("https://start")) == .failure(.wrongScheme))
    }

    @Test func rejectedURLsHaveNoSideEffects() {
        let recorder = Recorder()
        let router = AutomationRouter(actions: recorder.actions, isEnabled: { true })
        #expect(router.handle(url("mouthtype://reboot")) == .rejected(.unknownVerb("reboot")))
        #expect(router.handle(url("mouthtype://open?page=nope")) == .rejected(.unknownPage("nope")))
        #expect(recorder.calls.isEmpty)
    }

    @Test func recordingAndInsertingVerbsNeedTheOptIn() {
        let recorder = Recorder()
        let router = AutomationRouter(actions: recorder.actions, isEnabled: { false })
        for verb in ["start", "stop", "toggle", "cancel", "copy-last", "paste-last"] {
            guard case .disabled = router.handle(url("mouthtype://\(verb)")) else {
                Issue.record("\(verb) ran while disabled")
                continue
            }
        }
        #expect(recorder.calls.isEmpty)
        #expect(router.handle(url("mouthtype://open?page=general")) == .performed(.open(.general)))
        #expect(recorder.calls == ["open:general"])
    }

    @Test func optInComesFromDefaults() {
        let suite = "AutomationRouterTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = Recorder()
        let router = AutomationRouter(actions: recorder.actions, defaults: defaults)
        #expect(router.handle(url("mouthtype://toggle")) == .disabled(.toggle))
        defaults.set(true, forKey: AutomationRouter.enabledKey)
        #expect(router.handle(url("mouthtype://toggle")) == .performed(.toggle))
        #expect(recorder.calls == ["toggle"])
    }

    @Test func everyOpenPageRoutesToItsNewHome() {
        let expected: [AutomationPage: SettingsDestination?] = [
            .home: .page(.home), .settings: nil, .stats: .page(.stats), .records: .page(.stats), .spellings: .page(.dictionary),
            .phrases: .page(.transforms), .transcribe: .transcribeFile, .general: .settings(.general), .writing: .page(.style),
            .appearance: .page(.appearance), .diagnostics: .settings(.health),
        ]
        #expect(Set(expected.keys) == Set(AutomationPage.allCases))
        for (page, target) in expected {
            #expect(page.destination == target)
        }
    }

    @Test func openByURLGoesThroughSelectSoADraftStillAsks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-automation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suite = "AutomationOpen-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir)
        }
        let vocabulary = FileVocabulary(url: dir.appendingPathComponent("dictionary.json"))
        let spellings = SpellingEditor(store: vocabulary)
        var transcribeOpens = 0
        let model = SettingsModel(defaults: defaults, spellings: spellings,
            spellingSuggestions: SpellingSuggestionsModel(vocabulary: vocabulary, dismissedURL: dir.appendingPathComponent("dismissed.json")),
            phrases: PhraseEditor(store: FilePhrases(url: dir.appendingPathComponent("phrases.json"))),
            openTranscribeWindow: { transcribeOpens += 1 })
        var asked = 0
        var answer = false
        model.confirmDiscard = { _, _ in asked += 1; return answer }
        let router = AutomationRouter(actions: AutomationActions(
            startDictation: {}, stopDictation: {}, toggleDictation: {}, cancelDictation: {}, copyLast: {}, pasteLast: {},
            open: { if let destination = $0.destination { model.open(destination) } }
        ), isEnabled: { false })

        model.page = .dictionary
        spellings.newSpelling()
        spellings.heardInput = "mouth type"
        #expect(router.handle(url("mouthtype://open?page=appearance")) == .performed(.open(.appearance)))
        #expect(model.page == .dictionary && spellings.isDirty && asked == 1)

        answer = true
        router.handle(url("mouthtype://open?page=writing"))
        #expect(model.page == .style && !spellings.isDirty && asked == 2)

        router.handle(url("mouthtype://open?page=home"))
        #expect(model.page == .home && asked == 2)

        router.handle(url("mouthtype://open?page=diagnostics"))
        #expect(model.page == .home && model.settingsOpen && model.modalPage == .health)
        router.handle(url("mouthtype://open?page=records"))
        #expect(model.page == .stats && !model.settingsOpen)
        router.handle(url("mouthtype://open?page=transcribe"))
        #expect(model.page == .stats && !model.settingsOpen && transcribeOpens == 1)
    }
}
