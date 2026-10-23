import Foundation
import MouthtypeCore

struct SpellingImportPreview {
    struct Row: Identifiable, Equatable {
        enum Status: Equatable {
            case add, existing, duplicate, invalid(String)
            var label: String {
                switch self {
                case .add: "Add"
                case .existing: "Already saved"
                case .duplicate: "Duplicate row"
                case let .invalid(message): message
                }
            }
        }
        let id: Int
        let rule: DictionaryRule
        let status: Status
        var everydayWarning: String? { status == .add ? OrdinaryWords.warning(for: rule) : nil }
    }
    let rows: [Row]
    let problem: String?
    let originalContents: Data?
    var additions: [DictionaryRule] { rows.filter { $0.status == .add }.map(\.rule) }
    var canImport: Bool {
        problem == nil && !additions.isEmpty && !rows.contains { if case .invalid = $0.status { true } else { false } }
    }
}

enum SpellingCSV {
    static let maximumBytes = 1_048_576
    static let maximumRows = 5_000

    struct Record {
        let line: Int
        let fields: [String]
    }

    struct Invalid: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func records(from data: Data) throws -> [Record] {
        guard data.count <= maximumBytes else { throw Invalid(message: "Choose a CSV of 1 MiB or smaller.") }
        guard var text = String(data: data, encoding: .utf8) else { throw Invalid(message: "Save the CSV as UTF-8 text.") }
        if text.first == "\u{feff}" { text.removeFirst() }
        guard !text.contains("\0") else { throw Invalid(message: "The CSV contains an unsupported null character.") }
        enum State { case start, unquoted, quoted, closed }
        var state = State.start
        var records: [Record] = []
        var fields: [String] = []
        var field = ""
        var touched = false
        var line = 1
        var recordLine = 1

        func finishRecord() throws {
            if touched {
                fields.append(field)
                records.append(Record(line: recordLine, fields: fields))
                guard records.count <= maximumRows + 1 else {
                    throw Invalid(message: "Import up to 5,000 spellings at a time.")
                }
            }
            fields = []
            field = ""
            touched = false
            state = .start
        }

        for character in text {
            let newline = character == "\n" || character == "\r" || character == "\r\n"
            if state == .quoted {
                if character == "\"" { state = .closed } else { field.append(character) }
                if newline { line += 1 }
                continue
            }
            if character == "\"" {
                if state == .start {
                    state = .quoted; touched = true
                } else if state == .closed {
                    field.append(character); state = .quoted
                } else {
                    throw Invalid(message: "Row \(line): a quote must start a quoted field.")
                }
            } else if character == "," {
                fields.append(field)
                field = ""
                touched = true
                state = .start
            } else if newline {
                try finishRecord()
                line += 1
                recordLine = line
            } else {
                guard state != .closed else { throw Invalid(message: "Row \(line): unexpected text after a closing quote.") }
                field.append(character)
                touched = true
                state = .unquoted
            }
        }
        guard state != .quoted else { throw Invalid(message: "Row \(recordLine): a quoted field was not closed.") }
        try finishRecord()
        return records
    }
}
