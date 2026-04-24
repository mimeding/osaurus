//
//  WorkbookToolsTests.swift
//  osaurusTests
//
//  End-to-end tests for the `read_workbook` / `read_workbook_cell` /
//  `write_workbook` agent tools. Uses the checked-in sample.xlsx fixture
//  for the read paths and a temp directory for the write path so the
//  three tools exercise the same XLSXAdapter / XLSXEmitter pair that
//  agents see in production.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Workbook agent tools")
struct WorkbookToolsTests {

    private let rootPath: URL
    private let fixturePath: URL

    init() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-wb-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        rootPath = tmp

        // Copy the fixture into the temp root so the tools can resolve
        // "sample.xlsx" as a relative path under the working folder.
        guard
            let bundled = Bundle.module.url(
                forResource: "sample",
                withExtension: "xlsx",
                subdirectory: "Fixtures/xlsx"
            )
        else {
            throw FixtureError.missing
        }
        fixturePath = tmp.appendingPathComponent("sample.xlsx")
        try FileManager.default.copyItem(at: bundled, to: fixturePath)
    }

    // MARK: - read_workbook

    @Test func readWorkbook_returnsSheetSummaries() async throws {
        let tool = ReadWorkbookTool(rootPath: rootPath)
        let envelope = try await tool.execute(argumentsJSON: #"{"path":"sample.xlsx"}"#)
        let payload = try Self.successTextAsDict(envelope)

        #expect(payload["path"] as? String == "sample.xlsx")
        let sheets = payload["sheets"] as? [[String: Any]] ?? []
        #expect(sheets.count == 2)
        #expect(sheets.map { $0["name"] as? String }.contains { $0 == "Revenue" })
        #expect(sheets.map { $0["name"] as? String }.contains { $0 == "Notes" })

        let revenue = sheets.first { $0["name"] as? String == "Revenue" } ?? [:]
        let merged = revenue["mergedRanges"] as? [String] ?? []
        #expect(merged.contains("A5:B5"))
    }

    @Test func readWorkbook_rejectsMissingFile() async throws {
        let tool = ReadWorkbookTool(rootPath: rootPath)
        let envelope = try await tool.execute(argumentsJSON: #"{"path":"nope.xlsx"}"#)
        #expect(envelope.contains("\"kind\":\"execution_error\"") || envelope.contains("\"ok\":false"))
    }

    @Test func readWorkbook_rejectsPathOutsideRoot() async throws {
        let tool = ReadWorkbookTool(rootPath: rootPath)
        let envelope = try await tool.execute(argumentsJSON: #"{"path":"../outside.xlsx"}"#)
        #expect(envelope.contains("outside") || envelope.contains("invalid"))
    }

    // MARK: - read_workbook_cell

    @Test func readWorkbookCell_returnsFormulaAndValue() async throws {
        let tool = ReadWorkbookCellTool(rootPath: rootPath)
        let envelope = try await tool.execute(
            argumentsJSON: #"{"path":"sample.xlsx","sheet":"Revenue","cell":"B4"}"#
        )
        let payload = try Self.successTextAsDict(envelope)
        #expect(payload["ref"] as? String == "B4")
        #expect(payload["formula"] as? String == "SUM(B2:B3)")
    }

    @Test func readWorkbookCell_rejectsMissingSheet() async throws {
        let tool = ReadWorkbookCellTool(rootPath: rootPath)
        let envelope = try await tool.execute(
            argumentsJSON: #"{"path":"sample.xlsx","sheet":"Ghost","cell":"A1"}"#
        )
        #expect(envelope.contains("not found"))
    }

    // MARK: - write_workbook

    @Test func writeWorkbook_emitsAndRoundTrips() async throws {
        let tool = WriteWorkbookTool(rootPath: rootPath)
        let input = #"""
            {
              "path": "output.xlsx",
              "sheets": [
                {
                  "name": "Numbers",
                  "cells": [
                    {"ref": "A1", "type": "string", "value": "Label"},
                    {"ref": "B1", "type": "number", "value": 42},
                    {"ref": "A2", "type": "bool", "value": true},
                    {"ref": "C1", "type": "formula", "formula": "B1*2"}
                  ],
                  "mergedRanges": ["A3:B3"]
                }
              ]
            }
            """#
        let envelope = try await tool.execute(argumentsJSON: input)
        let payload = try Self.successTextAsDict(envelope)
        #expect(payload["sheetCount"] as? Int == 1)

        let outURL = rootPath.appendingPathComponent("output.xlsx")
        #expect(FileManager.default.fileExists(atPath: outURL.path))

        // Round-trip through XLSXAdapter to confirm the cells the agent
        // requested actually landed in the file.
        let reparsed = try await XLSXAdapter().parse(url: outURL, sizeLimit: 0)
        guard let workbook = reparsed.representation.underlying as? Workbook else {
            Issue.record("re-parsed representation was not a Workbook")
            return
        }
        #expect(workbook.sheets.first?.name == "Numbers")
        let cells = workbook.sheets.first?.rows.flatMap(\.cells) ?? []
        #expect(cells.contains { $0.reference == "A1" })
        #expect(cells.contains { $0.reference == "B1" })
        #expect(cells.contains { $0.reference == "C1" && $0.formula == "B1*2" })
    }

    @Test func writeWorkbook_rejectsNonXLSXPath() async throws {
        let tool = WriteWorkbookTool(rootPath: rootPath)
        let envelope = try await tool.execute(
            argumentsJSON: #"{"path":"report.txt","sheets":[{"name":"Sheet1","cells":[]}]}"#
        )
        #expect(envelope.contains("must end in"))
    }

    @Test func writeWorkbook_rejectsEmptySheets() async throws {
        let tool = WriteWorkbookTool(rootPath: rootPath)
        let envelope = try await tool.execute(
            argumentsJSON: #"{"path":"out.xlsx","sheets":[]}"#
        )
        #expect(envelope.contains("non-empty"))
    }

    // MARK: - Helpers

    /// Extracts the inner `result.text` from a `ToolEnvelope.success` JSON
    /// and parses it as a dictionary — the envelope wraps every tool
    /// response so tests have to peel one layer.
    private static func successTextAsDict(_ envelope: String) throws -> [String: Any] {
        let data = envelope.data(using: .utf8) ?? Data()
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = obj["result"] as? [String: Any],
            let text = result["text"] as? String,
            let innerData = text.data(using: .utf8),
            let inner = try JSONSerialization.jsonObject(with: innerData) as? [String: Any]
        else {
            throw FixtureError.notSuccessEnvelope(envelope)
        }
        return inner
    }

    private enum FixtureError: Error, CustomStringConvertible {
        case missing
        case notSuccessEnvelope(String)

        var description: String {
            switch self {
            case .missing: return "Bundle.module lost the sample.xlsx fixture"
            case .notSuccessEnvelope(let raw): return "Not a success envelope: \(raw)"
            }
        }
    }
}
