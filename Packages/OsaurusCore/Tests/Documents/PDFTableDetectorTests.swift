//
//  PDFTableDetectorTests.swift
//  osaurusTests
//
//  Layout-aware table extraction coverage for `PDFAdapter`. The detector
//  stages (`clusterRows`, `cellsForRow`, `groupConsecutiveTabularRows`,
//  and the pure-function `detect(glyphs:)`) are exercised with
//  synthesised `PDFGlyph` grids — Core Graphics-generated test PDFs
//  report character bounds that span trailing whitespace, which hides
//  the real column gaps and would make end-to-end fixtures unreliable.
//  An integration test below still verifies the adapter wraps everything
//  into a `PDFDocumentRepresentation` and preserves the flat text fallback.
//

import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import OsaurusCore

@Suite("PDFAdapter table extraction")
struct PDFTableDetectorTests {

    // MARK: - Algorithm: row clustering

    @Test func clusterRows_groupsByYTolerance() {
        // Two rows at y=120 (higher on page, emitted first) and y=100.
        // Within each row the glyphs are within 1pt of each other
        // vertically (rowTolerance = 3).
        let glyphs: [PDFGlyph] = [
            Self.glyph("A", x: 10, y: 100),
            Self.glyph("B", x: 30, y: 100.5),
            Self.glyph("C", x: 50, y: 100),
            Self.glyph("D", x: 10, y: 120),
            Self.glyph("E", x: 30, y: 120.5),
        ]
        let rows = PDFTableDetector.clusterRows(glyphs)
        #expect(rows.count == 2)
        // Top of page first (higher PDF y).
        #expect(rows.first?.map(\.scalar) == ["D", "E"])
        #expect(rows.last?.map(\.scalar) == ["A", "B", "C"])
    }

    @Test func clusterRows_sortsWithinRowByX() {
        // Glyphs arrive in scrambled x order — the clusterer must sort.
        let glyphs: [PDFGlyph] = [
            Self.glyph("C", x: 100, y: 50),
            Self.glyph("A", x: 10, y: 50),
            Self.glyph("B", x: 60, y: 50),
        ]
        let rows = PDFTableDetector.clusterRows(glyphs)
        #expect(rows.first?.map(\.scalar) == ["A", "B", "C"])
    }

    // MARK: - Algorithm: row → cells

    @Test func cellsForRow_splitsOnWideGap() {
        // Three 10pt characters per column with ~50pt column gaps —
        // well above the 8pt threshold.
        let row: [PDFGlyph] = [
            Self.glyph("A", x: 10, y: 0, width: 6),
            Self.glyph("a", x: 16, y: 0, width: 6),
            Self.glyph("B", x: 60, y: 0, width: 6),
            Self.glyph("b", x: 66, y: 0, width: 6),
            Self.glyph("C", x: 110, y: 0, width: 6),
        ]
        let cells = PDFTableDetector.cellsForRow(row)
        #expect(cells == ["Aa", "Bb", "C"])
    }

    @Test func cellsForRow_wordsInSameCellStayTogether() {
        // "Net Revenue" inside a single cell. The tiny single-space gap
        // (~3pt) is filtered upstream; even if it leaked through, it's
        // below the 8pt column threshold.
        let row: [PDFGlyph] = [
            Self.glyph("N", x: 10, y: 0, width: 6),
            Self.glyph("e", x: 16, y: 0, width: 6),
            Self.glyph("t", x: 22, y: 0, width: 6),
            Self.glyph("R", x: 30, y: 0, width: 6),  // 2pt gap where the space was
            Self.glyph("e", x: 36, y: 0, width: 6),
            Self.glyph("v", x: 42, y: 0, width: 6),
        ]
        let cells = PDFTableDetector.cellsForRow(row)
        #expect(cells == ["NetRev"])
    }

    @Test func cellsForRow_singleGlyphReturnsSingleCell() {
        let row: [PDFGlyph] = [Self.glyph("X", x: 0, y: 0)]
        #expect(PDFTableDetector.cellsForRow(row) == ["X"])
    }

    // MARK: - Algorithm: tabular grouping

    @Test func groupConsecutive_collectsMultiCellRunsIntoOneTable() {
        let rows: [[String]] = [
            ["Header1", "Header2"],
            ["a", "1"],
            ["b", "2"],
        ]
        let tables = PDFTableDetector.groupConsecutiveTabularRows(rows)
        #expect(tables.count == 1)
        #expect(tables.first?.rowCount == 3)
    }

    @Test func groupConsecutive_splitsAcrossSingleCellBreaks() {
        // Prose row in the middle cuts the table in two.
        let rows: [[String]] = [
            ["A", "1"],
            ["B", "2"],
            ["paragraph"],
            ["C", "3"],
            ["D", "4"],
        ]
        let tables = PDFTableDetector.groupConsecutiveTabularRows(rows)
        #expect(tables.count == 2)
        #expect(tables[0].rowCount == 2)
        #expect(tables[1].rowCount == 2)
    }

    @Test func groupConsecutive_dropsIsolatedSingleTabularRows() {
        // One tabular row on its own (form-field style: "Invoice No. 1234")
        // shouldn't surface as a "table".
        let rows: [[String]] = [
            ["Invoice", "No.", "1234"]
        ]
        let tables = PDFTableDetector.groupConsecutiveTabularRows(rows)
        #expect(tables.isEmpty)
    }

    @Test func groupConsecutive_emptyInputProducesEmptyOutput() {
        #expect(PDFTableDetector.groupConsecutiveTabularRows([]).isEmpty)
    }

    // MARK: - Algorithm: end-to-end on synthetic glyphs

    @Test func detect_endToEndSyntheticGrid() {
        // 3×3 grid at y = 100 / 80 / 60 with 50pt column gaps.
        var glyphs: [PDFGlyph] = []
        let yCoords: [CGFloat] = [100, 80, 60]
        let xCoords: [CGFloat] = [10, 60, 110]
        let data = [
            ["I", "Q", "P"],  // Header
            ["a", "1", "9"],
            ["b", "2", "8"],
        ]
        for (rowIdx, row) in data.enumerated() {
            for (colIdx, ch) in row.enumerated() {
                glyphs.append(
                    Self.glyph(Character(ch), x: xCoords[colIdx], y: yCoords[rowIdx], width: 6)
                )
            }
        }
        let tables = PDFTableDetector.detect(glyphs: glyphs)
        #expect(tables.count == 1)
        #expect(tables.first?.rowCount == 3)
        #expect(tables.first?.columnCount == 3)
        #expect(tables.first?.rows.first == ["I", "Q", "P"])
    }

    // MARK: - Integration: adapter contract

    @Test func parse_emitsPDFDocumentRepresentationWithTextFallback() async throws {
        let url = try Self.writeHelloPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try await PDFAdapter().parse(url: url, sizeLimit: 0)
        guard let repr = document.representation.underlying as? PDFDocumentRepresentation else {
            Issue.record("representation was not a PDFDocumentRepresentation")
            return
        }
        #expect(repr.pageCount == 1)
        #expect(repr.pages.first?.pageNumber == 1)
        #expect(document.textFallback.contains("Hello"))
    }

    @Test func parse_propagatesEmptyContentForBlankPDF() async throws {
        let url = try Self.writeBlankPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: DocumentAdapterError.self) {
            _ = try await PDFAdapter().parse(url: url, sizeLimit: 0)
        }
    }

    // MARK: - Fixtures

    private static func glyph(
        _ scalar: Character,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat = 5,
        height: CGFloat = 10
    ) -> PDFGlyph {
        PDFGlyph(scalar: scalar, rect: CGRect(x: x, y: y, width: width, height: height))
    }

    private static func writeHelloPDF() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-pdftable-hello-\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 200)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw WriterError.contextCreationFailed
        }
        ctx.beginPDFPage(nil)
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        NSAttributedString(string: "Hello PDF", attributes: [.font: NSFont.systemFont(ofSize: 14)])
            .draw(at: NSPoint(x: 20, y: 100))
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    private static func writeBlankPDF() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-pdftable-blank-\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 100, height: 100)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw WriterError.contextCreationFailed
        }
        ctx.beginPDFPage(nil)
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    private enum WriterError: Error { case contextCreationFailed }
}
