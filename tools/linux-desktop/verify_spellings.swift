import Foundation

// Compile with the real Core PhraseMatcher.swift and TextScan.swift. This checks the
// same committed fixtures against Mac matching without launching the application.
@main
struct VerifySpellings {
    struct Rule: Decodable { let heard: String; let written: String }
    struct Fixture: Decodable {
        let name: String
        let rules: [Rule]
        let input: String
        let expected: String
    }

    static func main() throws {
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        for fixture in fixtures {
            let rules = fixture.rules.filter { !$0.written.isEmpty }
            let matcher = PhraseMatcher(patterns: rules.map(\.heard))
            let chars = Array(fixture.input)
            var result = ""
            var cursor = 0
            for hit in matcher.matches(chars, lower: TextScan.lowered(chars)) {
                result += String(chars[cursor..<hit.range.lowerBound]) + rules[hit.pattern].written
                cursor = hit.range.upperBound
            }
            result += String(chars[cursor...])
            guard Array(result.utf8) == Array(fixture.expected.utf8) else {
                throw NSError(domain: "Spelling fixture: " + fixture.name, code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected \(fixture.expected.debugDescription), got \(result.debugDescription)"])
            }
        }
        print("Mac PhraseMatcher: \(fixtures.count) shared spelling fixtures passed")
        if CommandLine.arguments.count > 2 {
            let data = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
            var count = 0
            var mismatches = 0
            for line in data.split(separator: "\n") {
                let fields = line.split(separator: "#", omittingEmptySubsequences: false)[0].split(whereSeparator: \.isWhitespace)
                if fields.isEmpty { continue }
                var expected: [String] = []
                var current = ""
                for field in fields {
                    if field == "÷" {
                        if !current.isEmpty { expected.append(current); current = "" }
                    } else if field != "×" {
                        current.unicodeScalars.append(UnicodeScalar(UInt32(field, radix: 16)!)!)
                    }
                }
                if Array(expected.joined()).map(String.init) != expected {
                    mismatches += 1
                    print("Mac Character differs from Unicode fixture \(count): \(expected.map { $0.debugDescription })")
                }
                count += 1
            }
            print("Mac Character: \(count) Unicode grapheme fixtures, \(mismatches) differences")
            if mismatches != 0 { exit(2) }
        }
    }
}
