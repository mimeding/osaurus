//
//  XLSXAdapterTests.swift
//  osaurusTests
//
//  Validates the first real-fidelity document adapter end-to-end against
//  a checked-in XLSX fixture (produced by xlsxwriter, matching what most
//  business users ship). Ensures we surface sheet names, shared strings,
//  numeric cells, formulas as source strings, merged ranges, and booleans
//  — the round-trip checklist from the stage-2 business catalog.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("XLSXAdapter")
struct XLSXAdapterTests {

    // MARK: - canHandle

    @Test func canHandle_acceptsXLSXOnly() {
        let adapter = XLSXAdapter()
        #expect(adapter.canHandle(url: URL(fileURLWithPath: "/tmp/a.xlsx"), uti: nil))
        #expect(adapter.canHandle(url: URL(fileURLWithPath: "/tmp/a.XLSX"), uti: nil))
        #expect(adapter.canHandle(url: URL(fileURLWithPath: "/tmp/a.xls"), uti: nil) == false)
        #expect(adapter.canHandle(url: URL(fileURLWithPath: "/tmp/a.csv"), uti: nil) == false)
    }

    // MARK: - parse against fixture

    @Test func parse_surfacesSheetStructureAndValues() async throws {
        let url = try Self.fixtureURL()
        let adapter = XLSXAdapter()
        let document = try await adapter.parse(url: url, sizeLimit: 0)

        guard let workbook = document.representation.underlying as? Workbook else {
            Issue.record("representation was not a Workbook")
            return
        }

        #expect(workbook.sheets.count == 2)
        let sheetNames = workbook.sheets.map(\.name)
        #expect(sheetNames.contains("Revenue"))
        #expect(sheetNames.contains("Notes"))
    }

    @Test func parse_preservesFormulasAndMergedRanges() async throws {
        let url = try Self.fixtureURL()
        let document = try await XLSXAdapter().parse(url: url, sizeLimit: 0)
        guard let workbook = document.representation.underlying as? Workbook,
            let revenue = workbook.sheets.first(where: { $0.name == "Revenue" })
        else {
            Issue.record("Revenue sheet missing")
            return
        }

        let formulaCells = revenue.rows
            .flatMap(\.cells)
            .filter { $0.formula != nil }
        #expect(formulaCells.count == 1)
        #expect(formulaCells.first?.formula == "SUM(B2:B3)")

        // Merged cells in the fixture cover A5:B5 (the footer note).
        #expect(revenue.mergedRanges.map(\.reference).contains("A5:B5"))
    }

    @Test func parse_preservesSharedStringsAndNumbers() async throws {
        let url = try Self.fixtureURL()
        let document = try await XLSXAdapter().parse(url: url, sizeLimit: 0)
        guard let workbook = document.representation.underlying as? Workbook,
            let revenue = workbook.sheets.first(where: { $0.name == "Revenue" })
        else {
            Issue.record("Revenue sheet missing")
            return
        }

        // Shared strings include the header labels.
        #expect(workbook.sharedStrings.contains("Month"))
        #expect(workbook.sharedStrings.contains("Amount"))
        #expect(workbook.sharedStrings.contains("January"))

        // B2 = 1200 (numeric, not rendered as a shared string).
        let b2 = revenue.rows.flatMap(\.cells).first { $0.reference == "B2" }
        if case .number(let value) = b2?.value {
            #expect(value == 1200)
        } else {
            Issue.record("B2 was not a number: \(String(describing: b2?.value))")
        }
    }

    @Test func parse_surfacesBooleansOnNotesSheet() async throws {
        let url = try Self.fixtureURL()
        let document = try await XLSXAdapter().parse(url: url, sizeLimit: 0)
        guard let workbook = document.representation.underlying as? Workbook,
            let notes = workbook.sheets.first(where: { $0.name == "Notes" })
        else {
            Issue.record("Notes sheet missing")
            return
        }
        let boolCells = notes.rows.flatMap(\.cells).filter {
            if case .bool = $0.value { return true } else { return false }
        }
        #expect(boolCells.count == 2)
    }

    @Test func parse_textFallback_containsHumanReadableTable() async throws {
        let url = try Self.fixtureURL()
        let document = try await XLSXAdapter().parse(url: url, sizeLimit: 0)

        #expect(document.textFallback.contains("## Sheet: Revenue"))
        #expect(document.textFallback.contains("Total"))
        #expect(document.textFallback.contains("=SUM(B2:B3)"))
        #expect(document.textFallback.contains("Merged: A5:B5"))
    }

    @Test func parse_rejectsOversizedFile() async throws {
        let url = try Self.fixtureURL()
        await #expect(throws: DocumentAdapterError.self) {
            _ = try await XLSXAdapter().parse(url: url, sizeLimit: 64)
        }
    }

    // MARK: - Fixture plumbing

    private static func fixtureURL() throws -> URL {
        // `.copy("Documents/Fixtures")` in `Package.swift` drops the parent
        // `Documents/` segment inside the test bundle, so resources live
        // under `Fixtures/xlsx/...` at the bundle root.
        guard
            let url = Bundle.module.url(
                forResource: "sample",
                withExtension: "xlsx",
                subdirectory: "Fixtures/xlsx"
            )
        else {
            throw FixtureError.missing
        }
        return url
    }

    private enum FixtureError: Error { case missing }
}
