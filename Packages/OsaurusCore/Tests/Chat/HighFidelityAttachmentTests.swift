//
//  HighFidelityAttachmentTests.swift
//  OsaurusCoreTests
//
//  Verifies preserved PDF/PPT/PPTX input attachments and plugin context wiring.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct HighFidelityAttachmentTests {

    @Test
    func pptxAttachPreservesOriginalBytesOutsideChatJSON() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(
            "osaurus-high-fidelity-source-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let source = tempDir.appendingPathComponent("deck.pptx")
        let bytes = Data([0x50, 0x4B, 0x03, 0x04, 0x01, 0x02, 0x03])
        try bytes.write(to: source)

        let attachments = try DocumentParser.parseAll(url: source)
        #expect(attachments.count == 1)

        let attachment = try #require(attachments.first)
        #expect(attachment.isPreservedFile)
        #expect(attachment.filename == "deck.pptx")
        #expect(attachment.mimeType == "application/vnd.openxmlformats-officedocument.presentationml.presentation")
        #expect(attachment.hostPath?.hasPrefix(OsaurusPaths.attachmentsDir().path + "/") == true)

        let hostPath = try #require(attachment.hostPath)
        defer { try? fm.removeItem(at: URL(fileURLWithPath: hostPath).deletingLastPathComponent()) }
        #expect(fm.fileExists(atPath: hostPath))
        #expect(try Data(contentsOf: URL(fileURLWithPath: hostPath)) == bytes)

        let encoded = try JSONEncoder().encode(attachment)
        let json = String(decoding: encoded, as: UTF8.self)
        #expect(json.contains("\"type\":\"file\""))
        #expect(json.contains("hostPath"))
        #expect(!json.contains(bytes.base64EncodedString()))
    }

    @Test @MainActor
    func preservedFileManifestIsInjectedIntoUserMessage() {
        let attachment = Attachment.file(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000123")!,
            filename: "sample.pdf",
            mimeType: "application/pdf",
            fileSize: 42,
            hostPath: "/tmp/sample.pdf",
            extractedPreview: "Page 1:\nHello"
        )

        let text = ChatSession.buildUserMessageText(content: "Please summarize this.", attachments: [attachment])

        #expect(text.contains("<attached_files_available_to_tools"))
        #expect(text.contains("id=\"00000000-0000-0000-0000-000000000123\""))
        #expect(text.contains("mime_type=\"application/pdf\""))
        #expect(text.contains("<attached_file_preview"))
        #expect(text.contains("Hello"))
        #expect(text.contains("Please summarize this."))
    }

    @Test @MainActor
    func availableInputFilesCollectsPreservedUserAttachments() {
        let attachment = Attachment.file(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000456")!,
            filename: "deck.pptx",
            mimeType: "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            fileSize: 12,
            hostPath: "/tmp/deck.pptx"
        )
        let turn = ChatTurn(role: .user, content: "edit this", attachments: [attachment])

        let files = ChatSession.availableInputFiles(from: [turn])

        #expect(files.count == 1)
        #expect(files.first?.id == "00000000-0000-0000-0000-000000000456")
        #expect(files.first?.filename == "deck.pptx")
        #expect(files.first?.hostPath == "/tmp/deck.pptx")
    }

    @Test
    func oldDocumentAttachmentStillDecodes() throws {
        let id = UUID().uuidString
        let json = """
            {
              "id": "\(id)",
              "kind": {
                "type": "document",
                "filename": "notes.txt",
                "content": "hello",
                "fileSize": 5
              }
            }
            """
        let decoded = try JSONDecoder().decode(Attachment.self, from: Data(json.utf8))
        #expect(decoded.filename == "notes.txt")
        #expect(decoded.documentContent == "hello")
        #expect(decoded.isDocument)
        #expect(!decoded.isPreservedFile)
    }
}
