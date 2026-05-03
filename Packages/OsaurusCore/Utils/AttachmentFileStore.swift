//
//  AttachmentFileStore.swift
//  osaurus
//
//  Persists high-fidelity input files outside chat history JSON so plugins
//  can operate on original bytes.
//

import Foundation
import PDFKit

enum AttachmentFileStore {
    static let preservedExtensions: Set<String> = ["pdf", "ppt", "pptx", "ppsx", "potx"]

    static func shouldPreserveOriginal(url: URL) -> Bool {
        preservedExtensions.contains(url.pathExtension.lowercased())
    }

    static func store(url: URL) throws -> Attachment {
        let id = UUID()
        let filename = sanitizedFilename(url.lastPathComponent)
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let destinationDir = OsaurusPaths.attachmentDir(attachmentId: id.uuidString)
        let destinationURL = destinationDir.appendingPathComponent(filename, isDirectory: false)

        let fm = FileManager.default
        try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        try fm.copyItem(at: url, to: destinationURL)

        return .file(
            id: id,
            filename: filename,
            mimeType: mimeType(for: filename),
            fileSize: fileSize,
            hostPath: destinationURL.path,
            extractedPreview: extractedPreview(for: destinationURL)
        )
    }

    static func mimeType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "ppt":
            return "application/vnd.ms-powerpoint"
        case "pptx":
            return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "ppsx":
            return "application/vnd.openxmlformats-officedocument.presentationml.slideshow"
        case "potx":
            return "application/vnd.openxmlformats-officedocument.presentationml.template"
        default:
            return SharedArtifact.mimeType(from: filename)
        }
    }

    private static func sanitizedFilename(_ filename: String) -> String {
        let fallback = "attachment"
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? fallback : trimmed
        let invalid = CharacterSet(charactersIn: "/\\:")
        let cleaned = base.components(separatedBy: invalid).joined(separator: "_")
        return cleaned.isEmpty ? fallback : cleaned
    }

    private static func extractedPreview(for url: URL) -> String? {
        guard url.pathExtension.lowercased() == "pdf",
            let document = PDFDocument(url: url)
        else {
            return nil
        }

        var pages: [String] = []
        for i in 0 ..< document.pageCount {
            guard let page = document.page(at: i),
                let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty
            else { continue }
            pages.append("Page \(i + 1):\n\(text)")
        }

        let joined = pages.joined(separator: "\n\n")
        guard !joined.isEmpty else { return nil }

        if joined.count > DocumentParser.maxParsedTextLength {
            return String(joined.prefix(DocumentParser.maxParsedTextLength))
                + "\n\n[Preview truncated - exceeded \(DocumentParser.maxParsedTextLength) character limit]"
        }
        return joined
    }
}
