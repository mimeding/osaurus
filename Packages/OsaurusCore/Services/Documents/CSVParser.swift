//
//  CSVParser.swift
//  osaurus
//
//  Shared state-machine parser for CSV / TSV content. Consumers:
//    - `CSVAdapter` drains the whole file into `[[String]]`.
//    - `CSVStreamer` feeds bytes in chunks and pulls rows out as they
//      complete — the critical path for large files.
//
//  Grammar (RFC 4180 with the two common extensions noted inline):
//    - Fields are separated by the caller-specified `delimiter`.
//    - Rows are separated by `\r\n`, `\n`, or a bare `\r`.
//    - A field wrapped in `"` may contain delimiters and newlines;
//      a literal `"` inside is escaped as `""`.
//    - A `"` that follows the closing quote (unexpected per RFC) is
//      tolerated: we append it and stay in text mode, matching
//      real-world behaviour of Excel and Numbers exports.
//

import Foundation

enum CSVParser {

    /// One-shot: parse `text` into rows of cell strings. Quoted fields
    /// with embedded newlines collapse into a single cell, so the result
    /// isn't just `text.split(on: "\n")`.
    static func parseAll(text: String, delimiter: Character) -> [[String]] {
        var machine = Machine(delimiter: delimiter)
        for scalar in text.unicodeScalars {
            machine.consume(scalar)
        }
        machine.finish()
        return machine.rows
    }

    /// Incremental variant used by the streamer. Hand it bytes as they
    /// come off the file handle; drain `rows` after each feed and reset.
    struct Machine {
        let delimiter: Character
        private(set) var rows: [[String]] = []
        private var currentRow: [String] = []
        private var currentCell: String = ""
        private var state: State = .fieldStart
        private var pendingCR: Bool = false  // saw `\r`, waiting to see if `\n` follows

        init(delimiter: Character) {
            self.delimiter = delimiter
        }

        mutating func drainRows() -> [[String]] {
            let out = rows
            rows = []
            return out
        }

        mutating func consume(_ scalar: Unicode.Scalar) {
            if pendingCR {
                pendingCR = false
                if scalar == "\n" {
                    // Swallow the `\n` of a CRLF — the `\r` already
                    // terminated the row.
                    return
                }
                // Bare `\r` line ending; fall through so this scalar is
                // reprocessed as the start of the next row.
            }

            let char = Character(scalar)

            switch state {
            case .fieldStart:
                if char == "\"" {
                    state = .inQuotedField
                    return
                }
                if char == delimiter {
                    currentRow.append(currentCell)
                    currentCell = ""
                    return
                }
                if scalar == "\n" {
                    finishRow()
                    return
                }
                if scalar == "\r" {
                    pendingCR = true
                    finishRow()
                    return
                }
                currentCell.append(char)
                state = .inField

            case .inField:
                if char == delimiter {
                    currentRow.append(currentCell)
                    currentCell = ""
                    state = .fieldStart
                    return
                }
                if scalar == "\n" {
                    finishRow()
                    return
                }
                if scalar == "\r" {
                    pendingCR = true
                    finishRow()
                    return
                }
                currentCell.append(char)

            case .inQuotedField:
                if char == "\"" {
                    state = .afterQuote
                    return
                }
                currentCell.append(char)

            case .afterQuote:
                if char == "\"" {
                    // `""` → literal quote in the field.
                    currentCell.append(char)
                    state = .inQuotedField
                    return
                }
                if char == delimiter {
                    currentRow.append(currentCell)
                    currentCell = ""
                    state = .fieldStart
                    return
                }
                if scalar == "\n" {
                    finishRow()
                    return
                }
                if scalar == "\r" {
                    pendingCR = true
                    finishRow()
                    return
                }
                // Tolerate a stray character after a closing quote rather
                // than bailing — Excel-round-tripped CSVs occasionally
                // emit this for fields that started quoted but had the
                // closing quote elided.
                currentCell.append(char)
                state = .inField
            }
        }

        mutating func finish() {
            if state != .fieldStart || !currentCell.isEmpty || !currentRow.isEmpty {
                currentRow.append(currentCell)
                rows.append(currentRow)
                currentCell = ""
                currentRow = []
                state = .fieldStart
            }
        }

        private mutating func finishRow() {
            currentRow.append(currentCell)
            rows.append(currentRow)
            currentCell = ""
            currentRow = []
            state = .fieldStart
        }

        private enum State {
            case fieldStart
            case inField
            case inQuotedField
            case afterQuote
        }
    }
}
