//
//  PPTXAdapter.swift
//  osaurus
//
//  Read-only PPTX adapter. It extracts slide text and speaker notes from
//  the OpenXML package into `PresentationDocument`; richer media, layout,
//  and chart extraction can fill the existing typed slots later.
//

import Foundation

public struct PPTXAdapter: DocumentFormatAdapter {
    public static let id = "pptx"

    public let formatId = PPTXAdapter.id

    public init() {}

    public func canHandle(url: URL, uti: String?) -> Bool {
        if url.pathExtension.lowercased() == "pptx" {
            return true
        }

        return uti == "org.openxmlformats.presentationml.presentation"
    }

    public func parse(url: URL, sizeLimit: Int64) async throws -> StructuredDocument {
        try Task.checkCancellation()

        let fileSize = try Self.fileSize(for: url)
        guard fileSize <= sizeLimit else {
            throw DocumentAdapterError.sizeLimitExceeded(actual: fileSize, limit: sizeLimit)
        }

        do {
            let presentation = try await Self.parsePresentation(at: url)
            let textFallback = Self.textFallback(for: presentation)
            guard !textFallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DocumentAdapterError.emptyContent
            }

            return StructuredDocument(
                formatId: formatId,
                filename: url.lastPathComponent,
                fileSize: fileSize,
                representation: AnyStructuredRepresentation(formatId: formatId, underlying: presentation),
                textFallback: textFallback
            )
        } catch is CancellationError {
            throw DocumentAdapterError.cancelled
        } catch let error as DocumentAdapterError {
            throw error
        } catch {
            throw DocumentAdapterError.readFailed(underlying: error.localizedDescription)
        }
    }

    // MARK: - Parse

    private static func parsePresentation(at url: URL) async throws -> PresentationDocument {
        let entries = try zipEntryNames(in: url)
        try Task.checkCancellation()

        let slideEntries = numberedEntries(entries, directory: "ppt/slides", prefix: "slide")
        guard !slideEntries.isEmpty else {
            throw DocumentAdapterError.readFailed(underlying: "PPTX contains no slide XML files")
        }

        let notesEntries = numberedEntries(entries, directory: "ppt/notesSlides", prefix: "notesSlide")
        var notesByNumber: [Int: SpeakerNotes] = [:]
        for entry in notesEntries {
            try Task.checkCancellation()
            let paragraphs = try textParagraphs(in: entry.path, from: url)
            let noteText = paragraphs.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !noteText.isEmpty {
                notesByNumber[entry.number] = SpeakerNotes(
                    text: noteText,
                    sourceProvenance: SourceProvenance(
                        origin: .pptxNotesSlide(entry.number),
                        sourceName: entry.path
                    )
                )
            }
        }

        let slides = try slideEntries.map { entry in
            let provenance = SourceProvenance(origin: .pptxSlide(entry.number), sourceName: entry.path)
            let paragraphs = try textParagraphs(in: entry.path, from: url)
            let elements = slideElements(from: paragraphs, provenance: provenance)
            return PresentationSlide(
                number: entry.number,
                layout: layoutKind(for: elements),
                elements: elements,
                speakerNotes: notesByNumber[entry.number],
                sourceProvenance: provenance
            )
        }

        return PresentationDocument(
            slides: slides,
            sourceProvenance: SourceProvenance(origin: .file, sourceName: url.lastPathComponent)
        )
    }

    private static func slideElements(
        from paragraphs: [String],
        provenance: SourceProvenance
    ) -> [PresentationElement] {
        guard let first = paragraphs.first else { return [] }

        var elements: [PresentationElement] = [
            .title(PresentationText(text: first, sourceProvenance: provenance))
        ]
        let body = Array(paragraphs.dropFirst())
        if !body.isEmpty {
            elements.append(.bodyText(PresentationBulletList(body, sourceProvenance: provenance)))
        }
        return elements
    }

    private static func layoutKind(for elements: [PresentationElement]) -> PresentationLayoutKind {
        if elements.isEmpty {
            return .blank
        }
        if elements.count == 1, case .title = elements[0] {
            return .title
        }
        return .titleAndContent
    }

    private static func textFallback(for presentation: PresentationDocument) -> String {
        presentation.slides.map { slide in
            var parts = ["Slide \(slide.number)"]
            let slideText = plainText(for: slide.elements)
            if !slideText.isEmpty {
                parts.append(slideText)
            }
            if let noteText = slide.speakerNotes?.text, !noteText.isEmpty {
                parts.append("Speaker notes:\n\(noteText)")
            }
            return parts.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    private static func plainText(for elements: [PresentationElement]) -> String {
        elements.flatMap { element -> [String] in
            switch element {
            case .title(let text):
                return [text.text]
            case .bodyText(let list):
                return list.items.map(\.text)
            case .shape(let shape):
                return [shape.text?.text].compactMap { $0 }
            case .table(let table):
                return table.rows.map { $0.joined(separator: "\t") }
            case .chartReference(let chart):
                return [chart.title].compactMap { $0 }
            case .image:
                return []
            }
        }
        .joined(separator: "\n")
    }

    // MARK: - XML

    private static func textParagraphs(in entryPath: String, from archiveURL: URL) throws -> [String] {
        let data = try zipEntryData(entryPath, from: archiveURL)
        let collector = OpenXMLTextCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector

        guard parser.parse() else {
            let message = parser.parserError?.localizedDescription ?? "Invalid XML in \(entryPath)"
            throw DocumentAdapterError.readFailed(underlying: message)
        }

        return collector.paragraphs
    }

    // MARK: - ZIP

    private static func zipEntryNames(in archiveURL: URL) throws -> [String] {
        try runUnzip(arguments: ["-Z1", archiveURL.path])
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func zipEntryData(_ entryPath: String, from archiveURL: URL) throws -> Data {
        try runUnzipData(arguments: ["-p", archiveURL.path, entryPath])
    }

    private static func numberedEntries(
        _ entries: [String],
        directory: String,
        prefix: String
    ) -> [NumberedEntry] {
        let expectedPrefix = "\(directory)/\(prefix)"
        return entries.compactMap { entry -> NumberedEntry? in
            guard entry.hasPrefix(expectedPrefix), entry.hasSuffix(".xml") else {
                return nil
            }

            let start = entry.index(entry.startIndex, offsetBy: expectedPrefix.count)
            let end = entry.index(entry.endIndex, offsetBy: -".xml".count)
            guard start <= end, let number = Int(entry[start ..< end]) else {
                return nil
            }

            return NumberedEntry(number: number, path: entry)
        }
        .sorted {
            if $0.number == $1.number {
                return $0.path < $1.path
            }
            return $0.number < $1.number
        }
    }

    private static func runUnzip(arguments: [String]) throws -> String {
        let data = try runUnzipData(arguments: arguments)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func runUnzipData(arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments

        let output = Pipe()
        let errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw DocumentAdapterError.readFailed(underlying: "Unable to run unzip: \(error.localizedDescription)")
        }

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData.isEmpty ? outputData : errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = message?.isEmpty == false ? message! : "unzip exited with status \(process.terminationStatus)"
            throw DocumentAdapterError.readFailed(underlying: reason)
        }

        return outputData
    }

    // MARK: - Files

    private static func fileSize(for url: URL) throws -> Int64 {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            if let size = values.fileSize {
                return Int64(size)
            }

            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attributes[.size] as? NSNumber {
                return size.int64Value
            }
            return 0
        } catch {
            throw DocumentAdapterError.readFailed(underlying: error.localizedDescription)
        }
    }

    private struct NumberedEntry {
        var number: Int
        var path: String
    }
}

private final class OpenXMLTextCollector: NSObject, XMLParserDelegate {
    private var isInParagraph = false
    private var isInTextRun = false
    private var currentParagraph = ""
    private var currentRun = ""

    private(set) var paragraphs: [String] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if Self.matches(elementName, qualifiedName: qName, suffix: "p") {
            isInParagraph = true
            currentParagraph = ""
        } else if Self.matches(elementName, qualifiedName: qName, suffix: "t") {
            isInTextRun = true
            currentRun = ""
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if Self.matches(elementName, qualifiedName: qName, suffix: "t") {
            if isInParagraph {
                currentParagraph.append(currentRun)
            } else {
                appendParagraph(currentRun)
            }
            isInTextRun = false
            currentRun = ""
        } else if Self.matches(elementName, qualifiedName: qName, suffix: "p") {
            appendParagraph(currentParagraph)
            isInParagraph = false
            currentParagraph = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isInTextRun else { return }
        currentRun.append(string)
    }

    private func appendParagraph(_ text: String) {
        let normalized = Self.normalize(text)
        if !normalized.isEmpty {
            paragraphs.append(normalized)
        }
    }

    private static func matches(_ elementName: String, qualifiedName: String?, suffix: String) -> Bool {
        let names = [elementName, qualifiedName].compactMap { $0 }
        return names.contains(suffix) || names.contains { $0.hasSuffix(":\(suffix)") }
    }

    private static func normalize(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
