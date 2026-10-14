import Testing
@testable import MouthtypeCore

@Suite struct NameJoiningTests {
    @Test func findsOnlyWholePhrasesWhoseLettersMatchAKnownName() {
        let matches = NameJoining.candidates(in: "The dry dock build and sock guard update passed.", spellings: ["Drydock", "Sockguard", "Unrelated"])
        #expect(matches.map(\.heard) == ["dry dock", "sock guard"])
        #expect(matches.map(\.written) == ["Drydock", "Sockguard"])
        #expect(NameJoining.candidates(in: "the dry docking station", spellings: ["Drydock"]).isEmpty)
        #expect(NameJoining.candidates(in: "dry. Dock", spellings: ["Drydock"]).isEmpty)
    }

    @Test func keepsOccurrencesSeparateAndDoesNotGuessNewNames() {
        let matches = NameJoining.candidates(in: "dry dock build, boat in dry dock", spellings: ["Drydock", "Drydock"])
        #expect(matches.count == 2)
        #expect(matches.first?.range != matches.last?.range)
        #expect(NameJoining.candidates(in: "dry dock build", spellings: []).isEmpty)
        #expect(NameJoining.candidates(in: "Drydock build", spellings: ["Drydock"]).isEmpty)
    }

    @Test func aModelDecisionCanOnlyJoinTheSelectedSpan() throws {
        let text = "dry dock build, boat in dry dock"
        let matches = NameJoining.candidates(in: text, spellings: ["Drydock"])
        #expect(NameJoining.applying(Array(matches.prefix(1)), to: text) == "Drydock build, boat in dry dock")
        let first = try #require(matches.first)
        #expect(NameJoining.isProjectReference(first, in: text))
        #expect(!NameJoining.isProjectReference(matches[1], in: text))
    }

    @Test(arguments: ["the boat is in dry dock", "dry dock. Build the fence", "restarted the dry dock", "dry dock"])
    func ordinaryAndAmbiguousPhrasesDoNotSupplyProjectEvidence(text: String) throws {
        let first = try #require(NameJoining.candidates(in: text, spellings: ["Drydock"]).first)
        #expect(!NameJoining.isProjectReference(first, in: text))
    }

    @Test(arguments: ["deploy the dry dock", "dry dock repository", "clone dry dock"])
    func softwareOperationsSupplyProjectEvidence(text: String) throws {
        let first = try #require(NameJoining.candidates(in: text, spellings: ["Drydock"]).first)
        #expect(NameJoining.isProjectReference(first, in: text))
    }
}
