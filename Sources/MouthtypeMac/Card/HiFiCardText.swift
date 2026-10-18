import Foundation

/// The Hi-Fi card's text: made fit for the 5x7 face, and wrapped into lines that never cut a word short with an
/// ellipsis. Display only. The card's actions keep the original text.
enum HiFiCardText {
    enum Style: Equatable, Sendable { case normal, emphasis, detail }

    struct Run: Equatable, Sendable {
        var text: String
        var style: Style
    }

    typealias Line = [Run]

    private static let swaps: [Character: String] = [
        "\u{2018}": "'", "\u{2019}": "'", "\u{201C}": "\"", "\u{201D}": "\"", "\u{2013}": "-", "\u{2014}": "-",
        "\u{2026}": "...", "\u{2192}": "->", "\u{00A0}": " ", "\t": " ",
    ]

    /// Typographic marks reduced to the face's ASCII, diacritics folded, caps, and `?` for what the face can't draw.
    static func display(_ text: String, metrics: BitmapFont.Metrics) -> String {
        let known = Set(metrics.chars)
        var swapped = ""
        for character in text { swapped += swaps[character] ?? String(character) }
        let folded = swapped.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil).uppercased()
        return String(folded.map { known.contains($0) || $0 == "\n" ? $0 : "?" })
    }

    private struct Cell {
        var character: Character
        var style: Style
    }

    /// Greedy word wrap at `maxWidth` art pixels. Newlines break lines, runs of spaces collapse to one at a wrap,
    /// and a word wider than a line splits across lines. Text is expected to be `display` text already.
    static func wrap(_ pieces: [(text: String, style: Style)], metrics: BitmapFont.Metrics, maxWidth: Int) -> [Line] {
        var paragraphs: [[Cell]] = [[]]
        for piece in pieces {
            for character in piece.text {
                if character == "\n" { paragraphs.append([]) } else { paragraphs[paragraphs.count - 1].append(Cell(character: character, style: piece.style)) }
            }
        }
        func width(_ cells: [Cell]) -> Int { metrics.width(of: String(cells.map(\.character))) }
        var lines: [[Cell]] = []
        for paragraph in paragraphs {
            var words: [[Cell]] = []
            var word: [Cell] = []
            for cell in paragraph {
                if cell.character == " " {
                    if !word.isEmpty { words.append(word); word = [] }
                } else {
                    word.append(cell)
                }
            }
            if !word.isEmpty { words.append(word) }
            if words.isEmpty { lines.append([]); continue }
            var line: [Cell] = []
            for var word in words {
                while width(word) > maxWidth && word.count > 1 {
                    if !line.isEmpty { lines.append(line); line = [] }
                    var count = 1
                    while count < word.count && width(Array(word[0...count])) <= maxWidth { count += 1 }
                    lines.append(Array(word[0..<count]))
                    word = Array(word[count...])
                }
                let candidate = line.isEmpty ? word : line + [Cell(character: " ", style: word[0].style)] + word
                if width(candidate) <= maxWidth {
                    line = candidate
                } else {
                    if !line.isEmpty { lines.append(line) }
                    line = word
                }
            }
            if !line.isEmpty { lines.append(line) }
        }
        return lines.map { cells in
            var runs: Line = []
            for cell in cells {
                if let last = runs.last, last.style == cell.style {
                    runs[runs.count - 1].text.append(cell.character)
                } else {
                    runs.append(Run(text: String(cell.character), style: cell.style))
                }
            }
            return runs
        }
    }

    static func text(of line: Line) -> String { line.map(\.text).joined() }
}
