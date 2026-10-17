import Foundation

@main struct VerifyCleanup {
    struct Fixture: Decodable {
        let name: String
        let input: String
        let expected: String
        let coreExpected: String?
        let stage: String?
    }
    static func table() throws {
        let commands: [[String: Any]] = SpokenCommandTable.entries.map { entry in
            ["words": entry.words, "output": entry.output, "style": String(describing: entry.style),
             "attach": String(describing: entry.attach), "endsSentence": entry.endsSentence,
             "list": entry.list.map { String(describing: $0) } as Any? ?? NSNull()]
        }
        let guards: [String: [String]] = [
            "layoutNounSignals": SpokenCommandTable.layoutNounSignals.sorted(),
            "nextPrepositions": SpokenCommandTable.nextPrepositions.sorted(),
            "nextFollowers": SpokenCommandTable.nextFollowers.sorted(),
            "bulletFollowers": SpokenCommandTable.bulletFollowers.sorted(),
            "punctuationFollowers": SpokenCommandTable.punctuationFollowers.sorted(),
            "punctuationVerbs": SpokenCommandTable.punctuationVerbs.sorted(),
            "nounSignals": SpokenCommandTable.nounSignals.sorted(),
        ]
        let data = try JSONSerialization.data(withJSONObject: ["commands": commands, "guards": guards], options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
    static func main() throws {
        if CommandLine.arguments[1] == "table" { try table(); return }
        let fixtures = try JSONDecoder().decode([Fixture].self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        var policyDifferences = 0
        var observed: [[String: String]] = []
        for fixture in fixtures {
            let result: String
            switch fixture.stage {
            case "commands": result = SpokenCommands().apply(fixture.input).text
            case "commandsWhitespace": result = WhitespaceNormalizer().apply(SpokenCommands().apply(fixture.input).text)
            case "whitespace": result = WhitespaceNormalizer().apply(fixture.input)
            default:
                let commands = SpokenCommands().apply(fixture.input).text
                let blended = BlendStage(context: nil).apply(commands).text
                result = WhitespaceNormalizer().apply(blended)
            }
            if CommandLine.arguments.contains("--emit") {
                observed.append(["name": fixture.name, "output": result])
                continue
            }
            let expected = fixture.coreExpected ?? fixture.expected
            if fixture.coreExpected != nil { policyDifferences += 1 }
            guard Array(result.utf8) == Array(expected.utf8) else {
                throw NSError(domain: "Cleanup fixture: " + fixture.name, code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Expected \(expected.debugDescription), got \(result.debugDescription)"])
            }
        }
        if CommandLine.arguments.contains("--emit") {
            let data = try JSONSerialization.data(withJSONObject: observed, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        print("Core formatting: \(fixtures.count) fixture baselines passed; \(policyDifferences) explicit Linux literal-preservation differences recorded")
    }
}
