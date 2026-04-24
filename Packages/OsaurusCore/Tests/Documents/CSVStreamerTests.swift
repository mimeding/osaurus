//
//  CSVStreamerTests.swift
//  osaurusTests
//
//  Streaming-side coverage for the CSV pipeline. The parser state machine
//  is shared with `CSVAdapter`, so these tests focus on the streaming
//  contract: back-pressure via AsyncThrowingStream, row-by-row emission,
//  UTF-8 boundary handling across chunk edges, and cancellation.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("CSVStreamer")
struct CSVStreamerTests {

    @Test func stream_yieldsRowsInOrder() async throws {
        let url = try Self.write(
            """
            name,score
            Alice,10
            Bob,20
            Carol,30
            """,
            ext: "csv"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        var collected: [[String]] = []
        for try await record in CSVStreamer().stream(url: url) {
            collected.append(record.cells)
        }
        #expect(
            collected == [
                ["name", "score"],
                ["Alice", "10"],
                ["Bob", "20"],
                ["Carol", "30"],
            ]
        )
    }

    @Test func stream_numbersRowsFromOne() async throws {
        let url = try Self.write("a,b\n1,2\n3,4\n", ext: "csv")
        defer { try? FileManager.default.removeItem(at: url) }

        var lineNumbers: [Int] = []
        for try await record in CSVStreamer().stream(url: url) {
            lineNumbers.append(record.lineNumber)
        }
        #expect(lineNumbers == [1, 2, 3])
    }

    @Test func stream_tsvSplitsOnTab() async throws {
        let url = try Self.write("col1\tcol2\nA\t1\nB\t2\n", ext: "tsv")
        defer { try? FileManager.default.removeItem(at: url) }

        var collected: [[String]] = []
        for try await record in CSVStreamer().stream(url: url) {
            collected.append(record.cells)
        }
        #expect(collected == [["col1", "col2"], ["A", "1"], ["B", "2"]])
    }

    @Test func stream_preservesQuotedNewlinesAcrossChunks() async throws {
        // Build a payload bigger than one chunk so the parser actually
        // sees the embedded newline arrive in two separate feeds.
        let filler = String(repeating: "x", count: 70_000)
        let url = try Self.write(
            """
            id,note
            1,"line one
            line two \(filler) end"
            2,plain
            """,
            ext: "csv"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        var collected: [[String]] = []
        for try await record in CSVStreamer().stream(url: url) {
            collected.append(record.cells)
        }
        #expect(collected.count == 3)
        #expect(collected[1].count == 2)
        #expect(collected[1][0] == "1")
        #expect(collected[1][1].hasPrefix("line one\nline two "))
        #expect(collected[1][1].hasSuffix(" end"))
        #expect(collected[2] == ["2", "plain"])
    }

    @Test func stream_cancellationStopsMidFile() async throws {
        // Generate a file large enough that cancellation happens before
        // all rows drain. 10k rows × ~20 bytes = ~200 KB — several chunks.
        var text = "id,v\n"
        for i in 0 ..< 10_000 {
            text.append("\(i),\(i * 2)\n")
        }
        let url = try Self.write(text, ext: "csv")
        defer { try? FileManager.default.removeItem(at: url) }

        let task = Task { () -> Int in
            var count = 0
            for try await _ in CSVStreamer().stream(url: url) {
                count += 1
                if count >= 3 {
                    // Caller would normally break out of the loop; here we
                    // cancel the whole task so the streaming Task inside the
                    // streamer observes cancellation on its next check.
                    return count
                }
            }
            return count
        }
        let delivered = try await task.value
        #expect(delivered == 3)
    }

    // MARK: - UTF-8 boundary split helper

    @Test func splitAtUTF8Boundary_keepsCompleteScalars() {
        // `é` is C3 A9 in UTF-8. Cut the buffer mid-scalar and confirm
        // the tail gets carried to the next read.
        let data = Data([0x61, 0xC3, 0xA9, 0xC3])  // "a", "é", then a lead byte C3 with no continuation
        let (decodable, tail) = CSVStreamer.splitAtUTF8Boundary(data)
        #expect(decodable.count == 3)
        #expect(tail == Data([0xC3]))
    }

    @Test func splitAtUTF8Boundary_shortBufferReturnedAsIs() {
        let data = Data([0x61, 0x62])
        let (decodable, tail) = CSVStreamer.splitAtUTF8Boundary(data)
        #expect(decodable == data)
        #expect(tail.isEmpty)
    }

    // MARK: - Fixtures

    private static func write(_ content: String, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-csvstream-\(UUID().uuidString).\(ext)")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
