//
//  CSVAdapterTests.swift
//  osaurusTests
//
//  Covers the in-memory CSV / TSV adapter. Pins the fields business users
//  expect to survive an ingest: delimiter auto-pick per extension, quoted
//  cells with commas and newlines, `""` quote escapes, UTF-8 BOM handling,
//  header-row detection, and size-limit refusal. The streaming variant
//  has its own suite — the parser state machine is shared, so this one
//  focuses on the eager path + the typed CSVTable output.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("CSVAdapter")
struct CSVAdapterTests {

    @Test func canHandle_claimsCSVAndTSV() {
        let adapter = CSVAdapter()
        #expect(adapter.canHandle(url: URL(fileURLWithPath: "/tmp/a.csv"), uti: nil))
        #expect(adapter.canHandle(url: URL(fileURLWithPath: "/tmp/a.TSV"), uti: nil))
        #expect(adapter.canHandle(url: URL(fileURLWithPath: "/tmp/a.txt"), uti: nil) == false)
    }

    @Test func parse_splitsHeaderFromRecords() async throws {
        let url = try Self.write(
            """
            Month,Revenue,Status
            January,1200,closed
            February,950,closed
            March,1400,open
            """,
            ext: "csv"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try await CSVAdapter().parse(url: url, sizeLimit: 0)
        guard let table = document.representation.underlying as? CSVTable else {
            Issue.record("not a CSVTable"); return
        }
        #expect(table.header == ["Month", "Revenue", "Status"])
        #expect(table.records.count == 3)
        #expect(table.records.first == ["January", "1200", "closed"])
        #expect(table.delimiter == ",")
    }

    @Test func parse_tsvUsesTabDelimiter() async throws {
        let url = try Self.write("Col1\tCol2\nA\t1\nB\t2\n", ext: "tsv")
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try await CSVAdapter().parse(url: url, sizeLimit: 0)
        guard let table = document.representation.underlying as? CSVTable else {
            Issue.record("not a CSVTable"); return
        }
        #expect(table.delimiter == "\t")
        #expect(table.header == ["Col1", "Col2"])
        #expect(table.records == [["A", "1"], ["B", "2"]])
    }

    @Test func parse_preservesQuotedCommasAndNewlines() async throws {
        // Row 1 has a comma inside the quoted second field; row 2 has a
        // newline inside a quoted field. Both must end up as single cells.
        let url = try Self.write(
            """
            name,note
            "Smith, John","note line 1
            note line 2"
            Doe,plain
            """,
            ext: "csv"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try await CSVAdapter().parse(url: url, sizeLimit: 0)
        guard let table = document.representation.underlying as? CSVTable else {
            Issue.record("not a CSVTable"); return
        }
        #expect(table.records.count == 2)
        #expect(table.records[0] == ["Smith, John", "note line 1\nnote line 2"])
        #expect(table.records[1] == ["Doe", "plain"])
    }

    @Test func parse_expandsDoubleQuoteEscape() async throws {
        // Raw `#"""` so the embedded `""` escapes don't fight the compiler.
        let url = try Self.write(
            #"""
            code,label
            A,"He said ""yes"""
            """#,
            ext: "csv"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try await CSVAdapter().parse(url: url, sizeLimit: 0)
        guard let table = document.representation.underlying as? CSVTable else {
            Issue.record("not a CSVTable"); return
        }
        #expect(table.records.first == ["A", #"He said "yes""#])
    }

    @Test func parse_stripsUTF8BOM() async throws {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let body = "Name,Value\nAlpha,1\n".data(using: .utf8)!
        var combined = bom
        combined.append(body)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-csv-bom-\(UUID().uuidString).csv")
        try combined.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try await CSVAdapter().parse(url: url, sizeLimit: 0)
        guard let table = document.representation.underlying as? CSVTable else {
            Issue.record("not a CSVTable"); return
        }
        #expect(table.header == ["Name", "Value"])
        #expect(table.records.first == ["Alpha", "1"])
    }

    @Test func parse_numericOnlyFirstRowIsNotHeader() async throws {
        // All-numeric first row → no header detection; the whole file
        // should surface as records.
        let url = try Self.write("1,2,3\n4,5,6\n", ext: "csv")
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try await CSVAdapter().parse(url: url, sizeLimit: 0)
        guard let table = document.representation.underlying as? CSVTable else {
            Issue.record("not a CSVTable"); return
        }
        #expect(table.header == nil)
        #expect(table.records == [["1", "2", "3"], ["4", "5", "6"]])
    }

    @Test func parse_rejectsOversizedFile() async throws {
        let url = try Self.write("a,b\n1,2\n", ext: "csv")
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: DocumentAdapterError.self) {
            _ = try await CSVAdapter().parse(url: url, sizeLimit: 1)
        }
    }

    @Test func parse_emptyFileThrowsEmptyContent() async throws {
        let url = try Self.write("", ext: "csv")
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: DocumentAdapterError.self) {
            _ = try await CSVAdapter().parse(url: url, sizeLimit: 0)
        }
    }

    @Test func parse_crlfLineEndingsAreRecognised() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-csv-crlf-\(UUID().uuidString).csv")
        try "a,b\r\n1,2\r\n3,4\r\n".data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try await CSVAdapter().parse(url: url, sizeLimit: 0)
        guard let table = document.representation.underlying as? CSVTable else {
            Issue.record("not a CSVTable"); return
        }
        #expect(table.records == [["1", "2"], ["3", "4"]])
    }

    // MARK: - Fixtures

    private static func write(_ content: String, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-csv-\(UUID().uuidString).\(ext)")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
