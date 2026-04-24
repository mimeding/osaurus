//
//  Workbook.swift
//  osaurus
//
//  Typed representation for parsed XLSX workbooks. Designed as the
//  round-trip target for both the read side (`XLSXAdapter`, this PR) and
//  the write side (`XLSXEmitter`, landing in the next slice). Fields are
//  chosen to match what CoreXLSX surfaces cleanly today — sheet names,
//  merged ranges, raw cell values, formula source strings — plus the
//  shared-string table so repeated strings round-trip without being
//  re-interned on write. Style-derived fidelity (number formats, column
//  widths) is deliberately out of scope for this PR; see the comment on
//  `CellValue` for why.
//

import Foundation

public struct Workbook: StructuredRepresentation, Sendable {
    public let sheets: [Sheet]
    public let sharedStrings: [String]

    public init(sheets: [Sheet], sharedStrings: [String]) {
        self.sheets = sheets
        self.sharedStrings = sharedStrings
    }
}

public struct Sheet: Sendable {
    public let name: String
    public let rows: [Row]
    public let mergedRanges: [CellRange]

    public init(name: String, rows: [Row], mergedRanges: [CellRange]) {
        self.name = name
        self.rows = rows
        self.mergedRanges = mergedRanges
    }
}

public struct Row: Sendable {
    /// 1-based row number matching the on-wire `r` attribute.
    public let index: Int
    public let cells: [Cell]

    public init(index: Int, cells: [Cell]) {
        self.index = index
        self.cells = cells
    }
}

public struct Cell: Sendable {
    /// A1-style reference on-wire, e.g. "B3".
    public let reference: String
    public let value: CellValue
    /// Formula source (`=SUM(A1:A3)`) when the cell carries one. Excel
    /// stores both the formula and its cached result; we preserve both.
    public let formula: String?

    public init(reference: String, value: CellValue, formula: String? = nil) {
        self.reference = reference
        self.value = value
        self.formula = formula
    }
}

/// Scalar cell payload. Excel dates are stored as numbers with a style
/// attached — without parsing the style table we can't distinguish a date
/// from a plain number, so dates that aren't explicitly typed (`t="d"`)
/// surface as `.number`. Lifting that limitation means shipping a style
/// parser that tolerates the CoreXLSX `patternType` crash on
/// openpyxl-generated files; that work lives in a separate slice.
public enum CellValue: Sendable, Equatable {
    case empty
    case number(Double)
    case string(String)
    case bool(Bool)
    case inlineString(String)
}

/// A1-style cell range, e.g. "A1:C3".
public struct CellRange: Sendable, Equatable {
    public let reference: String

    public init(reference: String) {
        self.reference = reference
    }
}
