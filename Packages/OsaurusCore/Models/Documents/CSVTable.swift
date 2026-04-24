//
//  CSVTable.swift
//  osaurus
//
//  Typed representation for CSV / TSV files. Replaces the flat
//  "CSV-as-text" ingestion the legacy `DocumentParser` did by preserving
//  encoding, delimiter, line-ending style, and per-row cell boundaries.
//  Pairs with `CSVAdapter` (in-memory) and `CSVStreamer` (row-at-a-time).
//
//  High-fidelity fields — the ones that actually matter to business
//  users on round-trip — are deliberate:
//    - `delimiter`: comma / tab / semicolon, honoured on re-emit.
//    - `encoding`: UTF-8 / UTF-16 / ISO-Latin-1, preserved so an export
//      back to the same locale doesn't silently widen the file.
//    - `header`: optional first row, detected by the adapter.
//    - `records`: raw string cells; numeric / date coercion is the
//      caller's job (agents sometimes want the text literal).
//
//  Out of scope: style-level XLSX features (number formats, fills).
//  Those live in the Workbook representation, not here.
//

import Foundation

public struct CSVTable: StructuredRepresentation, Sendable {
    /// Field separator — typically `,` for `.csv` and `\t` for `.tsv`.
    public let delimiter: Character
    /// Byte encoding detected from BOM / heuristic.
    public let encoding: String.Encoding
    /// Line-ending style present in the source bytes. Preserved so a
    /// Windows-authored CSV round-trips as CRLF rather than being
    /// silently rewritten to LF.
    public let lineEnding: LineEnding
    /// First row when the adapter identified it as a header. Heuristic:
    /// present when the source had at least one data row AND the first
    /// row's cells all parse as non-numeric text.
    public let header: [String]?
    /// Parsed cell strings — one `[String]` per row, not including the
    /// header. Quoted-field expansion already applied.
    public let records: [[String]]
    /// Set to the row index where parsing stopped when `sizeLimit` was
    /// hit; `nil` when the whole file fit under the cap.
    public let truncatedAt: Int?

    public init(
        delimiter: Character,
        encoding: String.Encoding,
        lineEnding: LineEnding,
        header: [String]?,
        records: [[String]],
        truncatedAt: Int? = nil
    ) {
        self.delimiter = delimiter
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.header = header
        self.records = records
        self.truncatedAt = truncatedAt
    }

    public enum LineEnding: String, Sendable {
        case lf  // `\n`
        case crlf  // `\r\n`
        case cr  // `\r` — rare, classic Mac
    }
}

/// One streamed row emitted by `CSVStreamer`. `lineNumber` is 1-based and
/// matches the on-wire row number so callers can attribute errors.
public struct CSVRecord: Sendable, Equatable {
    public let lineNumber: Int
    public let cells: [String]

    public init(lineNumber: Int, cells: [String]) {
        self.lineNumber = lineNumber
        self.cells = cells
    }
}
