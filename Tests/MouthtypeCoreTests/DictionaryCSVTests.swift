import Testing
@testable import MouthtypeCore

@Suite struct DictionaryCSVTests {
    private func rule(_ heard: String, _ written: String) -> DictionaryRule {
        DictionaryRule(heard: heard, written: written)
    }

    @Test func singleColumnIsATermToBoost() {
        let r = DictionaryCSV.parse("Mouthtype\nParakeet\n")
        #expect(r.rules == [rule("Mouthtype", "Mouthtype"), rule("Parakeet", "Parakeet")])
        #expect(r.errors.isEmpty)
    }

    @Test func twoColumnsAreMisspellingAndCorrection() {
        let r = DictionaryCSV.parse("mouth type,Mouthtype\npair it,Parakeet\n")
        #expect(r.rules == [rule("mouth type", "Mouthtype"), rule("pair it", "Parakeet")])
        #expect(r.errors.isEmpty)
    }

    @Test func mixedShapesInOneFile() {
        let r = DictionaryCSV.parse("Mouthtype\nmouth type,Mouthtype\n")
        #expect(r.rules.count == 2)
        #expect(r.rules[0] == rule("Mouthtype", "Mouthtype"))
    }

    @Test func quotedFields() {
        let r = DictionaryCSV.parse("\"hello, world\",\"Hello, World\"\n\"say \"\"hi\"\"\",\"Say \"\"Hi\"\"\"\n")
        #expect(r.rules == [rule("hello, world", "Hello, World"), rule("say \"hi\"", "Say \"Hi\"")])
        #expect(r.errors.isEmpty)
    }

    @Test func quotedFieldWithNewlineKeepsLineNumbersHonest() {
        let r = DictionaryCSV.parse("\"two\nlines\",Fixed\nbad,\n")
        #expect(r.rules == [rule("two\nlines", "Fixed")])
        #expect(r.errors == [.init(line: 3, message: "Missing the correction for \"bad\".")])
    }

    @Test func headerRowIsSkipped() {
        #expect(DictionaryCSV.parse("misspelling,correction\nfoo,Foo\n").rules == [rule("foo", "Foo")])
        #expect(DictionaryCSV.parse("Heard,Written\nfoo,Foo\n").rules == [rule("foo", "Foo")])
        #expect(DictionaryCSV.parse("word\nFoo\n").rules == [rule("Foo", "Foo")])
        #expect(DictionaryCSV.parse("Terms\nFoo\n").rules == [rule("Foo", "Foo")])
    }

    @Test func aHeaderWordLaterInTheFileIsData() {
        let r = DictionaryCSV.parse("foo,Foo\nword\n")
        #expect(r.rules == [rule("foo", "Foo"), rule("word", "word")])
    }

    @Test func blankLinesAndCRLFAndBOM() {
        let r = DictionaryCSV.parse("\u{FEFF}a,A\r\n\r\n   \r\nb,B\r\n\n")
        #expect(r.rules == [rule("a", "A"), rule("b", "B")])
        #expect(r.errors.isEmpty)
    }

    @Test func fieldsAreTrimmed() {
        #expect(DictionaryCSV.parse("  foo  ,  Foo  \n").rules == [rule("foo", "Foo")])
    }

    @Test func identicalDuplicatesMerge() {
        let r = DictionaryCSV.parse("foo,Foo\nFOO,Foo\nfoo,Foo\n")
        #expect(r.rules == [rule("foo", "Foo")])
        #expect(r.duplicatesMerged == 2)
        #expect(r.errors.isEmpty)
    }

    @Test func termAndItsExplicitCorrectionMerge() {
        let r = DictionaryCSV.parse("Foo\nfoo,Foo\n")
        #expect(r.rules == [rule("Foo", "Foo")])
        #expect(r.duplicatesMerged == 1)
    }

    @Test func conflictingDuplicateKeepsFirstAndReports() {
        let r = DictionaryCSV.parse("foo,Foo\nfoo,FOO\n")
        #expect(r.rules == [rule("foo", "Foo")])
        #expect(r.errors.count == 1)
        #expect(r.errors[0].line == 2)
    }

    @Test func perLineErrors() {
        let r = DictionaryCSV.parse("ok,Ok\n,Missing\nbad,\na,b,c\nfine,Fine\n")
        #expect(r.rules == [rule("ok", "Ok"), rule("fine", "Fine")])
        #expect(r.errors.map(\.line) == [2, 3, 4])
    }

    @Test func unterminatedQuoteIsReported() {
        let r = DictionaryCSV.parse("ok,Ok\n\"never closed,Oops\n")
        #expect(r.rules == [rule("ok", "Ok")])
        #expect(r.errors == [.init(line: 2, message: "Unterminated quoted field.")])
    }

    @Test func emptyInput() {
        #expect(DictionaryCSV.parse("") == DictionaryCSVImport(rules: [], errors: [], duplicatesMerged: 0))
        #expect(DictionaryCSV.parse("\n\n  \n").rules.isEmpty)
    }

    @Test func unicodeSurvives() {
        let r = DictionaryCSV.parse("café,Café\n東京,Tokyo\n🎉,Party\n")
        #expect(r.rules.count == 3)
        #expect(r.rules[1] == rule("東京", "Tokyo"))
    }

    @Test func importedRulesDriveTheReplacer() {
        let r = DictionaryCSV.parse("mouth type,Mouthtype\nParakeet\n")
        let out = DictionaryReplacer(rules: r.rules).apply("send it to mouth type with parakeet")
        #expect(out.text == "send it to Mouthtype with Parakeet")
    }
}
