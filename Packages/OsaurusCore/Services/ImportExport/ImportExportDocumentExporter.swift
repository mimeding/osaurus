import AppKit
import CoreText
import Foundation
import PDFKit

enum ImportExportExportError: LocalizedError, Equatable {
    case unsupportedFormat(String)
    case unsupportedSource(String)
    case destinationMustBeFileURL
    case destinationExtensionMismatch(expected: String, actual: String)
    case destinationParentMissing(String)
    case destinationIsDirectory(String)
    case emptyContent
    case readFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "Unsupported export format: .\(ext)"
        case .unsupportedSource(let reason):
            return "Unsupported export source: \(reason)"
        case .destinationMustBeFileURL:
            return "Export destination must be a file URL"
        case .destinationExtensionMismatch(let expected, let actual):
            return "Export destination must use .\(expected), not .\(actual)"
        case .destinationParentMissing(let path):
            return "Export destination parent does not exist: \(path)"
        case .destinationIsDirectory(let path):
            return "Export destination is a directory: \(path)"
        case .emptyContent:
            return "Export source is empty"
        case .readFailed(let reason):
            return "Failed to read export source: \(reason)"
        case .writeFailed(let reason):
            return "Failed to write export file: \(reason)"
        }
    }
}

enum ImportExportDocumentExporter {
    static func exportMarkdown(request: ImportExportExportRequest) throws -> ImportExportExportResult {
        let ext = request.normalizedFormatExtension
        guard ["md", "markdown"].contains(ext) else {
            throw ImportExportExportError.unsupportedFormat(ext)
        }
        let destination = try validatedDestination(request.destinationURL, expectedExtension: ext)
        let content = try textContent(from: request.source)
        let normalized = normalizeTextDocument(content)

        do {
            try normalized.write(to: destination, atomically: true, encoding: .utf8)
            return ImportExportExportResult(outputURL: destination)
        } catch {
            throw ImportExportExportError.writeFailed(error.localizedDescription)
        }
    }

    static func exportDelimitedText(request: ImportExportExportRequest) throws -> ImportExportExportResult {
        let ext = request.normalizedFormatExtension
        guard ["csv", "tsv"].contains(ext) else {
            throw ImportExportExportError.unsupportedFormat(ext)
        }
        let destination = try validatedDestination(request.destinationURL, expectedExtension: ext)
        let content = try textContent(from: request.source)
        let normalized = normalizeTextDocument(content)

        do {
            try normalized.write(to: destination, atomically: true, encoding: .utf8)
            return ImportExportExportResult(outputURL: destination)
        } catch {
            throw ImportExportExportError.writeFailed(error.localizedDescription)
        }
    }

    static func exportPDF(request: ImportExportExportRequest) throws -> ImportExportExportResult {
        let ext = request.normalizedFormatExtension
        guard ext == "pdf" else {
            throw ImportExportExportError.unsupportedFormat(ext)
        }
        let destination = try validatedDestination(request.destinationURL, expectedExtension: ext)

        if let existingPDF = try existingPDFURL(from: request.source) {
            do {
                let fm = FileManager.default
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.copyItem(at: existingPDF, to: destination)
                return ImportExportExportResult(outputURL: destination)
            } catch {
                throw ImportExportExportError.writeFailed(error.localizedDescription)
            }
        }

        let content = try textContent(from: request.source)
        try writePDF(text: content, to: destination)
        return ImportExportExportResult(outputURL: destination)
    }

    static func textContent(from source: ImportExportExportSource) throws -> String {
        let text: String
        switch source {
        case .text(let content, _):
            text = content
        case .attachment(let attachment):
            guard let content = attachment.documentContent else {
                throw ImportExportExportError.unsupportedSource("image attachments cannot be exported as text documents")
            }
            text = content
        case .artifact(let artifact):
            if let content = artifact.content {
                text = content
            } else {
                text = try readArtifactText(artifact)
            }
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportExportExportError.emptyContent
        }
        return text
    }

    private static func readArtifactText(_ artifact: SharedArtifact) throws -> String {
        guard !artifact.isDirectory else {
            throw ImportExportExportError.unsupportedSource("directory artifacts cannot be exported as text documents")
        }
        guard !artifact.hostPath.isEmpty else {
            throw ImportExportExportError.unsupportedSource("artifact has no host path or inline content")
        }

        let source = URL(fileURLWithPath: artifact.hostPath)
        if artifact.isPDF || source.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: source) else {
                throw ImportExportExportError.readFailed("Could not open PDF artifact")
            }
            let text = (0 ..< document.pageCount)
                .compactMap { document.page(at: $0)?.string }
                .joined(separator: "\n\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ImportExportExportError.emptyContent
            }
            return text
        }

        guard artifact.isText else {
            throw ImportExportExportError.unsupportedSource("binary artifact \(artifact.filename) has no text content")
        }
        do {
            return try DocumentParser.parsePlainText(url: source)
        } catch {
            throw ImportExportExportError.readFailed(error.localizedDescription)
        }
    }

    private static func existingPDFURL(from source: ImportExportExportSource) throws -> URL? {
        guard case .artifact(let artifact) = source else { return nil }
        guard artifact.isPDF || (artifact.filename as NSString).pathExtension.lowercased() == "pdf" else {
            return nil
        }
        guard !artifact.hostPath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: artifact.hostPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ImportExportExportError.readFailed("PDF artifact file was not found")
        }
        return url
    }

    private static func normalizeTextDocument(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmed = normalized.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return "" }

        // Preserve caller-provided text semantics while making saved files stable.
        return trimmed + "\n"
    }

    private static func writePDF(text: String, to destination: URL) throws {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 54
        var mediaBox = pageRect
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw ImportExportExportError.writeFailed("Could not create PDF context")
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let textRect = CGRect(
            x: margin,
            y: margin,
            width: pageRect.width - margin * 2,
            height: pageRect.height - margin * 2
        )

        var currentRange = CFRange(location: 0, length: 0)
        repeat {
            context.beginPDFPage(nil)
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: 0, y: pageRect.height)
            context.scaleBy(x: 1, y: -1)

            let path = CGMutablePath()
            path.addRect(textRect)
            let frame = CTFramesetterCreateFrame(framesetter, currentRange, path, nil)
            CTFrameDraw(frame, context)
            let visibleRange = CTFrameGetVisibleStringRange(frame)

            context.restoreGState()
            context.endPDFPage()

            guard visibleRange.length > 0 else { break }
            currentRange.location += visibleRange.length
        } while currentRange.location < attributed.length

        context.closePDF()

        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw ImportExportExportError.writeFailed(error.localizedDescription)
        }
    }

    private static func validatedDestination(_ url: URL, expectedExtension: String) throws -> URL {
        guard url.isFileURL else {
            throw ImportExportExportError.destinationMustBeFileURL
        }
        let destination = url.standardizedFileURL
        let actualExtension = destination.pathExtension.lowercased()
        guard actualExtension == expectedExtension else {
            throw ImportExportExportError.destinationExtensionMismatch(
                expected: expectedExtension,
                actual: actualExtension.isEmpty ? "(none)" : actualExtension
            )
        }

        let parent = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ImportExportExportError.destinationParentMissing(parent.path)
        }

        var destinationIsDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: destination.path, isDirectory: &destinationIsDirectory),
            destinationIsDirectory.boolValue
        {
            throw ImportExportExportError.destinationIsDirectory(destination.path)
        }

        return destination
    }
}
