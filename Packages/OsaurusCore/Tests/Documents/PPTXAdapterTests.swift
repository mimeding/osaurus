//
//  PPTXAdapterTests.swift
//  osaurusTests
//
//  Generates tiny OpenXML packages in temp directories so the repository
//  does not carry binary PPTX fixtures.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("PPTXAdapter")
struct PPTXAdapterTests {
    @Test func canHandle_acceptsPPTXExtensionAndUTI() {
        let adapter = PPTXAdapter()

        #expect(adapter.canHandle(url: URL(fileURLWithPath: "/tmp/deck.pptx"), uti: nil))
        #expect(
            adapter.canHandle(
                url: URL(fileURLWithPath: "/tmp/deck"),
                uti: "org.openxmlformats.presentationml.presentation"
            )
        )
        #expect(!adapter.canHandle(url: URL(fileURLWithPath: "/tmp/deck.ppt"), uti: nil))
        #expect(!adapter.canHandle(url: URL(fileURLWithPath: "/tmp/deck.docx"), uti: nil))
    }

    @Test func parse_extractsSlideText() async throws {
        let fixture = try makePPTXFixture(
            slides: [
                1: ["Quarterly Review", "Revenue & retention", "Next steps"],
                2: ["Appendix", "Churn by segment"],
            ]
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let document = try await PPTXAdapter().parse(url: fixture.url, sizeLimit: 50_000)
        let presentation = try #require(document.representation.underlying as? PresentationDocument)

        #expect(document.fileSize < 50_000)
        #expect(presentation.sourceProvenance.origin == .file)
        #expect(presentation.slides.count == 2)
        #expect(presentation.slides[0].number == 1)
        #expect(presentation.slides[0].layout == .titleAndContent)
        #expect(
            presentation.slides[0].elements.first
                == .title(
                    PresentationText(
                        text: "Quarterly Review",
                        sourceProvenance: SourceProvenance(
                            origin: .pptxSlide(1),
                            sourceName: "ppt/slides/slide1.xml"
                        )
                    )
                )
        )
        #expect(document.textFallback.contains("Revenue & retention"))
        #expect(document.textFallback.contains("Churn by segment"))
    }

    @Test func parse_extractsSpeakerNotes() async throws {
        let fixture = try makePPTXFixture(
            slides: [1: ["Launch Plan", "Rollout phases"]],
            notes: [1: ["Mention pilot customers", "Pause for questions"]]
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let document = try await PPTXAdapter().parse(url: fixture.url, sizeLimit: 50_000)
        let presentation = try #require(document.representation.underlying as? PresentationDocument)

        #expect(presentation.slides.first?.speakerNotes?.text == "Mention pilot customers\nPause for questions")
        #expect(presentation.slides.first?.speakerNotes?.sourceProvenance.origin == .pptxNotesSlide(1))
        #expect(document.textFallback.contains("Speaker notes:"))
        #expect(document.textFallback.contains("Pause for questions"))
    }

    @Test func parse_refusesFilesAboveSizeLimit() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("too-large.pptx")
        try Data(repeating: 0x41, count: 16).write(to: url)

        do {
            _ = try await PPTXAdapter().parse(url: url, sizeLimit: 15)
            Issue.record("expected sizeLimitExceeded")
        } catch DocumentAdapterError.sizeLimitExceeded(let actual, let limit) {
            #expect(actual == 16)
            #expect(limit == 15)
        } catch {
            Issue.record("expected sizeLimitExceeded, got \(error)")
        }
    }

    @Test func parse_corruptZipThrowsReadFailed() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("corrupt.pptx")
        try Data("not a zip archive".utf8).write(to: url)

        do {
            _ = try await PPTXAdapter().parse(url: url, sizeLimit: 50_000)
            Issue.record("expected readFailed")
        } catch DocumentAdapterError.readFailed(let underlying) {
            #expect(!underlying.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } catch {
            Issue.record("expected readFailed, got \(error)")
        }
    }

    // MARK: - Fixture generation

    private func makePPTXFixture(
        slides: [Int: [String]],
        notes: [Int: [String]] = [:]
    ) throws -> (root: URL, url: URL) {
        let root = try makeTempDirectory()
        let packageRoot = root.appendingPathComponent("package", isDirectory: true)
        let pptRoot = packageRoot.appendingPathComponent("ppt", isDirectory: true)
        let slidesRoot = pptRoot.appendingPathComponent("slides", isDirectory: true)
        let notesRoot = pptRoot.appendingPathComponent("notesSlides", isDirectory: true)

        try FileManager.default.createDirectory(at: slidesRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: notesRoot, withIntermediateDirectories: true)

        try contentTypesXML.write(
            to: packageRoot.appendingPathComponent("[Content_Types].xml"),
            atomically: true,
            encoding: .utf8
        )

        for (number, paragraphs) in slides {
            try slideXML(paragraphs).write(
                to: slidesRoot.appendingPathComponent("slide\(number).xml"),
                atomically: true,
                encoding: .utf8
            )
        }

        for (number, paragraphs) in notes {
            try notesXML(paragraphs).write(
                to: notesRoot.appendingPathComponent("notesSlide\(number).xml"),
                atomically: true,
                encoding: .utf8
            )
        }

        let url = root.appendingPathComponent("fixture.pptx")
        try zipDirectory(packageRoot, to: url)
        return (root, url)
    }

    private var contentTypesXML: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="xml" ContentType="application/xml"/>
        </Types>
        """
    }

    private func slideXML(_ paragraphs: [String]) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
          <p:cSld>
            <p:spTree>
              \(paragraphs.map(textShapeXML).joined(separator: "\n"))
            </p:spTree>
          </p:cSld>
        </p:sld>
        """
    }

    private func notesXML(_ paragraphs: [String]) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <p:notes xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
          <p:cSld>
            <p:spTree>
              \(paragraphs.map(textShapeXML).joined(separator: "\n"))
            </p:spTree>
          </p:cSld>
        </p:notes>
        """
    }

    private func textShapeXML(_ text: String) -> String {
        """
        <p:sp>
          <p:txBody>
            <a:p>
              <a:r><a:t>\(escapeXML(text))</a:t></a:r>
            </a:p>
          </p:txBody>
        </p:sp>
        """
    }

    private func escapeXML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-pptx-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func zipDirectory(_ source: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = source
        process.arguments = ["-r", "-q", destination.path, "."]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "PPTXAdapterTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "zip failed: \(message)"]
            )
        }
    }
}
