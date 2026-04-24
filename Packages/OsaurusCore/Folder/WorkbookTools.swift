//
//  WorkbookTools.swift
//  osaurus
//
//  Folder-scoped agent tools for reading and writing XLSX workbooks
//  through the typed `Workbook` surface. Installed by
//  `FolderToolFactory.buildCoreTools` when a working folder is active.
//
//  These tools let an agent ingest a spreadsheet, reason about cells and
//  formulas in their native types, and emit a modified workbook without
//  ever dropping to markdown-as-text serialisation. They pair with
//  `XLSXAdapter` (read) and `XLSXEmitter` (write) via
//  `DocumentFormatRegistry`.
//
//  Path resolution matches `FileReadTool` / `FileWriteTool` — paths are
//  contained under `rootPath` and `..`-traversal is rejected.
//

import Foundation

// MARK: - read_workbook

struct ReadWorkbookTool: OsaurusTool {
    let name = "read_workbook"
    let description =
        "Read an XLSX spreadsheet into a structured summary. Returns sheet "
        + "names, row counts, merged ranges, and a truncated cell sample per "
        + "sheet so the response stays in-context. For a specific cell's value "
        + "or formula use `read_workbook_cell`. To write a modified workbook, "
        + "use `write_workbook`."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string("Relative path to an .xlsx file under the working folder."),
            ])
        ]),
        "required": .array([.string("path")]),
    ])

    private let rootPath: URL

    /// Cap on cells returned per sheet. Agents that need more should
    /// switch to `read_workbook_cell` for the specific reference.
    private static let maxCellsPerSheet = 200

    init(rootPath: URL) {
        self.rootPath = rootPath
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let pathReq = requireString(args, "path", expected: "relative path to an .xlsx file", tool: name)
        guard case .value(let relativePath) = pathReq else { return pathReq.failureEnvelope ?? "" }

        let fileURL: URL
        do {
            fileURL = try FolderToolHelpers.resolvePath(relativePath, rootPath: rootPath)
        } catch {
            return ToolEnvelope.failure(kind: .invalidArgs, message: error.localizedDescription, tool: name)
        }

        let workbook: Workbook
        do {
            let document = try await XLSXAdapter().parse(
                url: fileURL,
                sizeLimit: DocumentLimits.limit(forFormatId: "xlsx")
            )
            guard let wb = document.representation.underlying as? Workbook else {
                return ToolEnvelope.failure(
                    kind: .executionError,
                    message: "XLSX adapter returned unexpected representation.",
                    tool: name
                )
            }
            workbook = wb
        } catch {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Failed to read workbook: \(error.localizedDescription)",
                tool: name
            )
        }

        let payload = renderSummary(path: relativePath, workbook: workbook)
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Could not serialise workbook summary.",
                tool: name
            )
        }
        return ToolEnvelope.success(tool: name, text: text)
    }

    // MARK: - Summary rendering

    private func renderSummary(path: String, workbook: Workbook) -> [String: Any] {
        let sheets: [[String: Any]] = workbook.sheets.map { sheet in
            let allCells = sheet.rows.flatMap { row in
                row.cells.map { cell in renderCell(row: row.index, cell: cell) }
            }
            let truncated = allCells.prefix(Self.maxCellsPerSheet).map { $0 }
            var sheetPayload: [String: Any] = [
                "name": sheet.name,
                "rowCount": sheet.rows.count,
                "cellCount": allCells.count,
                "cells": truncated,
            ]
            if allCells.count > truncated.count {
                sheetPayload["truncated"] = true
            }
            if !sheet.mergedRanges.isEmpty {
                sheetPayload["mergedRanges"] = sheet.mergedRanges.map { $0.reference }
            }
            return sheetPayload
        }
        return [
            "path": path,
            "sheets": sheets,
        ]
    }

    private func renderCell(row: Int, cell: Cell) -> [String: Any] {
        var payload: [String: Any] = ["ref": cell.reference, "row": row]
        switch cell.value {
        case .empty:
            payload["type"] = "empty"
        case .number(let value):
            payload["type"] = "number"
            payload["value"] = value
        case .string(let text):
            payload["type"] = "string"
            payload["value"] = text
        case .inlineString(let text):
            payload["type"] = "inlineString"
            payload["value"] = text
        case .bool(let flag):
            payload["type"] = "bool"
            payload["value"] = flag
        }
        if let formula = cell.formula {
            payload["formula"] = formula
        }
        return payload
    }
}

// MARK: - read_workbook_cell

struct ReadWorkbookCellTool: OsaurusTool {
    let name = "read_workbook_cell"
    let description =
        "Read a single cell from an XLSX spreadsheet. Returns value, formula, "
        + "and type for the referenced cell. Use after `read_workbook` has "
        + "shown the structure and you need a specific value that was "
        + "truncated out of the summary."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string("Relative path to an .xlsx file under the working folder."),
            ]),
            "sheet": .object([
                "type": .string("string"),
                "description": .string("Sheet name, e.g. `Revenue`."),
            ]),
            "cell": .object([
                "type": .string("string"),
                "description": .string("A1-style cell reference, e.g. `B3` or `AA10`."),
            ]),
        ]),
        "required": .array([.string("path"), .string("sheet"), .string("cell")]),
    ])

    private let rootPath: URL

    init(rootPath: URL) {
        self.rootPath = rootPath
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let pathReq = requireString(args, "path", expected: "relative path to an .xlsx file", tool: name)
        guard case .value(let relativePath) = pathReq else { return pathReq.failureEnvelope ?? "" }
        let sheetReq = requireString(args, "sheet", expected: "sheet name", tool: name)
        guard case .value(let sheetName) = sheetReq else { return sheetReq.failureEnvelope ?? "" }
        let cellReq = requireString(args, "cell", expected: "A1-style cell reference", tool: name)
        guard case .value(let cellRef) = cellReq else { return cellReq.failureEnvelope ?? "" }

        let fileURL: URL
        do {
            fileURL = try FolderToolHelpers.resolvePath(relativePath, rootPath: rootPath)
        } catch {
            return ToolEnvelope.failure(kind: .invalidArgs, message: error.localizedDescription, tool: name)
        }

        let workbook: Workbook
        do {
            let document = try await XLSXAdapter().parse(
                url: fileURL,
                sizeLimit: DocumentLimits.limit(forFormatId: "xlsx")
            )
            guard let wb = document.representation.underlying as? Workbook else {
                return ToolEnvelope.failure(
                    kind: .executionError,
                    message: "XLSX adapter returned unexpected representation.",
                    tool: name
                )
            }
            workbook = wb
        } catch {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Failed to read workbook: \(error.localizedDescription)",
                tool: name
            )
        }

        guard let sheet = workbook.sheets.first(where: { $0.name == sheetName }) else {
            let available = workbook.sheets.map(\.name).joined(separator: ", ")
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "Sheet '\(sheetName)' not found. Available sheets: \(available).",
                field: "sheet",
                expected: "an existing sheet name",
                tool: name
            )
        }
        guard let cell = sheet.rows.flatMap(\.cells).first(where: { $0.reference == cellRef }) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Cell '\(cellRef)' not found on sheet '\(sheetName)'.",
                field: "cell",
                expected: "an occupied cell on the sheet",
                tool: name
            )
        }

        var payload: [String: Any] = ["ref": cell.reference]
        switch cell.value {
        case .empty: payload["type"] = "empty"
        case .number(let v): payload["type"] = "number"; payload["value"] = v
        case .string(let v): payload["type"] = "string"; payload["value"] = v
        case .inlineString(let v): payload["type"] = "inlineString"; payload["value"] = v
        case .bool(let v): payload["type"] = "bool"; payload["value"] = v
        }
        if let formula = cell.formula { payload["formula"] = formula }

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Could not serialise cell payload.",
                tool: name
            )
        }
        return ToolEnvelope.success(tool: name, text: text)
    }
}

// MARK: - write_workbook

struct WriteWorkbookTool: OsaurusTool {
    let name = "write_workbook"
    let description =
        "Write an XLSX spreadsheet to disk. Accepts a structured `sheets` "
        + "array so the model never has to format raw XML. Each cell carries "
        + "its A1 reference, a typed value, and an optional formula. "
        + "Call `share_artifact` afterwards if you want the file to appear in "
        + "the chat thread."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string("Relative output path, e.g. `report.xlsx`."),
            ]),
            "sheets": .object([
                "type": .string("array"),
                "description": .string("One or more sheets in display order."),
                "items": .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "required": .array([.string("name")]),
                    "properties": .object([
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Sheet display name."),
                        ]),
                        "cells": .object([
                            "type": .string("array"),
                            "description": .string(
                                "Cells to write. Omit to create an empty sheet."
                            ),
                            "items": .object([
                                "type": .string("object"),
                                "additionalProperties": .bool(false),
                                "required": .array([.string("ref")]),
                                "properties": .object([
                                    "ref": .object([
                                        "type": .string("string"),
                                        "description": .string("A1 reference, e.g. `B3`."),
                                    ]),
                                    "type": .object([
                                        "type": .string("string"),
                                        "description": .string(
                                            "`string`, `number`, `bool`, or `formula`."
                                        ),
                                        "enum": .array([
                                            .string("string"),
                                            .string("number"),
                                            .string("bool"),
                                            .string("formula"),
                                        ]),
                                    ]),
                                    "value": .object([
                                        "description": .string(
                                            "Cell value — string/number/bool. Ignored for `formula` cells; use `formula` instead."
                                        )
                                    ]),
                                    "formula": .object([
                                        "type": .string("string"),
                                        "description": .string(
                                            "Formula source without the leading `=`, e.g. `SUM(A1:A3)`."
                                        ),
                                    ]),
                                ]),
                            ]),
                        ]),
                        "mergedRanges": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Optional A1:A1 merge ranges, e.g. `A1:B1`."),
                        ]),
                    ]),
                ]),
            ]),
        ]),
        "required": .array([.string("path"), .string("sheets")]),
    ])

    private let rootPath: URL

    init(rootPath: URL) {
        self.rootPath = rootPath
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let pathReq = requireString(args, "path", expected: "relative output path ending in .xlsx", tool: name)
        guard case .value(let relativePath) = pathReq else { return pathReq.failureEnvelope ?? "" }

        guard let rawSheets = args["sheets"] as? [[String: Any]], !rawSheets.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`sheets` must be a non-empty array of sheet objects.",
                field: "sheets",
                expected: "non-empty array",
                tool: name
            )
        }

        let destURL: URL
        do {
            destURL = try FolderToolHelpers.resolvePath(relativePath, rootPath: rootPath)
        } catch {
            return ToolEnvelope.failure(kind: .invalidArgs, message: error.localizedDescription, tool: name)
        }

        guard destURL.pathExtension.lowercased() == "xlsx" else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`path` must end in `.xlsx`; got '\(relativePath)'.",
                field: "path",
                expected: ".xlsx file path",
                tool: name
            )
        }

        var sheets: [Sheet] = []
        for (index, raw) in rawSheets.enumerated() {
            switch parseSheet(raw, at: index) {
            case .value(let sheet): sheets.append(sheet)
            case .failure(let envelope): return envelope
            }
        }

        let workbook = Workbook(sheets: sheets, sharedStrings: [])
        let document = StructuredDocument(
            formatId: "xlsx",
            filename: destURL.lastPathComponent,
            fileSize: 0,
            representation: AnyStructuredRepresentation(formatId: "xlsx", underlying: workbook),
            textFallback: ""
        )

        // Ensure parent exists so relative writes like `reports/q4.xlsx`
        // work without a separate `dir_create` round-trip.
        try? FileManager.default.createDirectory(
            at: destURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        do {
            try await XLSXEmitter().emit(document, to: destURL)
        } catch {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Failed to write workbook: \(error.localizedDescription)",
                tool: name
            )
        }

        let payload: [String: Any] = [
            "path": relativePath,
            "sheetCount": sheets.count,
            "totalCells": sheets.reduce(0) { $0 + $1.rows.flatMap(\.cells).count },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            return ToolEnvelope.success(tool: name, text: "Wrote workbook to \(relativePath)")
        }
        return ToolEnvelope.success(tool: name, text: text)
    }

    // MARK: - Parsing

    private func parseSheet(
        _ raw: [String: Any],
        at index: Int
    ) -> ArgumentRequirement<Sheet> {
        guard let sheetName = raw["name"] as? String, !sheetName.isEmpty else {
            return .failure(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "Sheet at index \(index) is missing a non-empty `name`.",
                    field: "sheets[\(index)].name",
                    expected: "non-empty string",
                    tool: name
                )
            )
        }

        let rawCells = raw["cells"] as? [[String: Any]] ?? []
        var cellsByRow: [Int: [Cell]] = [:]
        for (cellIndex, rawCell) in rawCells.enumerated() {
            switch parseCell(rawCell, sheetIndex: index, cellIndex: cellIndex) {
            case .value(let (row, cell)):
                cellsByRow[row, default: []].append(cell)
            case .failure(let envelope): return .failure(envelope)
            }
        }
        let rows = cellsByRow.keys.sorted().map { rowIndex in
            Row(index: rowIndex, cells: cellsByRow[rowIndex] ?? [])
        }

        let mergedRanges: [CellRange] =
            (raw["mergedRanges"] as? [String])?
            .map { CellRange(reference: $0) } ?? []

        return .value(Sheet(name: sheetName, rows: rows, mergedRanges: mergedRanges))
    }

    private func parseCell(
        _ raw: [String: Any],
        sheetIndex: Int,
        cellIndex: Int
    ) -> ArgumentRequirement<(Int, Cell)> {
        guard let ref = raw["ref"] as? String, !ref.isEmpty else {
            return .failure(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "Cell \(cellIndex) on sheet \(sheetIndex) is missing `ref`.",
                    field: "sheets[\(sheetIndex)].cells[\(cellIndex)].ref",
                    expected: "A1-style reference",
                    tool: name
                )
            )
        }
        guard let rowOneBased = rowComponent(of: ref) else {
            return .failure(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "Cell reference '\(ref)' is not valid A1.",
                    field: "sheets[\(sheetIndex)].cells[\(cellIndex)].ref",
                    expected: "A1-style reference",
                    tool: name
                )
            )
        }

        let typeHint = (raw["type"] as? String)?.lowercased()
        let value: CellValue
        var formula: String?
        switch typeHint {
        case "formula":
            guard let f = raw["formula"] as? String, !f.isEmpty else {
                return .failure(
                    ToolEnvelope.failure(
                        kind: .invalidArgs,
                        message: "Cell '\(ref)' is typed as `formula` but has no `formula` string.",
                        field: "sheets[\(sheetIndex)].cells[\(cellIndex)].formula",
                        expected: "non-empty formula string",
                        tool: name
                    )
                )
            }
            formula = f
            value = .empty
        case "bool":
            value = .bool((raw["value"] as? Bool) ?? false)
        case "number":
            if let n = raw["value"] as? Double {
                value = .number(n)
            } else if let n = (raw["value"] as? NSNumber)?.doubleValue {
                value = .number(n)
            } else if let s = raw["value"] as? String, let n = Double(s) {
                value = .number(n)
            } else {
                value = .empty
            }
        case "string", nil:
            if let s = raw["value"] as? String {
                value = .string(s)
            } else if let n = raw["value"] as? NSNumber {
                value = .number(n.doubleValue)
            } else if let b = raw["value"] as? Bool {
                value = .bool(b)
            } else if raw["formula"] is String {
                formula = raw["formula"] as? String
                value = .empty
            } else {
                value = .empty
            }
        default:
            return .failure(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "Cell '\(ref)' has unknown type '\(typeHint ?? "?")'.",
                    field: "sheets[\(sheetIndex)].cells[\(cellIndex)].type",
                    expected: "string / number / bool / formula",
                    tool: name
                )
            )
        }
        return .value((rowOneBased, Cell(reference: ref, value: value, formula: formula)))
    }

    private func rowComponent(of reference: String) -> Int? {
        var digits = ""
        for ch in reference.unicodeScalars where ch.value >= 0x30 && ch.value <= 0x39 {
            digits.append(Character(ch))
        }
        return Int(digits)
    }
}
