import Foundation

enum PasteChunks {
    static let byteLimit = 1_024
    static func parts(_ text: String) -> [String]? {
        guard text.utf8.count > byteLimit else { return [text] }
        var parts: [String] = []
        var part = ""
        var bytes = 0
        for character in text {
            let size = character.utf8.count
            guard size <= byteLimit else { return nil }
            if bytes + size > byteLimit {
                parts.append(part)
                part = ""
                bytes = 0
            }
            part.append(character)
            bytes += size
        }
        if !part.isEmpty { parts.append(part) }
        return parts
    }
}
