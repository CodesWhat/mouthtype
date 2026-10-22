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
        /// A command by default: a comma is followed by a lowercase word, so clause-end rules can't work. Stays prose
        /// after a noun signal ("the Oxford comma"), before a noun follower ("comma splice"), or right after a verb
        /// that takes it as an object ("add comma").
        case punctuation
        /// A command unless a determiner or adjective right before it makes it a noun ("a question mark").
        case unlessNoun
        /// A list command: see `ListAction` for when each one counts.
        case list
    }

    /// The spoken list commands. All but `.end` and the item separators work anywhere; those only inside a list.
    public enum ListAction: Sendable, Equatable {
        case bullet  // "bullet", "bullet point": needs item text after it
        case newBullet  // "new bullet"
        case numbered  // "numbered list": needs item text after it
        case nextItem  // "next item", "new item": inside a list, needs item text
        case next  // bare "next": inside a list, needs item text, with extra prose guards
        case end  // "end list", "end of list": inside a list
    }

    /// How the symbol sits against its neighbours.
    public enum Attach: Sendable, Equatable {
        case previous  // glued to the word before, space after: , . ? ! : ; …
        case next  // space before, glued to the word after: ( open-quote
        case both  // glued on both sides: - @
        case spaced  // a space on each side: dash, &
        case newline  // replaces the surrounding spaces
    }

    public var words: [String]
    public var output: String
    public var style: Style
    public var attach: Attach
    /// The next word starts a new sentence and gets a capital.
    public var endsSentence: Bool
    public var list: ListAction?

    public init(
        _ words: [String], _ output: String, _ style: Style, _ attach: Attach, endsSentence: Bool = false,
        list: ListAction? = nil
    ) {
        self.list = list
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

        // Lists. The output is a placeholder: the marker depends on the list state when the command is read.
        SpokenCommand(["bullet", "point"], "- ", .list, .newline, endsSentence: true, list: .bullet),
        SpokenCommand(["bullet"], "- ", .list, .newline, endsSentence: true, list: .bullet),
        SpokenCommand(["new", "bullet"], "- ", .list, .newline, endsSentence: true, list: .newBullet),
        SpokenCommand(["numbered", "list"], "1. ", .list, .newline, endsSentence: true, list: .numbered),
        SpokenCommand(["next", "item"], "- ", .list, .newline, endsSentence: true, list: .nextItem),
        SpokenCommand(["new", "item"], "- ", .list, .newline, endsSentence: true, list: .nextItem),
        SpokenCommand(["next"], "- ", .list, .newline, endsSentence: true, list: .next),
        SpokenCommand(["end", "list"], "\n", .list, .newline, endsSentence: true, list: .end),
        SpokenCommand(["end", "of", "list"], "\n", .list, .newline, endsSentence: true, list: .end),

        // Clause-end only: these are common nouns.
        SpokenCommand(["period"], ".", .clauseEnd, .previous, endsSentence: true),
        SpokenCommand(["full", "stop"], ".", .clauseEnd, .previous, endsSentence: true),
        // Commands by default: a comma or colon is followed by a lowercase word more often than not.
        SpokenCommand(["comma"], ",", .punctuation, .previous),
        SpokenCommand(["colon"], ":", .punctuation, .previous),
        SpokenCommand(["semicolon"], ";", .punctuation, .previous),
        SpokenCommand(["semi", "colon"], ";", .punctuation, .previous),

        // Commands unless a noun use is signalled.
        SpokenCommand(["question", "mark"], "?", .unlessNoun, .previous, endsSentence: true),
        SpokenCommand(["exclamation", "point"], "!", .unlessNoun, .previous, endsSentence: true),
        SpokenCommand(["exclamation", "mark"], "!", .unlessNoun, .previous, endsSentence: true),
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

    /// Words right before "new line" or "new paragraph" that make it a noun phrase ("a new line of products").
    public static let layoutNounSignals: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those", "my", "your", "his", "her", "its", "our", "their",
        "another", "each", "every", "any", "some", "no",
    ]

    /// Words right before a bare "next" that make it prose ("what's next", "until next week").
    public static let nextPrepositions: Set<String> = [
        "on", "in", "at", "for", "until", "till", "by", "of", "to", "from", "with", "about", "is", "was", "be",
        "are", "what's", "whats", "here's", "comes", "came", "see", "up",
    ]

    /// Words right after a bare "next" that make it prose ("next week", "next steps").
    public static let nextFollowers: Set<String> = [
        "week", "weekend", "month", "year", "time", "to", "step", "steps", "door", "one", "day", "morning",
        "evening", "few", "up", "quarter", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
        "sunday", "summer", "winter", "spring", "fall", "on", "in", "round", "release", "version",
    ]

    /// Words right after a bare "bullet" that make it a noun ("bullet points are", "bullet train").
    public static let bulletFollowers: Set<String> = [
        "points", "lists", "list", "journal", "train", "proof", "wound", "wounds", "hole", "holes", "casing",
        "casings", "time", "point",
    ]

    /// Words right after "comma", "colon" or "semicolon" that make it a noun phrase ("comma splice", "colon cancer").
    public static let punctuationFollowers: Set<String> = [
        "splice", "splices", "separated", "delimited", "cancer", "cleanse", "cleansing", "polyp", "polyps",
        "surgery", "operator", "placement", "key",
    ]

    /// Verbs right before "comma", "colon" or "semicolon" that take it as an object ("add comma", "remove semicolon").
    public static let punctuationVerbs: Set<String> = [
        "add", "adds", "adding", "put", "puts", "putting", "insert", "inserts", "inserting", "remove", "removes",
        "removing", "use", "uses", "using", "need", "needs", "delete", "deletes", "deleting", "missing", "drop",
        "dropping", "replace", "replacing",
    ]

    /// A determiner, quantifier or adjective directly before a command word means it is being used as a noun.
    public static let nounSignals: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those", "my", "your", "his", "her", "its", "our", "their",
        "another", "each", "every", "any", "some", "no", "such", "which", "what", "per",
        "trial", "grace", "probation", "probationary", "first", "second", "third", "last", "next", "previous",
        "final", "same", "long", "short", "whole", "yard", "mad", "quick", "big", "little",
        "oxford", "serial", "missing", "extra", "trailing", "leading", "inverted", "stray", "dangling", "double",
    ]
}
