//
//  PDFDocumentRepresentation.swift
//  osaurus
//
//  Typed representation for parsed PDFs. Replaces the `PlainTextRepresentation`
//  that PR 3's PDFAdapter emitted — PDFs that look tabular (invoices, bank
//  statements, periodic reports) now surface the table structure alongside
//  the flat text fallback, while narrative PDFs keep working exactly as
//  before.
//
//  Table detection lives in `PDFAdapter` and is intentionally permissive:
//  a "table" here is a run of consecutive text rows that the layout
//  heuristic split into at least two cells each. It won't perfectly match
//  the author's semantic intent in every document — but for the files
//  osaurus users actually attach (invoices, bank statements, financial
//  tables), the heuristic is good enough to turn numeric columns from
//  `1,234.56 1,920.00 ...` concatenation into proper cells.
//

import Foundation

public struct PDFDocumentRepresentation: StructuredRepresentation, Sendable {
    public let pages: [PDFPageRepresentation]

    public var pageCount: Int { pages.count }

    public init(pages: [PDFPageRepresentation]) {
        self.pages = pages
    }
}

public struct PDFPageRepresentation: Sendable {
    /// 1-indexed page number matching the PDF's own display numbering.
    public let pageNumber: Int
    /// Plain text extracted via PDFKit. Kept on every page so the text
    /// fallback path stays byte-identical to the legacy behaviour even
    /// when no tables are detected.
    public let text: String
    /// Tables detected on this page. Empty for flowing-text pages.
    /// A single page can carry multiple tables (e.g. an invoice with
    /// line items + a summary block underneath).
    public let tables: [PDFTable]

    public init(pageNumber: Int, text: String, tables: [PDFTable]) {
        self.pageNumber = pageNumber
        self.text = text
        self.tables = tables
    }
}

/// Simple tabular region: an ordered list of rows, each with typed cell
/// strings. Coordinates are not retained because they're author-specific
/// and would force every downstream consumer to understand PDF geometry.
public struct PDFTable: Sendable, Equatable {
    public let rows: [[String]]

    public init(rows: [[String]]) {
        self.rows = rows
    }

    public var rowCount: Int { rows.count }
    public var columnCount: Int { rows.map(\.count).max() ?? 0 }
}
