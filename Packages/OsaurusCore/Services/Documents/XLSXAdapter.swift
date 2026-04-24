//
//  XLSXAdapter.swift
//  osaurus
//
//  First real-fidelity adapter: reads `.xlsx` into a typed `Workbook`
//  rather than flattening it to markdown the way the legacy text path
//  would. Backed by CoreXLSX. The adapter intentionally does NOT call
//  `parseStyles()` — that entry point crashes on openpyxl-generated
//  workbooks because CoreXLSX's `PatternFill.patternType` is non-optional
//  while Excel's default empty pattern omits that attribute. Style-
//  dependent fidelity (number formats, column widths, dates that aren't
//  explicitly typed) is deferred to a follow-up slice so this PR can ship
//  behaviour that works against every current-style XLSX writer.
//

import CoreXLSX
import Foundation

public struct XLSXAdapter: DocumentFormatAdapter {
    public let formatId = "xlsx"

    public init() {}

    public func canHandle(url: URL, uti: String?) -> Bool {
        url.pathExtension.lowercased() == "xlsx"
    }

    public func parse(url: URL, sizeLimit: Int64) async throws -> StructuredDocument {
        let fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        if sizeLimit > 0, fileSize > sizeLimit {
            throw DocumentAdapterError.sizeLimitExceeded(actual: fileSize, limit: sizeLimit)
        }

        let file: XLSXFile
        do {
            guard let opened = XLSXFile(filepath: url.path) else {
                throw DocumentAdapterError.readFailed(underlying: "XLSXFile could not open \(url.path)")
            }
            file = opened
        }

        let sharedStrings: [String]
        do {
            // `parseSharedStrings` is nil on workbooks with no text cells,
            // which is legal for a pure-numeric sheet. Treat that as empty.
            let parsed = try file.parseSharedStrings()
            sharedStrings = parsed?.items.map { $0.text ?? "" } ?? []
        } catch {
            throw DocumentAdapterError.readFailed(underlying: "shared strings: \(error.localizedDescription)")
        }

        let coreWorkbooks: [CoreXLSX.Workbook]
        do {
            coreWorkbooks = try file.parseWorkbooks()
        } catch {
            throw DocumentAdapterError.readFailed(underlying: "workbook index: \(error.localizedDescription)")
        }

        var sheets: [Sheet] = []
        for coreWorkbook in coreWorkbooks {
            let pathsAndNames: [(name: String?, path: String)]
            do {
                pathsAndNames = try file.parseWorksheetPathsAndNames(workbook: coreWorkbook)
            } catch {
                throw DocumentAdapterError.readFailed(underlying: "worksheet index: \(error.localizedDescription)")
            }

            for pair in pathsAndNames {
                let coreSheet: Worksheet
                do {
                    coreSheet = try file.parseWorksheet(at: pair.path)
                } catch {
                    throw DocumentAdapterError.readFailed(
                        underlying: "worksheet \(pair.name ?? pair.path): \(error.localizedDescription)"
                    )
                }
                sheets.append(
                    Self.makeSheet(
                        name: pair.name ?? pair.path,
                        coreSheet: coreSheet,
                        sharedStrings: sharedStrings
                    )
                )
            }
        }

        guard !sheets.isEmpty else {
            throw DocumentAdapterError.emptyContent
        }

        let workbook = Workbook(sheets: sheets, sharedStrings: sharedStrings)
        let textFallback = Self.renderTextFallback(workbook)

        return StructuredDocument(
            formatId: formatId,
            filename: url.lastPathComponent,
            fileSize: fileSize,
            representation: AnyStructuredRepresentation(
                formatId: formatId,
                underlying: workbook
            ),
            textFallback: textFallback
        )
    }

    // MARK: - CoreXLSX → Workbook

    private static func makeSheet(
        name: String,
        coreSheet: Worksheet,
        sharedStrings: [String]
    ) -> Sheet {
        let rows: [Row] = (coreSheet.data?.rows ?? []).map { coreRow in
            let cells: [Cell] = coreRow.cells.map { coreCell in
                Cell(
                    reference: coreCell.reference.description,
                    value: mapCellValue(coreCell, sharedStrings: sharedStrings),
                    formula: coreCell.formula?.value
                )
            }
            return Row(index: Int(coreRow.reference), cells: cells)
        }

        let mergedRanges: [CellRange] = (coreSheet.mergeCells?.items ?? []).map {
            CellRange(reference: $0.reference)
        }

        return Sheet(name: name, rows: rows, mergedRanges: mergedRanges)
    }

    private static func mapCellValue(
        _ coreCell: CoreXLSX.Cell,
        sharedStrings: [String]
    ) -> CellValue {
        // CoreXLSX's `Cell.type` is an optional enum; `Cell.value` is a
        // raw string. The interpretation depends on `type`.
        guard let rawValue = coreCell.value, !rawValue.isEmpty else {
            return .empty
        }

        switch coreCell.type {
        case .bool:
            return .bool(rawValue == "1")
        case .sharedString:
            if let index = Int(rawValue), index >= 0, index < sharedStrings.count {
                return .string(sharedStrings[index])
            }
            return .empty
        case .inlineStr:
            if let inline = coreCell.inlineString {
                // CoreXLSX's `InlineString` concatenates all runs for us.
                return .inlineString(inline.text ?? "")
            }
            return .inlineString(rawValue)
        case .string:
            return .string(rawValue)
        case .number, .none:
            if let number = Double(rawValue) {
                return .number(number)
            }
            return .empty
        case .date:
            // Explicitly-typed dates are rare in the wild — Excel writers
            // almost always store dates as numbers plus a style. Preserve
            // the raw string so callers that know the style table can
            // reconstruct; callers that don't still see a string.
            return .string(rawValue)
        case .error:
            return .string(rawValue)
        }
    }

    // MARK: - Text fallback

    private static func renderTextFallback(_ workbook: Workbook) -> String {
        var out: [String] = []
        for sheet in workbook.sheets {
            out.append("## Sheet: \(sheet.name)")
            for row in sheet.rows {
                let cellText = row.cells.map { describeCell($0) }.joined(separator: "\t")
                out.append("\(row.index)\t\(cellText)")
            }
            if !sheet.mergedRanges.isEmpty {
                let ranges = sheet.mergedRanges.map { $0.reference }.joined(separator: ", ")
                out.append("Merged: \(ranges)")
            }
            out.append("")
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func describeCell(_ cell: Cell) -> String {
        let base: String
        switch cell.value {
        case .empty: base = ""
        case .number(let value):
            base =
                value.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(value))
                : String(value)
        case .string(let text), .inlineString(let text):
            base = text
        case .bool(let flag):
            base = flag ? "TRUE" : "FALSE"
        }
        if let formula = cell.formula {
            return base.isEmpty ? "=\(formula)" : "\(base) [=\(formula)]"
        }
        return base
    }
}
