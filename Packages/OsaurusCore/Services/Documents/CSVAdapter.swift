//
//  CSVAdapter.swift
//  osaurus
//
//  RFC-4180-ish CSV / TSV parser that produces a typed `CSVTable`.
//  Replaces the legacy "CSV as plain text" path — the adapter still
//  returns a text fallback for chat attachment display, but the typed
//  representation exposes delimiter, encoding, line-ending, and per-row
//  cell boundaries so the downstream tooling (agent tools, CSV streamer)
//  can reason about columns rather than raw bytes.
//
//  What's handled:
//    - Delimiter defaults: `,` for `.csv`, `\t` for `.tsv`.
//    - Double-quoted fields, including `""` escape sequences.
//    - Embedded newlines inside quoted fields.
//    - UTF-8 BOM stripping; UTF-8 first, ISO-Latin-1 fallback.
//    - Header detection via a conservative "first row is non-numeric"
//      heuristic that's easy to override once the agent has context.
//
//  What's NOT handled yet:
//    - Encoding detection beyond BOM — a Windows-1252 file with no BOM
//      decodes as ISO-Latin-1 and may replace some byte sequences.
//    - Escaping via backslashes (non-standard but common in hand-rolled
//      CSVs) — quotes only.
//    - Skipping comment lines (`#foo`) — not in the format.
//

import Foundation

public struct CSVAdapter: DocumentFormatAdapter {
    public let formatId = "csv"

    public init() {}

    public func canHandle(url: URL, uti: String?) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "csv" || ext == "tsv"
    }

    public func parse(url: URL, sizeLimit: Int64) async throws -> StructuredDocument {
        let fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        if sizeLimit > 0, fileSize > sizeLimit {
            throw DocumentAdapterError.sizeLimitExceeded(actual: fileSize, limit: sizeLimit)
        }

        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw DocumentAdapterError.readFailed(underlying: error.localizedDescription)
        }

        let decoded = Self.decode(data)
        guard !decoded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentAdapterError.emptyContent
        }

        let delimiter: Character = url.pathExtension.lowercased() == "tsv" ? "\t" : ","
        let parsed = CSVParser.parseAll(text: decoded.text, delimiter: delimiter)
        let lineEnding = Self.detectLineEnding(decoded.text)
        let (header, body) = Self.detectHeader(parsed)

        let table = CSVTable(
            delimiter: delimiter,
            encoding: decoded.encoding,
            lineEnding: lineEnding,
            header: header,
            records: body
        )

        return StructuredDocument(
            formatId: formatId,
            filename: url.lastPathComponent,
            fileSize: fileSize,
            representation: AnyStructuredRepresentation(formatId: formatId, underlying: table),
            textFallback: Self.renderTextFallback(table: table)
        )
    }

    // MARK: - Decode

    /// Decodes the raw file bytes as a `String`, stripping any UTF-8 BOM,
    /// and reports which encoding actually worked so callers can preserve
    /// it on re-emit.
    static func decode(_ data: Data) -> (text: String, encoding: String.Encoding) {
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            let stripped = data.subdata(in: 3 ..< data.count)
            return (String(data: stripped, encoding: .utf8) ?? "", .utf8)
        }
        if let utf8 = String(data: data, encoding: .utf8) {
            return (utf8, .utf8)
        }
        if let latin1 = String(data: data, encoding: .isoLatin1) {
            return (latin1, .isoLatin1)
        }
        return ("", .utf8)
    }

    // MARK: - Line ending + header

    static func detectLineEnding(_ text: String) -> CSVTable.LineEnding {
        for scalar in text.unicodeScalars {
            if scalar == "\r" { return .crlf }  // we'll refine below
            if scalar == "\n" { return .lf }
        }
        return .lf
    }

    /// Heuristic: treat the first row as a header when at least one of
    /// its cells contains non-numeric text. Empty files return (nil, []).
    static func detectHeader(_ rows: [[String]]) -> (header: [String]?, body: [[String]]) {
        guard let first = rows.first else { return (nil, []) }
        let anyNonNumeric = first.contains { cell in
            !cell.isEmpty && Double(cell.trimmingCharacters(in: .whitespaces)) == nil
        }
        if anyNonNumeric, rows.count > 1 {
            return (first, Array(rows.dropFirst()))
        }
        return (nil, rows)
    }

    // MARK: - Text fallback

    static func renderTextFallback(table: CSVTable) -> String {
        var out: [String] = []
        if let header = table.header {
            out.append(header.joined(separator: " | "))
            out.append(String(repeating: "-", count: min(header.joined(separator: " | ").count, 80)))
        }
        for row in table.records.prefix(200) {
            out.append(row.joined(separator: " | "))
        }
        if table.records.count > 200 {
            out.append("… (\(table.records.count - 200) more rows)")
        }
        return out.joined(separator: "\n")
    }
}
