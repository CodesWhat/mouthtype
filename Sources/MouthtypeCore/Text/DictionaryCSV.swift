import Foundation

/// What a CSV import produced: the rules, and a message per line that could not be used.
public struct DictionaryCSVImport: Sendable, Equatable {
    public struct LineError: Sendable, Equatable {
        public var line: Int          // 1-based line where the record starts
        public var message: String
    }

    public var rules: [DictionaryRule]
    public var errors: [LineError]
    /// Rows dropped because an earlier row had the same `heard` (ignoring case) and the same `written`.
    public var duplicatesMerged: Int
}

/// Pure CSV importer for dictionary rules. `String` in, rules and per-line errors out.
///
/// Two shapes, which may be mixed in one file:
/// - one column: a term to boost. Becomes a rule with `heard == written`.
/// - two columns: `misspelling,correction`.
///
/// Quoted fields (with `""` for a quote, and embedded commas or newlines), CRLF, a leading BOM, blank lines and
/// a header row (`word`, `term`, `misspelling,correction`, `heard,written`, ...) are all tolerated. Duplicates
/// are merged; a duplicate with a different correction keeps the first and is reported as an error.
public enum DictionaryCSV {
    private static let singleHeaders: Set<String> = ["word", "words", "term", "terms", "phrase", "phrases", "vocabulary"]
    private static let heardHeaders: Set<String> = [
        "misspelling", "misspellings", "heard", "from", "incorrect", "spoken", "wrong", "original", "mishearing",
    ]
    private static let writtenHeaders: Set<String> = [
        "correction", "corrections", "written", "to", "correct", "replacement", "corrected", "right",
    ]

    private struct Record {
        var line: Int
        var fields: [String]
    }

    public static func parse(_ csv: String) -> DictionaryCSVImport {
        var errors: [DictionaryCSVImport.LineError] = []
        let records = tokenize(csv, errors: &errors)

        var rules: [DictionaryRule] = []
        var firstSeen: [String: (index: Int, line: Int)] = [:]
        var merged = 0
        var sawContent = false

        for record in records {
            let fields = record.fields.map { $0.trimmingCharacters(in: .whitespaces) }
            if fields.allSatisfy(\.isEmpty) { continue }
            let isFirstContent = !sawContent
            sawContent = true

            if isFirstContent, isHeader(fields) { continue }

            guard fields.count <= 2 else {
                errors.append(.init(line: record.line, message: "Expected 1 or 2 columns, found \(fields.count)."))
                continue
            }
            let heard = fields[0]
            guard !heard.isEmpty else {
                errors.append(.init(line: record.line, message: "Missing the misspelling (first column is empty)."))
                continue
            }
            let written: String
            if fields.count == 2 {
                guard !fields[1].isEmpty else {
                    errors.append(.init(line: record.line, message: "Missing the correction for \"\(heard)\"."))
                    continue
                }
                written = fields[1]
            } else {
                written = heard
            }

            let key = heard.lowercased()
            if let prior = firstSeen[key] {
                if rules[prior.index].written == written {
                    merged += 1
                } else {
                    errors.append(.init(
                        line: record.line,
                        message: "\"\(heard)\" already maps to \"\(rules[prior.index].written)\" on line \(prior.line); kept that one."
                    ))
                }
                continue
            }
            firstSeen[key] = (rules.count, record.line)
            rules.append(DictionaryRule(heard: heard, written: written))
        }
        return DictionaryCSVImport(rules: rules, errors: errors, duplicatesMerged: merged)
    }

    private static func isHeader(_ fields: [String]) -> Bool {
        let lowered = fields.map { $0.lowercased() }
        if lowered.count == 1 { return singleHeaders.contains(lowered[0]) }
        if lowered.count == 2 { return heardHeaders.contains(lowered[0]) && writtenHeaders.contains(lowered[1]) }
        return false
    }

    /// RFC 4180-style record splitter. Line numbers count physical lines, including ones inside quotes.
    private static func tokenize(_ csv: String, errors: inout [DictionaryCSVImport.LineError]) -> [Record] {
        var records: [Record] = []
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        var fieldWasQuoted = false
        var line = 1
        var recordLine = 1

        func endField() {
            fields.append(field)
            field = ""
            fieldWasQuoted = false
        }
        func endRecord() {
            endField()
            records.append(Record(line: recordLine, fields: fields))
            fields = []
        }

        var chars = Array(csv)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    if c.isNewline { line += 1 }
                    field.append(c)
                }
            } else if c == "\"", field.isEmpty, !fieldWasQuoted {
                inQuotes = true
                fieldWasQuoted = true
            } else if c == "," {
                endField()
            } else if c.isNewline {
                endRecord()
                line += 1
                recordLine = line
            } else {
                field.append(c)
            }
            i += 1
        }
        if inQuotes {
            errors.append(.init(line: recordLine, message: "Unterminated quoted field."))
            return records
        }
        if !field.isEmpty || !fields.isEmpty || fieldWasQuoted { endRecord() }
        return records
    }
}
