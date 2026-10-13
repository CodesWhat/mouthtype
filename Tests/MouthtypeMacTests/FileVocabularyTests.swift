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
}
