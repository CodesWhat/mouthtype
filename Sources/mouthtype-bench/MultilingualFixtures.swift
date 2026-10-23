import Foundation

/// One raw transcript as Parakeet v3 writes it, from `Tests/Fixtures/multilingual/<code>.json`.
struct MultilingualEntry: Codable, Sendable, Equatable {
    var id: String
    var language: String
    var raw: String
    var notes: String

    var wordCount: Int { raw.split(whereSeparator: \.isWhitespace).count }
}

enum MultilingualFixtures {
    static let defaultDirectory = "Tests/Fixtures/multilingual"

    /// Every `<code>.json` in the directory, keyed by the language code in the file name.
    static func load(directory: URL) throws -> [String: [MultilingualEntry]] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        var byLanguage: [String: [MultilingualEntry]] = [:]
        for file in files {
            byLanguage[file.deletingPathExtension().lastPathComponent] = try JSONDecoder().decode([MultilingualEntry].self, from: Data(contentsOf: file))
        }
        guard !byLanguage.isEmpty else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "No multilingual fixtures in \(directory.path)"])
        }
        return byLanguage
    }
}
