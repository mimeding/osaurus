//
//  WorkbookToolsTests.swift
//
//  Covers the folder-facing workbook tools against the document registry
//  and the existing XLSX adapter/emitter pair.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Workbook folder tools")
struct WorkbookToolsTests {

    @Test func readWorkbookReturnsStructuredSheetsFromRegistryAdapter() async throws {
        let fixture = try await Self.fixture()
        let tool = ReadWorkbookTool(rootPath: fixture.root, registry: fixture.registry)

        let result = try await tool.execute(
            argumentsJSON: #"{"path":"sample.xlsx","sheet_name":"Revenue","max_rows":2,"max_columns":2}"#
        )
        let payload = try Self.successPayload(result)
        let sheets = try #require(payload["sheets"] as? [[String: Any]])
        let firstSheet = try #require(sheets.first)
        let rows = try #require(firstSheet["rows"] as? [[String: Any]])
        let firstRow = try #require(rows.first)
        let cells = try #require(firstRow["cells"] as? [[String: Any]])

        #expect(payload["format_id"] as? String == "xlsx")
        #expect(firstSheet["name"] as? String == "Revenue")
        #expect(firstSheet["row_count"] as? Int == 3)
        #expect(firstSheet["truncated_rows"] as? Bool == true)
        #expect(cells.count == 2)
        #expect(cells.first?["reference"] as? String == "A1")
    }

    @Test func readWorkbookFailsForMissingSheet() async throws {
        let fixture = try await Self.fixture()
        let tool = ReadWorkbookTool(rootPath: fixture.root, registry: fixture.registry)

        do {
            _ = try await tool.execute(argumentsJSON: #"{"path":"sample.xlsx","sheet_name":"Missing"}"#)
            Issue.record("read_workbook should reject an unknown sheet")
        } catch let error as FolderToolError {
            guard case .operationFailed(let message) = error else {
                Issue.record("expected operationFailed, got \(error)")
                return
            }
            #expect(message.contains("Missing"))
        }
    }

    @Test func readWorkbookCellReturnsOneCell() async throws {
        let fixture = try await Self.fixture()
        let tool = ReadWorkbookCellTool(rootPath: fixture.root, registry: fixture.registry)

        let result = try await tool.execute(
            argumentsJSON: #"{"path":"sample.xlsx","sheet_name":"Revenue","cell":"B2"}"#
        )
        let payload = try Self.successPayload(result)
        let cell = try #require(payload["cell"] as? [String: Any])
        let value = try #require(cell["value"] as? [String: Any])

        #expect(payload["found"] as? Bool == true)
        #expect(cell["reference"] as? String == "B2")
        #expect(value["type"] as? String == "number")
        #expect(value["text"] as? String == "1200")
    }

    @Test func readWorkbookCellRejectsInvalidReference() async throws {
        let tool = ReadWorkbookCellTool(rootPath: Self.tmpRoot(), registry: Self.registry())
        let result = try await tool.execute(argumentsJSON: #"{"path":"sample.xlsx","cell":"not-a-cell"}"#)

        #expect(ToolEnvelope.isError(result))
        #expect(EnvelopeAssertions.failureKind(result) == "invalid_args")
        #expect(EnvelopeAssertions.failureField(result) == "cell")
    }

    @Test func writeWorkbookUsesRegistryEmitterAndRoundTrips() async throws {
        let root = Self.tmpRoot()
        let registry = Self.registry()
        let tool = WriteWorkbookTool(rootPath: root, registry: registry)

        let result = try await tool.execute(
            argumentsJSON:
                #"{"path":"created/report.xlsx","sheets":[{"name":"Revenue","rows":[["Month","Amount"],["January",1200],["Approved",true]]}]}"#
        )
        let payload = try Self.successPayload(result)
        let fileURL = root.appendingPathComponent("created/report.xlsx")
        let parsed = try await XLSXAdapter().parse(url: fileURL, sizeLimit: 0)
        let workbook = try #require(parsed.representation.underlying as? Workbook)
        let revenue = try #require(workbook.sheets.first)

        #expect(payload["written"] as? Bool == true)
        #expect(payload["sheet_count"] as? Int == 1)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(revenue.rows[1].cells[1].value == .number(1200))
        #expect(revenue.rows[2].cells[1].value == .bool(true))
    }

    @Test func writeWorkbookRequiresApprovalAndRejectsEscapingPath() async throws {
        let root = Self.tmpRoot()
        let tool = WriteWorkbookTool(rootPath: root, registry: Self.registry())

        #expect(tool.defaultPermissionPolicy == .ask)
        do {
            _ = try await tool.execute(
                argumentsJSON:
                    #"{"path":"../escape.xlsx","sheets":[{"name":"Sheet1","rows":[["x"]]}]}"#
            )
            Issue.record("write_workbook should reject paths outside the root")
        } catch let error as FolderToolError {
            guard case .pathOutsideRoot = error else {
                Issue.record("expected pathOutsideRoot, got \(error)")
                return
            }
        }
    }

    @MainActor
    @Test func folderRegistrationIncludesWorkbookTools() {
        let manager = FolderToolManager.shared
        let context = FolderContext(
            rootPath: Self.tmpRoot(),
            projectType: .unknown,
            tree: "",
            manifest: nil,
            gitStatus: nil,
            isGitRepo: false
        )
        manager.registerFolderTools(for: context)
        defer { manager.unregisterFolderTools() }

        for name in ["read_workbook", "read_workbook_cell", "write_workbook"] {
            #expect(manager.folderToolNames.contains(name))
        }
    }

    // MARK: - Fixtures

    private struct Fixture {
        let root: URL
        let registry: DocumentFormatRegistry
    }

    private static func fixture() async throws -> Fixture {
        let root = tmpRoot()
        let url = root.appendingPathComponent("sample.xlsx")
        try await XLSXEmitter().emit(document(workbook: makeWorkbook()), to: url)
        return Fixture(root: root, registry: registry())
    }

    private static func registry() -> DocumentFormatRegistry {
        let registry = DocumentFormatRegistry()
        registry.register(adapter: XLSXAdapter())
        registry.register(emitter: XLSXEmitter())
        return registry
    }

    private static func tmpRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-workbook-tools-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return dir
    }

    private static func successPayload(_ raw: String) throws -> [String: Any] {
        try #require(ToolEnvelope.successPayload(raw) as? [String: Any])
    }

    private static func document(workbook: Workbook) -> StructuredDocument {
        StructuredDocument(
            formatId: "xlsx",
            filename: "sample.xlsx",
            fileSize: 0,
            representation: AnyStructuredRepresentation(formatId: "xlsx", underlying: workbook),
            security: .notInspected(
                formatId: "xlsx",
                fileExtension: "xlsx",
                sourceTrust: .generatedArtifact
            ),
            textFallback: ""
        )
    }

    private static func makeWorkbook() -> Workbook {
        let rows = [
            row(
                number: 1,
                sheetName: "Revenue",
                sheetIndex: 0,
                cells: [
                    cell("A1", row: 1, column: 1, value: .string("Month"), sheetName: "Revenue", sheetIndex: 0),
                    cell("B1", row: 1, column: 2, value: .string("Amount"), sheetName: "Revenue", sheetIndex: 0),
                    cell("C1", row: 1, column: 3, value: .string("Approved"), sheetName: "Revenue", sheetIndex: 0),
                ]
            ),
            row(
                number: 2,
                sheetName: "Revenue",
                sheetIndex: 0,
                cells: [
                    cell("A2", row: 2, column: 1, value: .string("January"), sheetName: "Revenue", sheetIndex: 0),
                    cell("B2", row: 2, column: 2, value: .number(1200), sheetName: "Revenue", sheetIndex: 0),
                    cell("C2", row: 2, column: 3, value: .bool(true), sheetName: "Revenue", sheetIndex: 0),
                ]
            ),
            row(
                number: 3,
                sheetName: "Revenue",
                sheetIndex: 0,
                cells: [
                    cell("A3", row: 3, column: 1, value: .string("February"), sheetName: "Revenue", sheetIndex: 0),
                    cell("B3", row: 3, column: 2, value: .number(1300.5), sheetName: "Revenue", sheetIndex: 0),
                    cell("C3", row: 3, column: 3, value: .bool(false), sheetName: "Revenue", sheetIndex: 0),
                ]
            ),
        ]

        return Workbook(
            sheets: [
                Workbook.Sheet(
                    name: "Revenue",
                    index: 0,
                    rows: rows,
                    anchor: sheetAnchor(name: "Revenue", index: 0)
                )
            ]
        )
    }

    private static func row(
        number: Int,
        sheetName: String,
        sheetIndex: Int,
        cells: [Workbook.Cell]
    ) -> Workbook.Row {
        Workbook.Row(
            number: number,
            cells: cells,
            anchor: DocumentAnchor(
                kind: .row,
                path: [
                    .init(kind: .document),
                    .init(kind: .sheet, identifier: sheetName, index: sheetIndex),
                    .init(kind: .row, index: number - 1),
                ],
                sourceRange: DocumentSourceRange(
                    start: DocumentSourceLocation(sheetIndex: sheetIndex, sheetName: sheetName, rowIndex: number - 1)
                ),
                label: "\(sheetName) row \(number)"
            )
        )
    }

    private static func cell(
        _ reference: String,
        row: Int,
        column: Int,
        value: Workbook.CellValue,
        sheetName: String,
        sheetIndex: Int
    ) -> Workbook.Cell {
        Workbook.Cell(
            reference: reference,
            rowNumber: row,
            columnNumber: column,
            value: value,
            anchor: DocumentAnchor(
                kind: .cell,
                path: [
                    .init(kind: .document),
                    .init(kind: .sheet, identifier: sheetName, index: sheetIndex),
                    .init(kind: .cell, identifier: reference),
                ],
                sourceRange: DocumentSourceRange(
                    start: .cell(sheetName: sheetName, rowIndex: row - 1, columnIndex: column - 1)
                ),
                label: "\(sheetName)!\(reference)"
            )
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
}
