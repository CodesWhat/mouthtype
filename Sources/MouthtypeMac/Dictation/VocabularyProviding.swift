import Foundation
import MouthtypeCore

/// Where the cleanup pass gets the user's dictionary and snippets. The dictionary store and its UI plug in here later.
protocol VocabularyProviding: Sendable {
    func dictionary() -> [DictionaryRule]
    func snippets() -> [Snippet]
}

struct EmptyVocabulary: VocabularyProviding {
    func dictionary() -> [DictionaryRule] { [] }
    func snippets() -> [Snippet] { [] }
}
