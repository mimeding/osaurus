import Foundation
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

    @Test func registersScaffoldOnlyArtifactExportAndValidateMetadata() {
        let capabilities = ImportExportCapabilityRegistry.shared.capabilities(for: .export)
        let passthrough = capabilities.first { $0.id == "builtin.generic-artifact-passthrough" }

        #expect(passthrough != nil)
        #expect(passthrough?.roles.contains(.validate) == true)
        #expect(passthrough?.isScaffoldOnly == true)
    }

    @Test func attachmentIconsResolveThroughRegistryMetadata() {
        let attachment = Attachment.document(filename: "table.csv", content: "a,b", fileSize: 3)

        #expect(attachment.fileIcon == "tablecells")
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
}
