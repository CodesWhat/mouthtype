import Testing
@testable import MouthtypeCore

@Suite struct OrdinaryWordsTests {
    @Test func everydayWordsAreOrdinary() {
        for word in ["win", "the", "a", "I", "could", "Win", "don't", "to be"] {
            #expect(OrdinaryWords.isOrdinary(word), "\(word)")
        }
    }

    @Test func namesAndCoinedWordsAreNot() {
        for word in ["shivon", "praya", "sockguard", "nguyen", "win nguyen", "hove", "jim", "sam", "dan", "S3", "C++", "win32", "c#", "node.js", "e-mail", "a_b", "", "  "] {
            #expect(!OrdinaryWords.isOrdinary(word), "\(word)")
        }
    }

    @Test func warningNamesTheWordAndTheWrittenForm() {
        let text = OrdinaryWords.warning(for: DictionaryRule(heard: "win", written: "Nguyen"))
        #expect(text == "\u{2018}win\u{2019} is an everyday word, so every \u{2018}win\u{2019} you say becomes Nguyen.")
        #expect(OrdinaryWords.warning(for: DictionaryRule(heard: "shivon", written: "Siobhan")) == nil)
    }

    @Test func boostOnlyAndJoinedSpellingsDoNotWarn() {
        #expect(OrdinaryWords.warning(for: DictionaryRule(heard: "will", written: "Will")) == nil)
        #expect(OrdinaryWords.warning(for: DictionaryRule(heard: "mouth type", written: "Mouthtype")) == nil)
    }

    @Test func ordinaryHeardFormsAreNotBoostAliasesButWrittenStillBoosts() {
        let bias = VocabularyBias.collect(from: [
            DictionaryRule(heard: "win", written: "Nguyen"),
            DictionaryRule(heard: "shivon", written: "Siobhan"),
        ])
        #expect(bias.terms == ["Nguyen", "Siobhan"])
        #expect(bias.entries[0].aliases.isEmpty)
        #expect(bias.entries[1].aliases == ["shivon"])
    }

    @Test func commonNameWordsStayOrdinary() {
        for word in ["will", "mark", "bill", "rose"] {
            #expect(OrdinaryWords.isOrdinary(word), "\(word)")
        }
    }

    @Test func starredRuleKeepsItsAliasButStillWarns() {
        let rule = DictionaryRule(heard: "win", written: "Nguyen", starred: true)
        #expect(OrdinaryWords.warning(for: rule) != nil)
        #expect(VocabularyBias.collect(from: [rule]).entries[0].aliases == ["win"])
    }

    @Test func multiWordCopyCallsItAPhrase() {
        let text = OrdinaryWords.warning(for: DictionaryRule(heard: "win win", written: "Nguyen"))
        #expect(text == "\u{2018}win win\u{2019} is an everyday phrase, so every \u{2018}win win\u{2019} you say becomes Nguyen.")
    }
}
