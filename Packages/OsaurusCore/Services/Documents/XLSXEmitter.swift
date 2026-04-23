//
//  XLSXEmitter.swift
//  osaurus
//
//  Writes a typed `Workbook` back out to `.xlsx` using libxlsxwriter.
//  Pairs with `XLSXAdapter` to close the read-emit-read round trip that
//  makes Excel a first-class format for osaurus agents: an agent can
//  ingest a workbook, edit a `Workbook` in-process, and emit it back to
//  the user as an attachable artifact.
//
//  Licensing notes, surfaced for whoever owns acknowledgements:
//    - libxlsxwriter itself is BSD-2-Clause.
//    - It vendors `third_party/tmpfileplus/tmpfileplus.c` which is
//      MPL 2.0. Statically linking it is permitted; the MPL only
//      requires that the source of the covered file remain available.
//      A follow-up to `AcknowledgementsView` should list both.
//

import Foundation
import libxlsxwriter

public struct XLSXEmitter: DocumentFormatEmitter {
    public let formatId = "xlsx"

    public init() {}

    public func canEmit(_ document: StructuredDocument) -> Bool {
        document.representation.underlying is Workbook
    }

    public func emit(_ document: StructuredDocument, to url: URL) async throws {
        guard let workbook = document.representation.underlying as? Workbook else {
            throw DocumentAdapterError.writeFailed(
                underlying: "emit called with non-Workbook representation"
            )
        }

        // libxlsxwriter operates on a filename — it writes directly to the
        // destination during `workbook_close` rather than handing back
        // bytes. The caller has already resolved/contained `url` per the
        // emitter contract.
        let workbookHandle: UnsafeMutablePointer<lxw_workbook>? = url.path.withCString {
            workbook_new($0)
        }
        guard let lxwWorkbook = workbookHandle else {
            throw DocumentAdapterError.writeFailed(
                underlying: "workbook_new failed for \(url.path)"
            )
        }

        var pendingError: DocumentAdapterError?

        for sheet in workbook.sheets {
            let sheetHandle: UnsafeMutablePointer<lxw_worksheet>? = sheet.name.withCString {
                workbook_add_worksheet(lxwWorkbook, $0)
            }
            guard let lxwSheet = sheetHandle else {
                pendingError = .writeFailed(
                    underlying: "workbook_add_worksheet failed for '\(sheet.name)'"
                )
                break
            }
            if let err = Self.writeSheet(sheet, to: lxwSheet) {
                pendingError = err
                break
            }
        }

        // `workbook_close` is ALWAYS called, even on earlier errors, so
        // libxlsxwriter can release its buffers and temp files.
        let closeError = workbook_close(lxwWorkbook)
        if pendingError == nil, closeError.rawValue != 0 {
            pendingError = .writeFailed(underlying: "workbook_close error \(closeError.rawValue)")
        }

        if let error = pendingError {
            // Best-effort cleanup — leaving a partial .xlsx behind would
            // masquerade as a successful emit to any later reader.
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    // MARK: - Internals

    private static func writeSheet(
        _ sheet: Sheet,
        to lxwSheet: UnsafeMutablePointer<lxw_worksheet>
    ) -> DocumentAdapterError? {
        for row in sheet.rows {
            for cell in row.cells {
                if let error = writeCell(cell, to: lxwSheet) {
                    return error
                }
            }
        }
        for range in sheet.mergedRanges {
            guard let coords = parseRange(range.reference) else {
                return .writeFailed(underlying: "Bad merge range '\(range.reference)'")
            }
            // Passing a nil string tells libxlsxwriter to preserve whatever
            // was already written at the top-left cell of the range; our
            // top-left cell was emitted by the loop above.
            let err = worksheet_merge_range(
                lxwSheet,
                coords.firstRow,
                coords.firstCol,
                coords.lastRow,
                coords.lastCol,
                nil,
                nil
            )
            if err.rawValue != 0 {
                return .writeFailed(
                    underlying: "worksheet_merge_range \(range.reference) → \(err.rawValue)"
                )
            }
        }
        return nil
    }

    private static func writeCell(
        _ cell: Cell,
        to lxwSheet: UnsafeMutablePointer<lxw_worksheet>
    ) -> DocumentAdapterError? {
        guard let coords = parseA1(cell.reference) else {
            return .writeFailed(underlying: "Bad cell reference '\(cell.reference)'")
        }
        let row = coords.row
        let col = coords.col

        if let formula = cell.formula {
            let err = formula.withCString {
                worksheet_write_formula(lxwSheet, row, col, $0, nil)
            }
            if err.rawValue != 0 {
                return .writeFailed(
                    underlying: "worksheet_write_formula \(cell.reference) → \(err.rawValue)"
                )
            }
            return nil
        }

        switch cell.value {
        case .empty:
            return nil
        case .number(let value):
            let err = worksheet_write_number(lxwSheet, row, col, value, nil)
            if err.rawValue != 0 {
                return .writeFailed(
                    underlying: "worksheet_write_number \(cell.reference) → \(err.rawValue)"
                )
            }
        case .string(let text), .inlineString(let text):
            let err = text.withCString {
                worksheet_write_string(lxwSheet, row, col, $0, nil)
            }
            if err.rawValue != 0 {
                return .writeFailed(
                    underlying: "worksheet_write_string \(cell.reference) → \(err.rawValue)"
                )
            }
        case .bool(let flag):
            let err = worksheet_write_boolean(lxwSheet, row, col, flag ? 1 : 0, nil)
            if err.rawValue != 0 {
                return .writeFailed(
                    underlying: "worksheet_write_boolean \(cell.reference) → \(err.rawValue)"
                )
            }
        }
        return nil
    }

    // MARK: - A1 parsing

    /// Parses an A1-style cell reference ("B3", "AA10") into the 0-indexed
    /// row and column that libxlsxwriter expects. Returns nil for anything
    /// that doesn't match `[A-Z]+[0-9]+`.
    private static func parseA1(_ reference: String) -> (row: UInt32, col: UInt16)? {
        var letters: [UInt8] = []
        var digits: [UInt8] = []
        for scalar in reference.unicodeScalars {
            guard scalar.isASCII, let byte = UInt8(exactly: scalar.value) else { return nil }
            switch byte {
            case 0x41 ... 0x5A:  // A-Z
                letters.append(byte)
            case 0x61 ... 0x7A:  // a-z
                letters.append(byte - 32)
            case 0x30 ... 0x39:  // 0-9
                digits.append(byte)
            default:
                return nil
            }
        }
        guard !letters.isEmpty, !digits.isEmpty else { return nil }

        let rowOneBasedString = String(bytes: digits, encoding: .ascii) ?? ""
        guard let rowOneBased = UInt32(rowOneBasedString), rowOneBased > 0 else { return nil }

        var col: Int = 0
        let base = Int(UInt8(ascii: "A"))
        for byte in letters {
            col = col * 26 + (Int(byte) - base + 1)
        }
        guard col > 0, col <= 16_384 else { return nil }  // Excel col cap

        return (row: rowOneBased - 1, col: UInt16(col - 1))
    }

    /// Parses an A1:A1 range ("A5:B5") into the four 0-indexed coordinates
    /// libxlsxwriter's merge call wants.
    private static func parseRange(
        _ reference: String
    ) -> (firstRow: UInt32, firstCol: UInt16, lastRow: UInt32, lastCol: UInt16)? {
        let parts = reference.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
            let first = parseA1(String(parts[0])),
            let last = parseA1(String(parts[1]))
        else { return nil }
        return (first.row, first.col, last.row, last.col)
    }
}
