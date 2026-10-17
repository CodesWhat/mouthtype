import Foundation

@main struct VerifyPhrases {
    struct Fixture: Decodable {
        let name: String
        let rules: [Snippet]
        let input: String
        let expected: String
        let clipboard: String?
    }
    static func main() throws {
        let fixtures = try JSONDecoder().decode([Fixture].self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        for fixture in fixtures {
            let expander = SnippetExpander(snippets: fixture.rules, now: Date(timeIntervalSince1970: 0),
                clipboard: fixture.clipboard, dateFormatter: { _ in "October 17, 2026" })
            let result = expander.apply(fixture.input).text
            guard Array(result.utf8) == Array(fixture.expected.utf8) else {
                throw NSError(domain: "Phrase fixture: " + fixture.name, code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Expected \(fixture.expected.debugDescription), got \(result.debugDescription)"])
            }
        }
        print("Core SnippetExpander: \(fixtures.count) shared phrase fixtures passed")
    }
}
