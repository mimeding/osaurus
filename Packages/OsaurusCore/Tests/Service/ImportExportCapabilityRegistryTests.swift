import Foundation
import PDFKit
import Testing

@testable import OsaurusCore

struct ImportExportCapabilityRegistryTests {

    @Test func resolvesDelimitedTextImporterForCSV() {
        let url = URL(fileURLWithPath: "/tmp/sample.csv")

        let resolution = ImportExportCapabilityRegistry.shared.resolveImport(url: url)

        #expect(resolution?.metadata.id == "builtin.delimited-text-attachments")
        #expect(resolution?.matchedExtension == "csv")
        #expect(resolution?.metadata.roles.contains(.import) == true)
    }

    @Test func resolvesMarkdownImporterForMD() {
        let url = URL(fileURLWithPath: "/tmp/README.md")

        let resolution = ImportExportCapabilityRegistry.shared.resolveImport(url: url)

        #expect(resolution?.metadata.id == "builtin.markdown-attachments")
        #expect(resolution?.matchedExtension == "md")
        #expect(resolution?.metadata.roles.contains(.export) == true)
        #expect(resolution?.metadata.isScaffoldOnly == false)
    }

    @Test func registersScaffoldOnlyArtifactExportAndValidateMetadata() {
        let capabilities = ImportExportCapabilityRegistry.shared.capabilities(for: .export)
        let passthrough = capabilities.first { $0.id == "builtin.generic-artifact-passthrough" }

        #expect(passthrough != nil)
        #expect(passthrough?.roles.contains(.validate) == true)
        #expect(passthrough?.isScaffoldOnly == true)

        let csv = capabilities.first { $0.id == "builtin.delimited-text-attachments" }
        let markdown = capabilities.first { $0.id == "builtin.markdown-attachments" }
        let pdf = capabilities.first { $0.id == "builtin.pdf-attachments" }
        #expect(csv?.isScaffoldOnly == false)
        #expect(markdown?.isScaffoldOnly == false)
        #expect(pdf?.isScaffoldOnly == false)
    }

    @Test func attachmentIconsResolveThroughRegistryMetadata() {
        let attachment = Attachment.document(filename: "table.csv", content: "a,b", fileSize: 3)
        let markdown = Attachment.document(filename: "README.md", content: "# Title", fileSize: 7)

        #expect(attachment.fileIcon == "tablecells")
        #expect(markdown.fileIcon == "text.document")
    }

    @Test func exportOptionsPreferNativeMarkdownFormatAndExposePDF() throws {
        let attachment = Attachment.document(filename: "README.md", content: "# Title\nBody", fileSize: 12)

        let options = ImportExportExportOptions.options(for: .attachment(attachment))

        #expect(options.map(\.formatExtension) == ["md", "pdf"])
        #expect(ImportExportExportOptions.defaultOption(for: .attachment(attachment))?.formatExtension == "md")
        let pdf = try #require(options.first { $0.formatExtension == "pdf" })
        #expect(ImportExportExportOptions.suggestedFilename(for: .attachment(attachment), option: pdf) == "README.pdf")
    }

    @Test func exportOptionsExposeMarkdownForRawTextSources() {
        let options = ImportExportExportOptions.options(
            for: .text(content: "# Notes", suggestedFilename: "../unsafe/notes.md")
        )

        #expect(options.map(\.formatExtension) == ["md", "pdf"])
        #expect(
            ImportExportExportOptions.suggestedFilename(
                for: .text(content: "# Notes", suggestedFilename: "../unsafe/notes.md"),
                option: ImportExportExportOption(formatExtension: "md", displayName: "Markdown")
            ) == "notes.md"
        )
    }

    @Test func exportOptionsPreferNativeDelimitedFormatAndExposePDF() throws {
        let attachment = Attachment.document(filename: "table.csv", content: "a,b\n1,2", fileSize: 7)

        let options = ImportExportExportOptions.options(for: .attachment(attachment))

        #expect(options.map(\.formatExtension) == ["csv", "pdf"])
        #expect(ImportExportExportOptions.defaultOption(for: .attachment(attachment))?.formatExtension == "csv")
        let pdf = try #require(options.first { $0.formatExtension == "pdf" })
        #expect(ImportExportExportOptions.suggestedFilename(for: .attachment(attachment), option: pdf) == "table.pdf")
    }

    @Test func exportOptionsPreferExistingPDFArtifact() {
        let artifact = SharedArtifact(
            contextId: "registry-export-options",
            contextType: .chat,
            filename: "analysis.pdf",
            mimeType: "application/pdf",
            fileSize: 12,
            hostPath: "/tmp/analysis.pdf"
        )

        let options = ImportExportExportOptions.options(for: .artifact(artifact))

        #expect(options.map(\.formatExtension) == ["pdf"])
        #expect(ImportExportExportOptions.defaultOption(for: .artifact(artifact))?.formatExtension == "pdf")
        #expect(
            ImportExportExportOptions.suggestedFilename(
                for: .artifact(artifact),
                option: ImportExportExportOption(formatExtension: "pdf", displayName: "PDF")
            ) == "analysis.pdf"
        )
    }

    @Test func exportOptionsRejectDirectoryArtifacts() {
        let artifact = SharedArtifact(
            contextId: "registry-export-options",
            contextType: .chat,
            filename: "site",
            mimeType: "inode/directory",
            fileSize: 0,
            hostPath: "/tmp/site",
            isDirectory: true
        )

        #expect(ImportExportExportOptions.options(for: .artifact(artifact)).isEmpty)
    }

    @Test func unknownFormatsRemainUnsupported() {
        let url = URL(fileURLWithPath: "/tmp/workbook.xlsx")

        #expect(DocumentParser.canParse(url: url) == false)
        #expect(ImportExportCapabilityRegistry.shared.resolveImport(url: url) == nil)

        do {
            _ = try DocumentParser.parseAll(url: url)
            Issue.record("Expected unsupported format error for .xlsx")
        } catch let error as DocumentParser.ParseError {
            switch error {
            case .unsupportedFormat(let ext):
                #expect(ext == "xlsx")
            default:
                Issue.record("Expected unsupportedFormat, got \(error)")
            }
        } catch {
            Issue.record("Expected DocumentParser.ParseError, got \(error)")
        }
    }

    @Test func exportsAttachmentAsCSVAndImportsItBackThroughRegistry() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let content = "name,value\r\nalpha,1\r\nbeta,2\r\n"
        let attachment = Attachment.document(filename: "table.csv", content: content, fileSize: content.utf8.count)
        let destination = directory.appendingPathComponent("roundtrip.csv")

        let result = try ImportExportCapabilityRegistry.shared.export(
            source: .attachment(attachment),
            to: destination
        )

        #expect(result.outputURL.path == destination.standardizedFileURL.path)
        let exported = try String(contentsOf: destination, encoding: .utf8)
        #expect(exported == "name,value\nalpha,1\nbeta,2\n")

        let imported = try DocumentParser.parse(url: destination)
        #expect(imported.filename == "roundtrip.csv")
        #expect(imported.documentContent == exported)
    }

    @Test func exportsAttachmentAsMarkdownAndImportsItBackThroughRegistry() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let content = "# Development Notes\r\n\r\n- Chat is the product surface.\r\n- Tools are capabilities.\r\n"
        let attachment = Attachment.document(filename: "notes.md", content: content, fileSize: content.utf8.count)
        let destination = directory.appendingPathComponent("roundtrip.md")

        let result = try ImportExportCapabilityRegistry.shared.export(
            source: .attachment(attachment),
            to: destination
        )

        #expect(result.outputURL.path == destination.standardizedFileURL.path)
        let exported = try String(contentsOf: destination, encoding: .utf8)
        #expect(exported == "# Development Notes\n\n- Chat is the product surface.\n- Tools are capabilities.\n")

        let imported = try DocumentParser.parse(url: destination)
        #expect(imported.filename == "roundtrip.md")
        #expect(imported.documentContent == exported)
    }

    @Test func exportsTextAsMarkdownWithLongExtension() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("summary.markdown")

        let result = try ImportExportCapabilityRegistry.shared.export(
            source: .text(content: "## Summary\r\n\nMaintainer-aligned registry support.", suggestedFilename: "summary.md"),
            to: destination
        )

        #expect(result.outputURL.path == destination.standardizedFileURL.path)
        let exported = try String(contentsOf: destination, encoding: .utf8)
        #expect(exported == "## Summary\n\nMaintainer-aligned registry support.\n")
    }

    @Test func exportsTextAsPDFAndImportsExtractedTextBackThroughRegistry() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("summary.pdf")
        let sourceText = "Quarterly summary\n\nRevenue, margin, and retention improved in the pilot cohort."

        let result = try ImportExportCapabilityRegistry.shared.export(
            source: .text(content: sourceText, suggestedFilename: "summary.txt"),
            to: destination
        )

        #expect(result.outputURL.path == destination.standardizedFileURL.path)
        let document = try #require(PDFDocument(url: destination))
        #expect(document.pageCount >= 1)
        #expect((document.string ?? "").contains("Quarterly summary"))

        let imported = try DocumentParser.parse(url: destination)
        #expect(imported.filename == "summary.pdf")
        #expect(imported.documentContent?.contains("pilot cohort") == true)
    }

    @Test func pdfExportCopiesExistingPDFArtifact() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourcePDF = directory.appendingPathComponent("source.pdf")
        _ = try ImportExportCapabilityRegistry.shared.export(
            source: .text(content: "Existing PDF artifact", suggestedFilename: "source.txt"),
            to: sourcePDF
        )
        let sourceSize = (try FileManager.default.attributesOfItem(atPath: sourcePDF.path)[.size] as? Int) ?? 0
        let artifact = SharedArtifact(
            contextId: "registry-export-test",
            contextType: .chat,
            filename: "source.pdf",
            mimeType: "application/pdf",
            fileSize: sourceSize,
            hostPath: sourcePDF.path
        )
        let destination = directory.appendingPathComponent("copied.pdf")

        _ = try ImportExportCapabilityRegistry.shared.export(source: .artifact(artifact), to: destination)

        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(try Data(contentsOf: sourcePDF) == Data(contentsOf: destination))
    }

    @Test func exportRejectsDestinationExtensionMismatch() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try ImportExportCapabilityRegistry.shared.export(
                source: .text(content: "a,b\n1,2", suggestedFilename: nil),
                to: directory.appendingPathComponent("table.txt"),
                formatExtension: "csv"
            )
            Issue.record("Expected destination extension mismatch")
        } catch let error as ImportExportExportError {
            #expect(error == .destinationExtensionMismatch(expected: "csv", actual: "txt"))
        } catch {
            Issue.record("Expected ImportExportExportError, got \(error)")
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-import-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
