//
//  WorkbookTools.swift
//  osaurus
//
//  Folder-context tools for reading and writing the conservative Workbook
//  representation carried by the document adapter stack. The tools route
//  through DocumentFormatRegistry so XLSX support stays behind the same
//  adapter/emitter seam as attachment ingestion and artifact emission.
//

import Foundation

struct ReadWorkbookTool: OsaurusTool {
    let name = "read_workbook"
    let description =
        "Read an XLSX workbook in the working directory and return structured sheets, rows, and cells."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string("Relative path to the workbook from the working directory"),
            ]),
            "sheet_name": .object([
                "type": .string("string"),
                "description": .string("Optional exact worksheet name to read"),
            ]),
            "max_rows": .object([
                "type": .string("integer"),
                "description": .string("Maximum rows per sheet to return (default: 100)"),
            ]),
            "max_columns": .object([
                "type": .string("integer"),
                "description": .string("Maximum cells per row to return (default: 50)"),
            ]),
        ]),
        "required": .array([.string("path")]),
    ])

    private let rootPath: URL
    private let registry: DocumentFormatRegistry

    init(rootPath: URL, registry: DocumentFormatRegistry = .shared) {
        self.rootPath = rootPath
        self.registry = registry
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let pathReq = requireString(
            args,
            "path",
            expected: "relative path to an .xlsx workbook under the working folder",
            tool: name
        )
        guard case .value(let relativePath) = pathReq else {
            return pathReq.failureEnvelope ?? ""
        }

        let sheetReq = optionalString(
            args,
            "sheet_name",
            expected: "exact worksheet name",
            tool: name
        )
        guard case .value(let sheetName) = sheetReq else { return sheetReq.failureEnvelope ?? "" }

        let maxRows = max(1, coerceInt(args["max_rows"]) ?? 100)
        let maxColumns = max(1, coerceInt(args["max_columns"]) ?? 50)
        let workbookDocument = try await WorkbookToolSupport.loadWorkbook(
            relativePath: relativePath,
            rootPath: rootPath,
            registry: registry
        )
        let sheets = try WorkbookToolSupport.selectedSheets(
            in: workbookDocument.workbook,
            sheetName: sheetName,
            toolName: name
        )

        return ToolEnvelope.success(
            tool: name,
            result: [
                "path": relativePath,
                "format_id": workbookDocument.document.formatId,
                "filename": workbookDocument.document.filename,
                "sheet_count": workbookDocument.workbook.sheets.count,
                "sheets": sheets.map {
                    WorkbookToolSupport.sheetPayload(
                        $0,
                        maxRows: maxRows,
                        maxColumns: maxColumns
                    )
                },
            ]
        )
    }
}

struct ReadWorkbookCellTool: OsaurusTool {
    let name = "read_workbook_cell"
    let description =
        "Read one cell from an XLSX workbook in the working directory. Defaults to the first sheet when sheet_name is omitted."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string("Relative path to the workbook from the working directory"),
            ]),
            "cell": .object([
                "type": .string("string"),
                "description": .string("A1 cell reference, e.g. B2"),
            ]),
            "sheet_name": .object([
                "type": .string("string"),
                "description": .string("Optional exact worksheet name; defaults to the first sheet"),
            ]),
        ]),
        "required": .array([.string("path"), .string("cell")]),
    ])

    private let rootPath: URL
    private let registry: DocumentFormatRegistry

    init(rootPath: URL, registry: DocumentFormatRegistry = .shared) {
        self.rootPath = rootPath
        self.registry = registry
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let pathReq = requireString(
            args,
            "path",
            expected: "relative path to an .xlsx workbook under the working folder",
            tool: name
        )
        guard case .value(let relativePath) = pathReq else {
            return pathReq.failureEnvelope ?? ""
        }

        let cellReq = requireString(
            args,
            "cell",
            expected: "A1 cell reference, e.g. B2",
            tool: name
        )
        guard case .value(let rawCellReference) = cellReq else {
            return cellReq.failureEnvelope ?? ""
        }
        let cellReference = rawCellReference.uppercased()
        guard WorkbookToolSupport.parseCellReference(cellReference) != nil else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Argument `cell` must be a valid A1 reference.",
                field: "cell",
                expected: "A1 cell reference, e.g. B2",
                tool: name
            )
        }

        let sheetReq = optionalString(
            args,
            "sheet_name",
            expected: "exact worksheet name",
            tool: name
        )
        guard case .value(let sheetName) = sheetReq else { return sheetReq.failureEnvelope ?? "" }

        let workbookDocument = try await WorkbookToolSupport.loadWorkbook(
            relativePath: relativePath,
            rootPath: rootPath,
            registry: registry
        )
        let sheet = try WorkbookToolSupport.selectedSheet(
            in: workbookDocument.workbook,
            sheetName: sheetName,
            toolName: name
        )
        let cell = sheet.rows.lazy
            .flatMap(\.cells)
            .first { $0.reference.uppercased() == cellReference }

        var payload: [String: Any] = [
            "path": relativePath,
            "sheet": ["name": sheet.name, "index": sheet.index],
            "reference": cellReference,
            "found": cell != nil,
            "cell": NSNull(),
        ]
        if let cell {
            payload["cell"] = WorkbookToolSupport.cellPayload(cell)
        }

        return ToolEnvelope.success(tool: name, result: payload)
    }
}

struct WriteWorkbookTool: OsaurusTool, PermissionedTool {
    let name = "write_workbook"
    let description =
        "Write an XLSX workbook under the working directory from structured sheet rows. This action requires approval."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string("Relative destination path ending in .xlsx"),
            ]),
            "sheets": .object([
                "type": .string("array"),
                "description": .string(
                    "Workbook sheets. Each sheet is an object with `name` and `rows`; rows is an array of cell-value arrays."
                ),
                "items": .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "properties": .object([
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Worksheet name"),
                        ]),
                        "rows": .object([
                            "type": .string("array"),
                            "description": .string(
                                "Rows as arrays of scalar values, nulls, strings, numbers, or booleans"
                            ),
                            "items": .object([
                                "type": .string("array")
                            ]),
                        ]),
                    ]),
                    "required": .array([.string("name"), .string("rows")]),
                ]),
            ]),
        ]),
        "required": .array([.string("path"), .string("sheets")]),
    ])

    var requirements: [String] { [] }
    var defaultPermissionPolicy: ToolPermissionPolicy { .ask }

    private let rootPath: URL
    private let registry: DocumentFormatRegistry

    init(rootPath: URL, registry: DocumentFormatRegistry = .shared) {
        self.rootPath = rootPath
        self.registry = registry
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let pathReq = requireString(
            args,
            "path",
            expected: "relative destination path ending in .xlsx",
            tool: name
        )
        guard case .value(let relativePath) = pathReq else {
            return pathReq.failureEnvelope ?? ""
        }
        guard relativePath.lowercased().hasSuffix(".xlsx") else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Argument `path` must end in .xlsx.",
                field: "path",
                expected: "relative destination path ending in .xlsx",
                tool: name
            )
        }

        guard let rawSheets = args["sheets"] as? [Any] else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Missing or invalid `sheets` array.",
                field: "sheets",
                expected: "array of sheet objects with `name` and `rows`",
                tool: name
            )
        }

        let fileURL = try FolderToolHelpers.resolvePath(relativePath, rootPath: rootPath)
        let workbook: Workbook
        do {
            workbook = try WorkbookToolSupport.workbook(from: rawSheets, toolName: name)
        } catch let error as WorkbookToolInputError {
            return error.envelope
        }
        let document = StructuredDocument(
            formatId: "xlsx",
            filename: fileURL.lastPathComponent,
            fileSize: 0,
            representation: AnyStructuredRepresentation(formatId: "xlsx", underlying: workbook),
            security: .notInspected(
                formatId: "xlsx",
                fileExtension: "xlsx",
                sourceTrust: .generatedArtifact
            ),
            textFallback: WorkbookToolSupport.textFallback(for: workbook)
        )
        let emitter = try WorkbookToolSupport.emitter(
            for: document,
            registry: registry,
            toolName: name
        )

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try await emitter.emit(document, to: fileURL)

        return ToolEnvelope.success(
            tool: name,
            result: [
                "path": relativePath,
                "format_id": "xlsx",
                "sheet_count": workbook.sheets.count,
                "written": true,
            ]
        )
    }
}

private enum WorkbookToolSupport {
    struct LoadedWorkbook {
        let document: StructuredDocument
        let workbook: Workbook
    }

    static func loadWorkbook(
        relativePath: String,
        rootPath: URL,
        registry: DocumentFormatRegistry
    ) async throws -> LoadedWorkbook {
        let fileURL = try FolderToolHelpers.resolvePath(relativePath, rootPath: rootPath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw FolderToolError.fileNotFound(relativePath)
        }
        let adapter = try adapter(for: fileURL, registry: registry, toolName: "workbook")
        let document = try await adapter.parse(
            url: fileURL,
            sizeLimit: DocumentLimits.limit(forFormatId: adapter.formatId)
        )
        guard let workbook = document.representation.underlying as? Workbook else {
            throw FolderToolError.operationFailed(
                "Registered adapter '\(adapter.formatId)' did not produce a Workbook representation."
            )
        }
        return LoadedWorkbook(document: document, workbook: workbook)
    }

    static func selectedSheets(
        in workbook: Workbook,
        sheetName: String?,
        toolName: String
    ) throws -> [Workbook.Sheet] {
        if let sheetName {
            return [try selectedSheet(in: workbook, sheetName: sheetName, toolName: toolName)]
        }
        return workbook.sheets
    }

    static func selectedSheet(
        in workbook: Workbook,
        sheetName: String?,
        toolName: String
    ) throws -> Workbook.Sheet {
        guard let sheetName else {
            guard let first = workbook.sheets.first else {
                throw FolderToolError.operationFailed("Workbook has no sheets.")
            }
            return first
        }
        guard let sheet = workbook.sheets.first(where: { $0.name == sheetName }) else {
            throw FolderToolError.operationFailed("Workbook has no sheet named '\(sheetName)' for \(toolName).")
        }
        return sheet
    }

    static func sheetPayload(
        _ sheet: Workbook.Sheet,
        maxRows: Int,
        maxColumns: Int
    ) -> [String: Any] {
        let rows = sheet.rows.prefix(maxRows)
        let rowPayloads: [[String: Any]] = rows.map { row in
            let cells = row.cells.prefix(maxColumns)
            return [
                "number": row.number,
                "cell_count": row.cells.count,
                "truncated_columns": row.cells.count > maxColumns,
                "cells": cells.map(cellPayload),
            ]
        }
        return [
            "name": sheet.name,
            "index": sheet.index,
            "row_count": sheet.rows.count,
            "merged_ranges": sheet.mergedRanges.map(\.reference),
            "truncated_rows": sheet.rows.count > maxRows,
            "rows": rowPayloads,
        ]
    }

    static func cellPayload(_ cell: Workbook.Cell) -> [String: Any] {
        var payload: [String: Any] = [
            "reference": cell.reference,
            "row": cell.rowNumber,
            "column": cell.columnNumber,
            "value": valuePayload(cell.value),
        ]
        if let formula = cell.formula {
            payload["formula"] = formula
        }
        return payload
    }

    static func valuePayload(_ value: Workbook.CellValue) -> [String: Any] {
        switch value {
        case .empty:
            return ["type": "empty", "value": NSNull(), "text": ""]
        case .number(let value):
            return ["type": "number", "value": value, "text": Workbook.CellValue.number(value).fallbackText]
        case .string(let value):
            return ["type": "string", "value": value, "text": value]
        case .bool(let value):
            return ["type": "boolean", "value": value, "text": value ? "TRUE" : "FALSE"]
        }
    }

    static func workbook(from rawSheets: [Any], toolName: String) throws -> Workbook {
        guard !rawSheets.isEmpty else {
            throw invalid(field: "sheets", expected: "at least one sheet object", toolName: toolName)
        }

        var sheets: [Workbook.Sheet] = []
        var names: Set<String> = []
        for (index, rawSheet) in rawSheets.enumerated() {
            guard let sheetObject = rawSheet as? [String: Any] else {
                throw invalid(field: "sheets", expected: "each sheet must be an object", toolName: toolName)
            }
            guard let name = sheetObject["name"] as? String, !name.isEmpty else {
                throw invalid(field: "name", expected: "non-empty sheet name", toolName: toolName)
            }
            guard names.insert(name.lowercased()).inserted else {
                throw invalid(field: "name", expected: "unique sheet names", toolName: toolName)
            }
            guard let rawRows = sheetObject["rows"] as? [Any] else {
                throw invalid(field: "rows", expected: "array of row arrays", toolName: toolName)
            }
            let rows = try workbookRows(
                from: rawRows,
                sheetName: name,
                sheetIndex: index,
                toolName: toolName
            )
            sheets.append(
                Workbook.Sheet(
                    name: name,
                    index: index,
                    rows: rows,
                    anchor: sheetAnchor(name: name, index: index)
                )
            )
        }

        return Workbook(sheets: sheets)
    }

    static func textFallback(for workbook: Workbook) -> String {
        workbook.sheets.map { sheet in
            var text = "## Sheet: \(sheet.name)"
            for row in sheet.rows {
                let values = row.cells.map { $0.value.fallbackText }.joined(separator: "\t")
                text += "\n\(row.number)\t\(values)"
            }
            return text
        }.joined(separator: "\n\n")
    }

    static func parseCellReference(_ reference: String) -> (columnNumber: Int, rowNumber: Int)? {
        var column = 0
        var rowText = ""
        for scalar in reference.unicodeScalars {
            switch scalar.value {
            case 65 ... 90:
                guard rowText.isEmpty else { return nil }
                column = column * 26 + Int(scalar.value - 65 + 1)
            case 97 ... 122:
                guard rowText.isEmpty else { return nil }
                column = column * 26 + Int(scalar.value - 97 + 1)
            case 48 ... 57:
                rowText.unicodeScalars.append(scalar)
            default:
                return nil
            }
        }
        guard column > 0, let row = Int(rowText), row > 0 else { return nil }
        return (column, row)
    }

    private static func adapter(
        for url: URL,
        registry: DocumentFormatRegistry,
        toolName: String
    ) throws -> any DocumentFormatAdapter {
        var adapter = registry.adapter(for: url)
        if adapter == nil, registry === DocumentFormatRegistry.shared {
            DocumentAdaptersBootstrap.registerBuiltIns()
            adapter = registry.adapter(for: url)
        }
        guard let adapter else {
            throw FolderToolError.operationFailed("No registered workbook adapter for \(toolName).")
        }
        return adapter
    }

    static func emitter(
        for document: StructuredDocument,
        registry: DocumentFormatRegistry,
        toolName: String
    ) throws -> any DocumentFormatEmitter {
        var emitter = registry.emitter(for: document)
        if emitter == nil, registry === DocumentFormatRegistry.shared {
            DocumentAdaptersBootstrap.registerBuiltIns()
            emitter = registry.emitter(for: document)
        }
        guard let emitter else {
            throw FolderToolError.operationFailed("No registered workbook emitter for \(toolName).")
        }
        return emitter
    }

    private static func workbookRows(
        from rawRows: [Any],
        sheetName: String,
        sheetIndex: Int,
        toolName: String
    ) throws -> [Workbook.Row] {
        try rawRows.enumerated().map { rowOffset, rawRow in
            guard let rawCells = rawRow as? [Any] else {
                throw invalid(field: "rows", expected: "each row must be an array", toolName: toolName)
            }
            let rowNumber = rowOffset + 1
            let cells = try rawCells.enumerated().map { columnOffset, rawValue in
                let columnNumber = columnOffset + 1
                let reference = cellReference(columnNumber: columnNumber, rowNumber: rowNumber)
                return Workbook.Cell(
                    reference: reference,
                    rowNumber: rowNumber,
                    columnNumber: columnNumber,
                    value: try cellValue(from: rawValue, toolName: toolName),
                    anchor: cellAnchor(
                        reference: reference,
                        rowNumber: rowNumber,
                        columnNumber: columnNumber,
                        sheetName: sheetName,
                        sheetIndex: sheetIndex
                    )
                )
            }
            return Workbook.Row(
                number: rowNumber,
                cells: cells,
                anchor: rowAnchor(number: rowNumber, sheetName: sheetName, sheetIndex: sheetIndex)
            )
        }
    }

    private static func cellValue(from rawValue: Any, toolName: String) throws -> Workbook.CellValue {
        if rawValue is NSNull { return .empty }
        if let bool = rawValue as? Bool { return .bool(bool) }
        if let int = rawValue as? Int { return .number(Double(int)) }
        if let double = rawValue as? Double { return .number(double) }
        if let number = rawValue as? NSNumber { return .number(number.doubleValue) }
        if let string = rawValue as? String { return .string(string) }
        throw invalid(
            field: "rows",
            expected: "cells must be strings, numbers, booleans, or null",
            toolName: toolName
        )
    }

    private static func sheetAnchor(name: String, index: Int) -> DocumentAnchor {
        DocumentAnchor(
            kind: .sheet,
            path: [
                .init(kind: .document),
                .init(kind: .sheet, identifier: name, index: index),
            ],
            sourceRange: DocumentSourceRange(
                start: DocumentSourceLocation(sheetIndex: index, sheetName: name)
            ),
            label: name,
            metadata: ["sheetIndex": "\(index)"]
        )
    }

    private static func rowAnchor(number: Int, sheetName: String, sheetIndex: Int) -> DocumentAnchor {
        DocumentAnchor(
            kind: .row,
            path: [
                .init(kind: .document),
                .init(kind: .sheet, identifier: sheetName, index: sheetIndex),
                .init(kind: .row, index: number - 1),
            ],
            sourceRange: DocumentSourceRange(
                start: DocumentSourceLocation(
                    sheetIndex: sheetIndex,
                    sheetName: sheetName,
                    rowIndex: number - 1
                )
            ),
            label: "\(sheetName) row \(number)"
        )
    }

    private static func cellAnchor(
        reference: String,
        rowNumber: Int,
        columnNumber: Int,
        sheetName: String,
        sheetIndex: Int
    ) -> DocumentAnchor {
        DocumentAnchor(
            kind: .cell,
            path: [
                .init(kind: .document),
                .init(kind: .sheet, identifier: sheetName, index: sheetIndex),
                .init(kind: .cell, identifier: reference),
            ],
            sourceRange: DocumentSourceRange(
                start: .cell(
                    sheetName: sheetName,
                    rowIndex: rowNumber - 1,
                    columnIndex: columnNumber - 1
                )
            ),
            label: "\(sheetName)!\(reference)"
        )
    }

    private static func cellReference(columnNumber: Int, rowNumber: Int) -> String {
        var column = columnNumber
        var letters = ""
        while column > 0 {
            let remainder = (column - 1) % 26
            let scalar = UnicodeScalar(65 + UInt32(remainder))!
            letters.insert(
                Character(scalar),
                at: letters.startIndex
            )
            column = (column - 1) / 26
        }
        return "\(letters)\(rowNumber)"
    }

    private static func invalid(
        field: String,
        expected: String,
        toolName: String
    ) -> WorkbookToolInputError {
        WorkbookToolInputError(
            envelope: ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Invalid workbook payload field `\(field)`.",
                field: field,
                expected: expected,
                tool: toolName
            )
        )
    }
}

private struct WorkbookToolInputError: Error {
    let envelope: String
}
