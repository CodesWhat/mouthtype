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
        #expect(
            vocabulary.dictionary() == [
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

    @Test func removeThenRestorePutsTheExactEntryBackAtItsIndex() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("dictionary.json")
        let long = String(repeating: "x", count: 200)
        try write(
            """
            [
              {"heard":"one","written":"One"},
              {"heard":"two","written":"\(long)","starred":true,"note":{"a":[1,2]}},
              {"heard":"three","written":"Three"}
            ]
            """, to: url)
        let vocabulary = FileVocabulary(url: url)
        let rule = DictionaryRule(heard: "two", written: long, starred: true)
        let removed = try vocabulary.remove(rule)
        #expect(removed.index == 1)
        #expect(try vocabulary.allRules().map(\.heard) == ["one", "three"])
        try vocabulary.restore(removed)
        #expect(try vocabulary.allRules() == [DictionaryRule(heard: "one", written: "One"), rule, DictionaryRule(heard: "three", written: "Three")])
        let entries = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        #expect((entries[1]["note"] as? [String: Any])?["a"] as? [Int] == [1, 2])
    }

    @Test func removeRejectsAChangedRuleAndRestoreRejectsATakenHeardPhrase() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vocabulary = FileVocabulary(url: dir.appendingPathComponent("dictionary.json"))
        try vocabulary.save(heard: "win", written: "Win2")
        #expect(throws: FileVocabulary.WriteError.changed) { try vocabulary.remove(DictionaryRule(heard: "win", written: "Nguyen")) }
        let removed = try vocabulary.remove(DictionaryRule(heard: "win", written: "Win2"))
        try vocabulary.save(heard: "win", written: "Other")
        #expect(throws: FileVocabulary.WriteError.staleUndo) { try vocabulary.restore(removed) }
        #expect(try vocabulary.allRules() == [DictionaryRule(heard: "win", written: "Other")])
    }

    @Test func removeAllWritesOnceOrNotAtAll() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vocabulary = FileVocabulary(url: dir.appendingPathComponent("dictionary.json"))
        try vocabulary.save(heard: "a", written: "Aa")
        try vocabulary.save(heard: "b", written: "Bb")
        try vocabulary.save(heard: "c", written: "Cc")
        let before = try Data(contentsOf: vocabulary.url)
        #expect(throws: FileVocabulary.WriteError.changed) {
            try vocabulary.removeAll([DictionaryRule(heard: "a", written: "Aa"), DictionaryRule(heard: "b", written: "BB")])
        }
        #expect(try Data(contentsOf: vocabulary.url) == before)
        let removed = try vocabulary.removeAll([DictionaryRule(heard: "c", written: "Cc"), DictionaryRule(heard: "a", written: "Aa")])
        #expect(removed.map(\.index) == [0, 2])
        #expect(try vocabulary.allRules() == [DictionaryRule(heard: "b", written: "Bb")])
        try vocabulary.restore(removed)
        #expect(try vocabulary.allRules().map(\.heard) == ["a", "b", "c"])
    }

}
