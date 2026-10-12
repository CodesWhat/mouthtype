import Foundation

/// One spoken command. The whole table lives in `SpokenCommandTable.entries` so it can grow in one place.
public struct SpokenCommand: Sendable, Equatable {
    /// When the phrase counts as a command rather than ordinary speech.
    public enum Style: Sendable, Equatable {
        /// Always a command ("new line").
        case layout
        /// Only at the end of a clause: followed by end of text, a newline, punctuation Parakeet already
        /// inserted, a capitalised word, or another command. Ordinary nouns ("period", "colon") live here.
        case clauseEnd
        /// A command unless a determiner or adjective right before it makes it a noun ("a question mark").
        case unlessNoun
    }

    /// How the symbol sits against its neighbours.
    public enum Attach: Sendable, Equatable {
        case previous      // glued to the word before, space after: , . ? ! : ; …
        case next          // space before, glued to the word after: ( open-quote
        case both          // glued on both sides: - @
        case spaced        // a space on each side: dash, &
        case newline       // replaces the surrounding spaces
    }

    public var words: [String]
    public var output: String
    public var style: Style
    public var attach: Attach
    /// The next word starts a new sentence and gets a capital.
    public var endsSentence: Bool

    public init(_ words: [String], _ output: String, _ style: Style, _ attach: Attach, endsSentence: Bool = false) {
        self.words = words
        self.output = output
        self.style = style
        self.attach = attach
        self.endsSentence = endsSentence
    }
}

public enum SpokenCommandTable {
    public static let entries: [SpokenCommand] = [
        // Layout: always commands.
        SpokenCommand(["new", "paragraph"], "\n\n", .layout, .newline, endsSentence: true),
        SpokenCommand(["new", "line"], "\n", .layout, .newline, endsSentence: true),
        SpokenCommand(["newline"], "\n", .layout, .newline, endsSentence: true),

        // Clause-end only: these are common nouns.
        SpokenCommand(["period"], ".", .clauseEnd, .previous, endsSentence: true),
        SpokenCommand(["full", "stop"], ".", .clauseEnd, .previous, endsSentence: true),
        SpokenCommand(["comma"], ",", .clauseEnd, .previous),
        SpokenCommand(["colon"], ":", .clauseEnd, .previous),

        // Commands unless a noun use is signalled.
        SpokenCommand(["question", "mark"], "?", .unlessNoun, .previous, endsSentence: true),
        SpokenCommand(["exclamation", "point"], "!", .unlessNoun, .previous, endsSentence: true),
        SpokenCommand(["exclamation", "mark"], "!", .unlessNoun, .previous, endsSentence: true),
        SpokenCommand(["semicolon"], ";", .unlessNoun, .previous),
        SpokenCommand(["semi", "colon"], ";", .unlessNoun, .previous),
        SpokenCommand(["ellipsis"], "\u{2026}", .unlessNoun, .previous),
        SpokenCommand(["dot", "dot", "dot"], "\u{2026}", .unlessNoun, .previous),
        SpokenCommand(["dash"], " - ", .unlessNoun, .spaced),
        SpokenCommand(["hyphen"], "-", .unlessNoun, .both),
        SpokenCommand(["at", "sign"], "@", .unlessNoun, .both),
        SpokenCommand(["ampersand"], " & ", .unlessNoun, .spaced),
        SpokenCommand(["open", "paren"], "(", .unlessNoun, .next),
        SpokenCommand(["open", "parenthesis"], "(", .unlessNoun, .next),
        SpokenCommand(["close", "paren"], ")", .unlessNoun, .previous),
        SpokenCommand(["close", "parenthesis"], ")", .unlessNoun, .previous),
        SpokenCommand(["open", "quote"], "\"", .unlessNoun, .next),
        SpokenCommand(["close", "quote"], "\"", .unlessNoun, .previous),
        SpokenCommand(["end", "quote"], "\"", .unlessNoun, .previous),
    ]

    /// A determiner, quantifier or adjective directly before a command word means it is being used as a noun.
    public static let nounSignals: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those", "my", "your", "his", "her", "its", "our", "their",
        "another", "each", "every", "any", "some", "no", "such", "which", "what", "per",
        "trial", "grace", "probation", "probationary", "first", "second", "third", "last", "next", "previous",
        "final", "same", "long", "short", "whole", "yard", "mad", "quick", "big", "little",
    ]
}
