//
//  PDFAdapter.swift
//  osaurus
//
//  Text-layer extraction plus layout-aware table detection for PDFs.
//
//  The adapter produces a `PDFDocumentRepresentation` carrying one
//  `PDFPageRepresentation` per text-bearing page. Each page retains the
//  plain extracted text (byte-identical to the legacy PR-3 behaviour)
//  and — when the layout heuristic finds them — a list of `PDFTable`
//  regions. The `textFallback` on the returned `StructuredDocument`
//  stays flat for chat-attachment display.
//
//  Image-only PDFs still throw `.emptyContent` so the `DocumentParser`
//  shim can fall through to the legacy image-render path; moving that
//  path onto the adapter surface is deliberately out of scope here.
//
//  Detection strategy (`PDFTableDetector` below):
//    1. Enumerate each page's characters, capturing `(char, x, y, width)`
//       from `PDFPage.characterBounds(at:)`.
//    2. Cluster glyphs into rows by y-coordinate tolerance.
//    3. Within each row, split into cells wherever the inter-glyph gap
//       exceeds the configured threshold.
//    4. Collect consecutive multi-cell rows as a table; single-cell rows
//       are treated as prose and end the current table.
//

import Foundation
import PDFKit

public struct PDFAdapter: DocumentFormatAdapter {
    public let formatId = "pdf"

    public init() {}

    public func canHandle(url: URL, uti: String?) -> Bool {
        url.pathExtension.lowercased() == "pdf"
    }

    public func parse(url: URL, sizeLimit: Int64) async throws -> StructuredDocument {
        let fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        if sizeLimit > 0, fileSize > sizeLimit {
            throw DocumentAdapterError.sizeLimitExceeded(actual: fileSize, limit: sizeLimit)
        }

        guard let document = PDFDocument(url: url) else {
            throw DocumentAdapterError.readFailed(underlying: "PDFKit could not open document")
        }

        var pages: [PDFPageRepresentation] = []
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index), let text = page.string else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let tables = PDFTableDetector.detect(on: page, text: text)
            pages.append(
                PDFPageRepresentation(pageNumber: index + 1, text: text, tables: tables)
            )
        }

        guard !pages.isEmpty else {
            // No text layer on any page — let the shim fall through to
            // the legacy image-render fallback. Don't claim a result we
            // can't produce.
            throw DocumentAdapterError.emptyContent
        }

        let flatText = pages.map(\.text).joined(separator: "\n\n")
        let truncated = PlainTextAdapter.applyCharacterCap(flatText)

        return StructuredDocument(
            formatId: formatId,
            filename: url.lastPathComponent,
            fileSize: fileSize,
            representation: AnyStructuredRepresentation(
                formatId: formatId,
                underlying: PDFDocumentRepresentation(pages: pages)
            ),
            textFallback: truncated
        )
    }
}

// MARK: - Table detector

/// Glyph record used by the detector. Exposed internally so tests can
/// feed synthetic character grids in without going through PDFKit —
/// Core Graphics-generated PDFs report character bounds that span
/// trailing whitespace, which masks the real column gaps, so relying
/// only on end-to-end PDF fixtures makes the algorithm hard to pin.
struct PDFGlyph: Sendable, Equatable {
    let scalar: Character
    let rect: CGRect
}

/// Layout-aware table detector. Pure function over a `PDFPage` at the
/// top, with the inner stages (`clusterRows`, `cellsForRow`, grouping)
/// internal so the heuristic can be unit-tested without PDFKit.
enum PDFTableDetector {

    /// Tunables chosen for common business PDFs (10-12pt body text).
    /// `rowTolerance` is how far two characters' y-baselines can differ
    /// and still be on the same row; `columnGap` is the inter-glyph
    /// distance that must be exceeded before we declare a cell boundary.
    /// Both are in PDF points. `columnGap` is set above typical single-
    /// space width (~3-4pt at 12pt body) so "Widget Pro" stays one cell
    /// but "Widget      7" splits — the heuristic trades some recall on
    /// very tightly-spaced tables for precision on prose.
    static let rowTolerance: CGFloat = 3.0
    static let columnGap: CGFloat = 8.0

    static func detect(on page: PDFPage, text: String) -> [PDFTable] {
        let glyphs = collectGlyphs(from: page, text: text)
        return detect(glyphs: glyphs)
    }

    /// Pure-function variant used by tests and reachable without PDFKit.
    static func detect(glyphs: [PDFGlyph]) -> [PDFTable] {
        let rows = clusterRows(glyphs)
        let cellRows = rows.map { cellsForRow($0) }
        return groupConsecutiveTabularRows(cellRows)
    }

    // MARK: Glyph collection

    private struct RowCluster {
        var y: CGFloat
        var glyphs: [PDFGlyph]
    }

    private static func collectGlyphs(from page: PDFPage, text: String) -> [PDFGlyph] {
        // `characterBounds(at:)` uses UTF-16 offsets, so we index into
        // `text.utf16` and map back to characters for the cell content.
        //
        // Space / tab / newline characters carry bounds that span the
        // whitespace they introduce — including column gaps many points
        // wide — so including them in the glyph stream hides the gap
        // between "Item" and "Qty" (see e.g. PDFKit on a 3-column PDF,
        // where the space glyph between columns reports width ≈ 95pt).
        // Dropping whitespace glyphs turns "gap between meaningful
        // characters" into the real signal we cluster on.
        var glyphs: [PDFGlyph] = []
        glyphs.reserveCapacity(text.utf16.count)
        var index = 0
        for scalar in text {
            let length = scalar.utf16.count
            defer { index += length }
            if scalar.isWhitespace { continue }
            let bounds = page.characterBounds(at: index)
            if bounds.width > 0 || bounds.height > 0 {
                glyphs.append(PDFGlyph(scalar: scalar, rect: bounds))
            }
        }
        return glyphs
    }

    // MARK: Row clustering

    static func clusterRows(_ glyphs: [PDFGlyph]) -> [[PDFGlyph]] {
        // Sort by y descending — PDF coordinates have origin at bottom-
        // left, so top-of-page rows carry the highest y values.
        let sorted = glyphs.sorted { lhs, rhs in
            let ly = lhs.rect.midY
            let ry = rhs.rect.midY
            if abs(ly - ry) < rowTolerance { return lhs.rect.minX < rhs.rect.minX }
            return ly > ry
        }

        var clusters: [RowCluster] = []
        for glyph in sorted {
            let y = glyph.rect.midY
            if let last = clusters.last, abs(last.y - y) < rowTolerance {
                var updated = last
                updated.glyphs.append(glyph)
                clusters[clusters.count - 1] = updated
            } else {
                clusters.append(RowCluster(y: y, glyphs: [glyph]))
            }
        }

        return clusters.map { cluster in
            cluster.glyphs.sorted { $0.rect.minX < $1.rect.minX }
        }
    }

    // MARK: Row → cells

    static func cellsForRow(_ row: [PDFGlyph]) -> [String] {
        guard !row.isEmpty else { return [] }

        var cells: [String] = []
        var buffer: String = String(row[0].scalar)
        var cursor = row[0].rect.maxX

        for glyph in row.dropFirst() {
            let gap = glyph.rect.minX - cursor
            if gap > columnGap {
                cells.append(buffer.trimmingCharacters(in: .whitespaces))
                buffer = String(glyph.scalar)
            } else {
                buffer.append(glyph.scalar)
            }
            cursor = glyph.rect.maxX
        }
        cells.append(buffer.trimmingCharacters(in: .whitespaces))
        return cells.filter { !$0.isEmpty }
    }

    // MARK: Tabular row grouping

    static func groupConsecutiveTabularRows(_ rows: [[String]]) -> [PDFTable] {
        var tables: [PDFTable] = []
        var current: [[String]] = []

        for row in rows {
            if row.count >= 2 {
                current.append(row)
            } else if !current.isEmpty {
                tables.append(PDFTable(rows: current))
                current = []
            }
        }
        if !current.isEmpty {
            tables.append(PDFTable(rows: current))
        }
        // Single-row "tables" are almost always form lines ("Invoice: 1234"),
        // not real tables — drop them so downstream consumers don't have to.
        return tables.filter { $0.rows.count >= 2 }
    }
}
