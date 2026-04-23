//
//  XLSXEmitterTests.swift
//  osaurusTests
//
//  Proves the XLSX round trip: build a `Workbook` in memory, emit it
//  through `XLSXEmitter`, re-parse the resulting file through
//  `XLSXAdapter`, and assert that every fidelity feature we care about
//  — sheet names, cell values, formula source strings, merged ranges,
//  booleans — survives. Libxlsxwriter's output is strictly standards-
//  conforming so the re-parse exercises the same CoreXLSX paths the
//  read-side tests already pin.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("XLSXEmitter round trip")
struct XLSXEmitterTests {

    @Test func canEmit_onlyAcceptsWorkbookRepresentations() {
        let emitter = XLSXEmitter()
        let workbookDoc = StructuredDocument(
            formatId: "xlsx",
            filename: "a.xlsx",
            fileSize: 0,
            representation: AnyStructuredRepresentation(
                formatId: "xlsx",
                underlying: Workbook(sheets: [], sharedStrings: [])
            ),
            textFallback: ""
        )
        let plainDoc = StructuredDocument(
            formatId: "plaintext",
            filename: "a.txt",
            fileSize: 0,
            representation: AnyStructuredRepresentation(
                formatId: "plaintext",
                underlying: PlainTextRepresentation(text: "")
            ),
            textFallback: ""
        )

        #expect(emitter.canEmit(workbookDoc))
        #expect(emitter.canEmit(plainDoc) == false)
    }

    // MARK: - Round trip

    @Test func emit_thenReparse_preservesSheetsAndCells() async throws {
        let input = Self.makeRoundTripFixture()
        let dest = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: dest) }

        let emitter = XLSXEmitter()
        try await emitter.emit(Self.wrap(input), to: dest)

        #expect(FileManager.default.fileExists(atPath: dest.path))

        let reparsed = try await XLSXAdapter().parse(url: dest, sizeLimit: 0)
        guard let output = reparsed.representation.underlying as? Workbook else {
            Issue.record("Re-parsed representation was not a Workbook")
            return
        }

        #expect(output.sheets.count == input.sheets.count)
        for (expected, actual) in zip(input.sheets, output.sheets) {
            #expect(expected.name == actual.name, "sheet name mismatch")
        }
    }

    @Test func emit_preservesFormulaSourceStrings() async throws {
        let input = Self.makeRoundTripFixture()
        let dest = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: dest) }

        try await XLSXEmitter().emit(Self.wrap(input), to: dest)
        let reparsed = try await XLSXAdapter().parse(url: dest, sizeLimit: 0)
        guard let output = reparsed.representation.underlying as? Workbook else {
            Issue.record("Re-parsed representation was not a Workbook")
            return
        }

        let formulas = output.sheets
            .flatMap(\.rows)
            .flatMap(\.cells)
            .compactMap(\.formula)
        #expect(formulas.contains("SUM(B2:B3)"))
    }

    @Test func emit_preservesMergedRanges() async throws {
        let input = Self.makeRoundTripFixture()
        let dest = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: dest) }

        try await XLSXEmitter().emit(Self.wrap(input), to: dest)
        let reparsed = try await XLSXAdapter().parse(url: dest, sizeLimit: 0)
        guard let output = reparsed.representation.underlying as? Workbook else {
            Issue.record("Re-parsed representation was not a Workbook")
            return
        }

        let mergedRefs = output.sheets.flatMap { $0.mergedRanges.map(\.reference) }
        #expect(mergedRefs.contains("A5:B5"))
    }

    @Test func emit_preservesStringAndNumberCells() async throws {
        let input = Self.makeRoundTripFixture()
        let dest = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: dest) }

        try await XLSXEmitter().emit(Self.wrap(input), to: dest)
        let reparsed = try await XLSXAdapter().parse(url: dest, sizeLimit: 0)
        guard let output = reparsed.representation.underlying as? Workbook,
            let revenue = output.sheets.first(where: { $0.name == "Revenue" })
        else {
            Issue.record("Revenue sheet missing after round trip")
            return
        }

        // "Month" string header lands in A1.
        let a1 = revenue.rows.flatMap(\.cells).first { $0.reference == "A1" }
        if case .string(let value) = a1?.value {
            #expect(value == "Month")
        } else {
            Issue.record("A1 after round trip was \(String(describing: a1?.value))")
        }

        // 1200 number lands in B2.
        let b2 = revenue.rows.flatMap(\.cells).first { $0.reference == "B2" }
        if case .number(let value) = b2?.value {
            #expect(value == 1200)
        } else {
            Issue.record("B2 after round trip was \(String(describing: b2?.value))")
        }
    }

    @Test func emit_preservesBooleans() async throws {
        let input = Self.makeRoundTripFixture()
        let dest = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: dest) }

        try await XLSXEmitter().emit(Self.wrap(input), to: dest)
        let reparsed = try await XLSXAdapter().parse(url: dest, sizeLimit: 0)
        guard let output = reparsed.representation.underlying as? Workbook,
            let notes = output.sheets.first(where: { $0.name == "Notes" })
        else {
            Issue.record("Notes sheet missing")
            return
        }

        let bools = notes.rows.flatMap(\.cells).compactMap { cell -> Bool? in
            if case .bool(let flag) = cell.value { return flag } else { return nil }
        }
        #expect(bools.count == 2)
        #expect(bools.contains(true))
        #expect(bools.contains(false))
    }

    @Test func emit_rejectsNonWorkbookRepresentation() async throws {
        let dest = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: dest) }
        let plain = StructuredDocument(
            formatId: "plaintext",
            filename: "a.txt",
            fileSize: 0,
            representation: AnyStructuredRepresentation(
                formatId: "plaintext",
                underlying: PlainTextRepresentation(text: "")
            ),
            textFallback: ""
        )
        await #expect(throws: DocumentAdapterError.self) {
            try await XLSXEmitter().emit(plain, to: dest)
        }
    }

    // MARK: - Fixture builder

    private static func wrap(_ workbook: Workbook) -> StructuredDocument {
        StructuredDocument(
            formatId: "xlsx",
            filename: "fixture.xlsx",
            fileSize: 0,
            representation: AnyStructuredRepresentation(
                formatId: "xlsx",
                underlying: workbook
            ),
            textFallback: ""
        )
    }

    /// Matches the shape of the checked-in `sample.xlsx` fixture so the
    /// emitter and adapter exercise the same fidelity checklist.
    private static func makeRoundTripFixture() -> Workbook {
        let revenue = Sheet(
            name: "Revenue",
            rows: [
                Row(
                    index: 1,
                    cells: [
                        Cell(reference: "A1", value: .string("Month")),
                        Cell(reference: "B1", value: .string("Amount")),
                    ]
                ),
                Row(
                    index: 2,
                    cells: [
                        Cell(reference: "A2", value: .string("January")),
                        Cell(reference: "B2", value: .number(1200)),
                    ]
                ),
                Row(
                    index: 3,
                    cells: [
                        Cell(reference: "A3", value: .string("February")),
                        Cell(reference: "B3", value: .number(950)),
                    ]
                ),
                Row(
                    index: 4,
                    cells: [
                        Cell(reference: "A4", value: .string("Total")),
                        Cell(reference: "B4", value: .empty, formula: "SUM(B2:B3)"),
                    ]
                ),
                Row(
                    index: 5,
                    cells: [
                        Cell(reference: "A5", value: .string("Generated for osaurus tests"))
                    ]
                ),
            ],
            mergedRanges: [CellRange(reference: "A5:B5")]
        )

        let notes = Sheet(
            name: "Notes",
            rows: [
                Row(
                    index: 1,
                    cells: [
                        Cell(reference: "A1", value: .string("Key")),
                        Cell(reference: "B1", value: .string("Value")),
                    ]
                ),
                Row(
                    index: 2,
                    cells: [
                        Cell(reference: "A2", value: .string("reviewer")),
                        Cell(reference: "B2", value: .string("mimeding")),
                    ]
                ),
                Row(
                    index: 3,
                    cells: [
                        Cell(reference: "A3", value: .bool(true)),
                        Cell(reference: "B3", value: .bool(false)),
                    ]
                ),
            ],
            mergedRanges: []
        )

        return Workbook(sheets: [revenue, notes], sharedStrings: [])
    }

    private static func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-xlsx-roundtrip-\(UUID().uuidString).xlsx")
    }
}
