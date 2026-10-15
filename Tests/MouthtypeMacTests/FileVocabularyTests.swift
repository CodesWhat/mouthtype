import AppKit
import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor
@Suite struct FileVocabularyTests {
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-dictionary-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes so the modification date always moves, whatever the filesystem's clock resolution.
    private func write(_ text: String, to url: URL, second: Int = 0) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_000 + Double(second))], ofItemAtPath: url.path)
    }

    @Test func aMissingFileMeansNoRules() {
        let vocabulary = FileVocabulary(url: directory().appendingPathComponent("dictionary.json"))
        #expect(vocabulary.dictionary().isEmpty && vocabulary.status == .missing && vocabulary.snippets().isEmpty)
    }

    @Test func theFileIsLoadedAtLaunch() throws {
        let url = directory().appendingPathComponent("dictionary.json")
        try write(#"[{"heard": "hove", "written": "Hov", "starred": true}, {"heard": "mouth type", "written": "Mouthtype"}]"#, to: url)
        let vocabulary = FileVocabulary(url: url)
        #expect(vocabulary.status == .loaded(count: 2))
        #expect(vocabulary.dictionary() == [
            DictionaryRule(heard: "hove", written: "Hov", starred: true),
            DictionaryRule(heard: "mouth type", written: "Mouthtype", starred: false),
        ])
    }

    @Test func aChangedFileIsReloadedOnTheNextRead() throws {
        let url = directory().appendingPathComponent("dictionary.json")
        try write(#"[{"heard": "a", "written": "A"}]"#, to: url, second: 0)
        let vocabulary = FileVocabulary(url: url)
        #expect(vocabulary.dictionary().map(\.written) == ["A"])
        try write(#"[{"heard": "a", "written": "A"}, {"heard": "b", "written": "B"}]"#, to: url, second: 5)
        #expect(vocabulary.dictionary().map(\.written) == ["A", "B"])
        try FileManager.default.removeItem(at: url)
        #expect(vocabulary.dictionary().isEmpty && vocabulary.status == .missing)
    }

    @Test func malformedJSONKeepsTheLastGoodRulesAndReportsTheError() throws {
        let url = directory().appendingPathComponent("dictionary.json")
        try write(#"[{"heard": "a", "written": "A"}]"#, to: url, second: 0)
        let vocabulary = FileVocabulary(url: url)
        try write(#"[{"heard": "a", "written": "A"}, "#, to: url, second: 5)
        #expect(vocabulary.dictionary().map(\.written) == ["A"])
        guard case .error = vocabulary.status else { Issue.record("status \(vocabulary.status)"); return }
        try write(#"{"heard": "a"}"#, to: url, second: 9)
        #expect(vocabulary.dictionary().map(\.written) == ["A"])
        guard case .error = vocabulary.status else { Issue.record("status \(vocabulary.status)"); return }
        try write(#"[{"heard": "c", "written": "C"}]"#, to: url, second: 12)
        #expect(vocabulary.dictionary().map(\.written) == ["C"] && vocabulary.status == .loaded(count: 1))
    }

    @Test func aBrokenFileAtLaunchStartsEmptyWithTheError() throws {
        let url = directory().appendingPathComponent("dictionary.json")
        try write("not json", to: url)
        let vocabulary = FileVocabulary(url: url)
        #expect(vocabulary.dictionary().isEmpty)
        guard case .error = vocabulary.status else { Issue.record("status \(vocabulary.status)"); return }
    }

    @Test func creatingTheFileWritesTwoWorkingExamplesAndNeverOverwrites() throws {
        let url = directory().appendingPathComponent("sub/dictionary.json")
        let vocabulary = FileVocabulary(url: url)
        #expect(try vocabulary.createIfMissing() == url)
        #expect(vocabulary.status == .loaded(count: 2))
        #expect(vocabulary.dictionary().map(\.written) == ["Mouthtype", "Superwhisper"])
        try write(#"[{"heard": "x", "written": "X"}]"#, to: url, second: 40)
        try vocabulary.createIfMissing()
        #expect(vocabulary.dictionary().map(\.written) == ["X"])
    }

    @Test func theDictionaryReachesTheDeterministicPipeline() throws {
        let url = directory().appendingPathComponent("dictionary.json")
        try write(#"[{"heard": "mouth type", "written": "Mouthtype"}]"#, to: url)
        let vocabulary = FileVocabulary(url: url)
        let result = TextPipeline().run(TextPipelineInput(text: "the mouth type build", dictionary: vocabulary.dictionary()))
        #expect(result.text == "The Mouthtype build")
    }

    // MARK: Saving

    @Test func savingCreatesAMissingFileWithTheOneRule() throws {
        let url = directory().appendingPathComponent("sub/dictionary.json")
        let vocabulary = FileVocabulary(url: url)
        #expect(try vocabulary.save(heard: "Hove", written: "Hov") == .added)
        #expect(vocabulary.status == .loaded(count: 1))
        #expect(vocabulary.dictionary() == [DictionaryRule(heard: "Hove", written: "Hov")])
    }

    @Test func savingAppendsAndLeavesTheRestOfTheFileAsTheUserWroteIt() throws {
        let url = directory().appendingPathComponent("dictionary.json")
        let original = "[\n  { \"heard\": \"a\",   \"written\": \"A\", \"starred\": true, \"note\": \"mine\" }\n]\n"
        try write(original, to: url)
        let vocabulary = FileVocabulary(url: url)
        #expect(try vocabulary.save(heard: "Hove", written: "Hov") == .added)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix(String(original.dropLast(3))))
        #expect(text.contains(#"{ "heard": "Hove", "written": "Hov", "starred": false }"#))
        #expect(vocabulary.dictionary() == [DictionaryRule(heard: "a", written: "A", starred: true), DictionaryRule(heard: "Hove", written: "Hov")])
    }

    @Test func savingIntoAnEmptyListWorks() throws {
        let url = directory().appendingPathComponent("dictionary.json")
        try write("[]\n", to: url)
        let vocabulary = FileVocabulary(url: url)
        try vocabulary.save(heard: "x", written: "X")
        try vocabulary.save(heard: "y", written: "Y")
        #expect(vocabulary.dictionary().map(\.written) == ["X", "Y"])
    }

    @Test func savingARuleWithTheSameHeardUpdatesItsWrittenForm() throws {
        let url = directory().appendingPathComponent("dictionary.json")
        try write(#"[{"heard": "b", "written": "B", "starred": true, "note": "keep"}, {"heard": "Hove", "written": "Hoove"}]"#, to: url)
        let vocabulary = FileVocabulary(url: url)
        #expect(try vocabulary.save(heard: "hove", written: "Hov") == .updated)
        #expect(vocabulary.dictionary() == [DictionaryRule(heard: "b", written: "B", starred: true), DictionaryRule(heard: "Hove", written: "Hov")])
        #expect(try String(contentsOf: url, encoding: .utf8).contains(#""note": "keep""#))
        #expect(try vocabulary.save(heard: "Hove", written: "Hov") == .unchanged)
    }

    @Test func aMalformedFileIsLeftExactlyAsItIs() throws {
        let url = directory().appendingPathComponent("dictionary.json")
        for broken in ["[oops", #"{"heard": "a"}"#, #"[{"heard": "a"}]"#, ""] {
            try write(broken, to: url)
            let vocabulary = FileVocabulary(url: url)
            #expect(throws: FileVocabulary.WriteError.self) { try vocabulary.save(heard: "x", written: "X") }
            #expect(throws: FileVocabulary.WriteError.self) { try vocabulary.remove(heard: "x") }
            #expect(try String(contentsOf: url, encoding: .utf8) == broken)
        }
    }

    @Test func removingTakesOutOnlyThatRule() throws {
        let url = directory().appendingPathComponent("dictionary.json")
        try write(#"[{"heard": "a", "written": "A"}, {"heard": "Hove", "written": "Hov"}]"#, to: url)
        let vocabulary = FileVocabulary(url: url)
        #expect(try vocabulary.remove(heard: "hove"))
        #expect(vocabulary.dictionary().map(\.written) == ["A"])
        #expect(try !vocabulary.remove(heard: "hove"))
        #expect(try vocabulary.remove(heard: "a") && vocabulary.dictionary().isEmpty)
        #expect(try !FileVocabulary(url: directory().appendingPathComponent("none.json")).remove(heard: "x"))
    }

    @Test func quotesAndUnicodeSurviveASave() throws {
        let url = directory().appendingPathComponent("dictionary.json")
        let vocabulary = FileVocabulary(url: url)
        try vocabulary.save(heard: #"zoe "z""#, written: "Zo\u{EB}/\\")
        #expect(vocabulary.dictionary() == [DictionaryRule(heard: #"zoe "z""#, written: "Zo\u{EB}/\\")])
    }

    // MARK: Menu

    @Test func editDictionaryCreatesTheFileAndOpensIt() throws {
        let suite = "mouthtype.vocab.menu.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        let url = directory().appendingPathComponent("dictionary.json")
        var opened: [URL] = []
        let section = CleanupMenuSection(defaults: d, dictionary: FileVocabulary(url: url), openFile: { opened.append($0) })
        let menu = section.items[0].submenu!
        let edit = try #require(menu.items.first { $0.title == "Edit Dictionary\u{2026}" })
        _ = edit.target?.perform(edit.action, with: edit)
        #expect(opened == [url] && FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aBrokenFileShowsAnErrorLineInTheMenu() throws {
        let suite = "mouthtype.vocab.menu.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        let url = directory().appendingPathComponent("dictionary.json")
        try write(#"[{"heard": "a", "written": "A"}]"#, to: url, second: 0)
        let section = CleanupMenuSection(defaults: d, dictionary: FileVocabulary(url: url))
        let menu = section.items[0].submenu!
        let line = try #require(menu.items.first { $0.title.hasPrefix("dictionary.json has an error") })
        #expect(line.isHidden)
        try write("[oops", to: url, second: 9)
        section.refresh()
        #expect(!line.isHidden)
        try write(#"[{"heard": "a", "written": "A"}]"#, to: url, second: 20)
        section.refresh()
        #expect(line.isHidden)
    }

    @Test func theLearnSettingIsAMenuCheckboxThatDefaultsOn() throws {
        let suite = "mouthtype.vocab.menu.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        let section = CleanupMenuSection(defaults: d, dictionary: FileVocabulary(url: directory().appendingPathComponent("dictionary.json")))
        let menu = section.items[0].submenu!
        let item = try #require(menu.items.first { $0.title == "Learn from My Corrections" })
        #expect(item.state == .on && CorrectionSettings.isEnabled(d))
        _ = item.target?.perform(item.action, with: item)
        #expect(item.state == .off && !CorrectionSettings.isEnabled(d) && d.bool(forKey: "learnFromCorrections") == false)
        _ = item.target?.perform(item.action, with: item)
        #expect(item.state == .on)
        let titles = menu.items.map(\.title)
        let learn = try #require(titles.firstIndex(of: "Learn from My Corrections"))
        #expect(abs(learn - (try #require(titles.firstIndex(of: "Edit Dictionary\u{2026}")))) == 1)
    }
}
