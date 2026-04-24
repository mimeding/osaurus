//
//  StructuredDocumentAttachmentTests.swift
//  osaurusTests
//
//  Covers the new `Attachment.Kind.structuredDocument` case end to end:
//    - accessors (isDocument, filename, documentContent, structuredDocument,
//      estimatedTokens, fileIcon) behave identically to `.document(…)`
//      for consumers that only need the text view.
//    - Codable round-trip serialises `.structuredDocument` as the
//      legacy `.document` wire shape so persisted history stays
//      readable by older builds.
//    - DocumentParser.parseAll emits `.structuredDocument` for formats
//      whose adapter produces a typed representation (XLSX, CSV) and
//      stays on `.document` for PlainText / PDF-text / RichDocument
//      adapters that surface only a text fallback.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Attachment.Kind.structuredDocument")
struct StructuredDocumentAttachmentTests {

    // MARK: - Accessors

    @Test func isDocument_returnsTrueForBothCases() {
        let legacy = Attachment.document(filename: "a.txt", content: "hi", fileSize: 2)
        let structured = Attachment.structuredDocument(Self.sampleStructured())
        #expect(legacy.isDocument)
        #expect(structured.isDocument)
        #expect(legacy.isImage == false)
        #expect(structured.isImage == false)
    }

    @Test func filenameAndContent_bridgeStructured() {
        let doc = Self.sampleStructured(filename: "q4.xlsx", text: "Revenue totals")
        let attachment = Attachment.structuredDocument(doc)
        #expect(attachment.filename == "q4.xlsx")
        #expect(attachment.documentContent == "Revenue totals")
    }

    @Test func structuredDocument_onlyPresentForStructuredCase() {
        let legacy = Attachment.document(filename: "a.txt", content: "hi", fileSize: 2)
        let structured = Attachment.structuredDocument(Self.sampleStructured())
        #expect(legacy.structuredDocument == nil)
        #expect(structured.structuredDocument?.formatId == "xlsx")
    }

    @Test func fileIcon_usesTableIconForXLSX() {
        let doc = Self.sampleStructured(filename: "report.xlsx")
        #expect(Attachment.structuredDocument(doc).fileIcon == "tablecells")
    }

    @Test func estimatedTokens_usesTextFallbackLength() {
        let body = String(repeating: "a", count: 400)
        let doc = Self.sampleStructured(text: body)
        let attachment = Attachment.structuredDocument(doc)
        #expect(attachment.estimatedTokens == body.count / 4)
    }

    // MARK: - Codable

    @Test func encoding_downgradesStructuredToLegacyWireShape() throws {
        let doc = Self.sampleStructured(
            filename: "payroll.xlsx",
            text: "wire-format body",
            fileSize: 512
        )
        let encoded = try JSONEncoder().encode(Attachment.structuredDocument(doc).kind)
        let obj = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]

        #expect(obj["type"] as? String == "document")
        #expect(obj["filename"] as? String == "payroll.xlsx")
        #expect(obj["content"] as? String == "wire-format body")
        #expect(obj["fileSize"] as? Int == 512)
    }

    @Test func decoding_structuredPersistedHistoryReadsAsLegacyDocument() throws {
        // Simulate a persisted row written by the new build, re-read by
        // any build that understands the `document` case. Decoding
        // preserves the text view even though the typed representation
        // is intentionally not round-tripped.
        let original = Attachment.structuredDocument(
            Self.sampleStructured(filename: "q4.xlsx", text: "body")
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Attachment.self, from: data)

        #expect(decoded.isDocument)
        #expect(decoded.filename == "q4.xlsx")
        #expect(decoded.documentContent == "body")
        #expect(decoded.structuredDocument == nil)
    }

    // MARK: - DocumentParser emission

    @Test func parseAll_emitsStructuredForXLSX() throws {
        // Uses the checked-in sample.xlsx fixture from PR 5's resources.
        guard
            let bundled = Bundle.module.url(
                forResource: "sample",
                withExtension: "xlsx",
                subdirectory: "Fixtures/xlsx"
            )
        else {
            Issue.record("sample.xlsx fixture is missing")
            return
        }

        // Ensure the XLSXAdapter is registered for this test run.
        let registry = DocumentFormatRegistry.shared
        DocumentAdaptersBootstrap.registerBuiltIns(registry: registry)

        let attachments = try DocumentParser.parseAll(url: bundled)
        #expect(attachments.count == 1)
        guard let attachment = attachments.first else { return }

        // Structured path — accessors read typed fields.
        #expect(attachment.structuredDocument?.formatId == "xlsx")
        if case .structuredDocument(let doc) = attachment.kind {
            #expect(doc.representation.underlying is Workbook)
        } else {
            Issue.record("XLSX attachment was not emitted as .structuredDocument")
        }
    }

    @Test func parseAll_emitsLegacyDocumentForPlainText() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-sd-plain-\(UUID().uuidString).md")
        try "# Hello\n\nBody text\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        DocumentAdaptersBootstrap.registerBuiltIns()

        let attachments = try DocumentParser.parseAll(url: url)
        #expect(attachments.count == 1)
        if case .document = attachments.first?.kind {
            // Expected — plaintext stays on the legacy case.
        } else {
            Issue.record(
                "plaintext attachment should have emitted .document, got \(String(describing: attachments.first?.kind))"
            )
        }
    }

    // MARK: - Fixtures

    private static func sampleStructured(
        formatId: String = "xlsx",
        filename: String = "sample.xlsx",
        text: String = "sample text",
        fileSize: Int64 = 128
    ) -> StructuredDocument {
        StructuredDocument(
            formatId: formatId,
            filename: filename,
            fileSize: fileSize,
            representation: AnyStructuredRepresentation(
                formatId: formatId,
                underlying: PlainTextRepresentation(text: text)
            ),
            textFallback: text
        )
    }
}
