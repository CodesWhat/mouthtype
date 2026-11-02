import Foundation

@main struct VerifyTone {
    struct Case: Decodable {
        let name: String
        let tone: String
        let input: String
        let protectedWords: [String]?
        let protectedPhrases: [String]?
    }

    static func options(_ tone: String) -> StyleOptions? {
        switch tone {
        case "casual": StylePreset.casual.options
        case "very_casual": StylePreset.veryCasual.options
        default: nil
        }
    }

    /// What the Mac pipeline does for a tone: Formal softens swearing, the others run the style stage.
    static func run(_ item: Case) -> String {
        let protected = Set(item.protectedWords ?? [])
        if let style = options(item.tone) {
            return StyleStage(options: style, protectedWords: protected).apply(item.input).text
        }
        return ProfanityRemover(protectedWords: protected, protectedPhrases: item.protectedPhrases ?? []).apply(item.input).text
    }

    static func main() throws {
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        var observed: [[String: String]] = []
        for item in cases { observed.append(["name": item.name, "output": run(item)]) }
        let data = try JSONSerialization.data(withJSONObject: observed, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
