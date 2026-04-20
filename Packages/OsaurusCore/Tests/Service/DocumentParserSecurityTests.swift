import Foundation
import Testing

@testable import OsaurusCore

struct DocumentParserSecurityTests {

    @Test func parseAll_rejectsOversizedFilesBeforeImport() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-doc-too-large-\(UUID().uuidString).txt")
        let oversizedData = Data(repeating: 0x61, count: DocumentParser.maxFileSizeBytes + 1)
        try oversizedData.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try DocumentParser.parseAll(url: url)
            Issue.record("Expected fileTooLarge for oversized attachment")
        } catch let error as DocumentParser.ParseError {
            switch error {
            case .fileTooLarge:
                break
            default:
                Issue.record("Expected fileTooLarge, got \(error)")
            }
        } catch {
            Issue.record("Expected DocumentParser.ParseError, got \(error)")
        }
    }
}
