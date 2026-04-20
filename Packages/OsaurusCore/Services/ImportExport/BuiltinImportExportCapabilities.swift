import Foundation

enum ImportExportScaffoldOnlyError: LocalizedError {
    case notImplemented(String)

    var errorDescription: String? {
        switch self {
        case .notImplemented(let capabilityId):
            return "Capability registry scaffold-only path is not implemented yet: \(capabilityId)"
        }
    }
}

enum BuiltinImportExportCapabilities {
    static func defaultRegistrations() -> [ImportExportCapabilityRegistration] {
        let plainTextImporter = PlainTextAttachmentImportCapability()
        let richTextImporter = RichDocumentAttachmentImportCapability()
        let pdfImporter = PDFDocumentAttachmentImportCapability()
        let delimitedTextExporter = DelimitedTextAttachmentExportCapability()
        let pdfExporter = PDFDocumentAttachmentExportCapability()
        let scaffoldExporter = ScaffoldOnlyArtifactExportCapability()
        let scaffoldValidator = ScaffoldOnlyArtifactValidationCapability()

        return [
            ImportExportCapabilityRegistration(
                metadata: ImportExportCapabilityMetadata(
                    id: "builtin.plain-text-attachments",
                    displayName: "Plain Text and Code Attachments",
                    supportedExtensions: [
                        "txt", "md", "markdown",
                        "log", "ini", "cfg", "conf", "env",
                        "swift", "py", "js", "ts", "tsx", "jsx",
                        "rs", "go", "java", "kt", "c", "cpp", "h", "hpp",
                        "rb", "php", "sh", "bash", "zsh", "fish",
                        "css", "scss", "less", "sql",
                        "r", "m", "mm", "lua", "pl", "ex", "exs",
                        "zig", "nim", "dart", "scala", "groovy",
                        "tf", "hcl", "dockerfile",
                        "gitignore", "editorconfig", "prettierrc",
                    ],
                    utTypeIdentifiers: [
                        "public.plain-text",
                        "public.utf8-plain-text",
                        "public.python-script",
                        "public.swift-source",
                        "com.netscape.javascript-source",
                        "public.shell-script",
                    ],
                    roles: [.probe, .import],
                    canonicalTarget: "Attachment.document",
                    trust: ImportExportTrustMetadata(
                        runtime: .builtIn,
                        promptSafety: .plainText,
                        activeContentRisk: .low,
                        notes: [
                            "Parsed with Foundation string decoding only.",
                            "This remains a lightweight chat-ingest path, not a semantic document model.",
                        ]
                    ),
                    runtimeRequirements: ["Foundation"],
                    fidelityNotes: [
                        "Formatting and structure beyond raw text are discarded.",
                    ],
                    defaultIconSymbolName: "doc.plaintext",
                    iconSymbolNamesByExtension: [
                        "md": "text.document",
                        "markdown": "text.document",
                    ],
                    isScaffoldOnly: false
                ),
                probe: ExtensionProbeCapability(
                    supportedExtensions: [
                        "txt", "md", "markdown",
                        "log", "ini", "cfg", "conf", "env",
                        "swift", "py", "js", "ts", "tsx", "jsx",
                        "rs", "go", "java", "kt", "c", "cpp", "h", "hpp",
                        "rb", "php", "sh", "bash", "zsh", "fish",
                        "css", "scss", "less", "sql",
                        "r", "m", "mm", "lua", "pl", "ex", "exs",
                        "zig", "nim", "dart", "scala", "groovy",
                        "tf", "hcl", "dockerfile",
                        "gitignore", "editorconfig", "prettierrc",
                    ]
                ),
                importer: plainTextImporter,
                exporter: nil,
                validator: nil
            ),
            ImportExportCapabilityRegistration(
                metadata: ImportExportCapabilityMetadata(
                    id: "builtin.delimited-text-attachments",
                    displayName: "Delimited Text Attachments",
                    supportedExtensions: ["csv", "tsv"],
                    utTypeIdentifiers: [
                        "public.comma-separated-values-text",
                        "public.tab-separated-values-text",
                    ],
                    roles: [.probe, .import, .export],
                    canonicalTarget: "Attachment.document",
                    trust: ImportExportTrustMetadata(
                        runtime: .builtIn,
                        promptSafety: .plainText,
                        activeContentRisk: .low,
                        notes: [
                            "Import behavior remains text-only ingestion.",
                            "Export writes prompt-safe delimited text from document, text, or text artifact sources.",
                            "Canonical table/workbook modeling is intentionally not part of this slice.",
                        ]
                    ),
                    runtimeRequirements: ["Foundation"],
                    fidelityNotes: [
                        "Cell typing and workbook semantics are not preserved.",
                        "Export preserves caller-provided delimiters and normalizes line endings.",
                    ],
                    defaultIconSymbolName: "tablecells",
                    iconSymbolNamesByExtension: [:],
                    isScaffoldOnly: false
                ),
                probe: ExtensionProbeCapability(supportedExtensions: ["csv", "tsv"]),
                importer: plainTextImporter,
                exporter: delimitedTextExporter,
                validator: nil
            ),
            ImportExportCapabilityRegistration(
                metadata: ImportExportCapabilityMetadata(
                    id: "builtin.structured-text-attachments",
                    displayName: "Structured Text Attachments",
                    supportedExtensions: ["json", "xml", "yaml", "yml", "toml"],
                    utTypeIdentifiers: [
                        "public.json",
                        "public.xml",
                        "public.yaml",
                    ],
                    roles: [.probe, .import],
                    canonicalTarget: "Attachment.document",
                    trust: ImportExportTrustMetadata(
                        runtime: .builtIn,
                        promptSafety: .plainText,
                        activeContentRisk: .low,
                        notes: [
                            "Structured text is currently flattened to prompt-safe text content.",
                        ]
                    ),
                    runtimeRequirements: ["Foundation"],
                    fidelityNotes: [
                        "Schema-aware parsing is intentionally deferred.",
                    ],
                    defaultIconSymbolName: "doc.plaintext",
                    iconSymbolNamesByExtension: [
                        "json": "curlybraces",
                        "xml": "chevron.left.forwardslash.chevron.right",
                    ],
                    isScaffoldOnly: false
                ),
                probe: ExtensionProbeCapability(
                    supportedExtensions: ["json", "xml", "yaml", "yml", "toml"]
                ),
                importer: plainTextImporter,
                exporter: nil,
                validator: nil
            ),
            ImportExportCapabilityRegistration(
                metadata: ImportExportCapabilityMetadata(
                    id: "builtin.pdf-attachments",
                    displayName: "PDF Attachments",
                    supportedExtensions: ["pdf"],
                    utTypeIdentifiers: ["com.adobe.pdf"],
                    roles: [.probe, .import, .export],
                    canonicalTarget: "Attachment.document",
                    trust: ImportExportTrustMetadata(
                        runtime: .builtIn,
                        promptSafety: .extractedText,
                        activeContentRisk: .medium,
                        notes: [
                            "PDF text is extracted with PDFKit.",
                            "If text extraction fails, pages are rendered as images.",
                            "Export writes text sources to a simple paginated PDF or copies existing PDF artifacts.",
                        ]
                    ),
                    runtimeRequirements: ["PDFKit", "AppKit", "CoreText"],
                    fidelityNotes: [
                        "Layout fidelity is reduced to extracted text or page images.",
                        "Generated PDFs preserve readable text, not source document layout.",
                    ],
                    defaultIconSymbolName: "doc.richtext",
                    iconSymbolNamesByExtension: [:],
                    isScaffoldOnly: false
                ),
                probe: ExtensionProbeCapability(supportedExtensions: ["pdf"]),
                importer: pdfImporter,
                exporter: pdfExporter,
                validator: nil
            ),
            ImportExportCapabilityRegistration(
                metadata: ImportExportCapabilityMetadata(
                    id: "builtin.rich-document-attachments",
                    displayName: "Rich Document Attachments",
                    supportedExtensions: ["docx", "doc", "rtf", "rtfd", "html", "htm"],
                    utTypeIdentifiers: [
                        "org.openxmlformats.wordprocessingml.document",
                        "com.microsoft.word.doc",
                        "public.rtf",
                        "com.apple.rtfd",
                        "public.html",
                    ],
                    roles: [.probe, .import],
                    canonicalTarget: "Attachment.document",
                    trust: ImportExportTrustMetadata(
                        runtime: .builtIn,
                        promptSafety: .extractedText,
                        activeContentRisk: .medium,
                        notes: [
                            "Rich documents are currently reduced to extracted text.",
                            "Semantic Office support is intentionally out of scope for this slice.",
                        ]
                    ),
                    runtimeRequirements: ["AppKit"],
                    fidelityNotes: [
                        "Formatting, layout, and editable document structure are not preserved.",
                    ],
                    defaultIconSymbolName: "doc.text",
                    iconSymbolNamesByExtension: [
                        "rtf": "doc.richtext",
                        "rtfd": "doc.richtext",
                        "html": "chevron.left.forwardslash.chevron.right",
                        "htm": "chevron.left.forwardslash.chevron.right",
                    ],
                    isScaffoldOnly: false
                ),
                probe: ExtensionProbeCapability(
                    supportedExtensions: ["docx", "doc", "rtf", "rtfd", "html", "htm"]
                ),
                importer: richTextImporter,
                exporter: nil,
                validator: nil
            ),
            ImportExportCapabilityRegistration(
                metadata: ImportExportCapabilityMetadata(
                    id: "builtin.generic-artifact-passthrough",
                    displayName: "Generic Artifact Passthrough",
                    supportedExtensions: ["txt", "md", "json", "html", "csv", "tsv", "png", "jpg", "jpeg", "pdf"],
                    utTypeIdentifiers: [
                        "public.plain-text",
                        "public.json",
                        "public.html",
                        "public.comma-separated-values-text",
                        "public.png",
                        "public.jpeg",
                        "com.adobe.pdf",
                    ],
                    roles: [.probe, .export, .validate],
                    canonicalTarget: "SharedArtifact",
                    trust: ImportExportTrustMetadata(
                        runtime: .passthrough,
                        promptSafety: .scaffoldOnly,
                        activeContentRisk: .unknown,
                        notes: [
                            "This registry entry documents the existing lightweight artifact path.",
                            "Export and validation hooks are scaffold-only in this slice.",
                        ]
                    ),
                    runtimeRequirements: ["Existing share_artifact flow"],
                    fidelityNotes: [
                        "No semantic export contract is attached yet.",
                    ],
                    defaultIconSymbolName: "doc",
                    iconSymbolNamesByExtension: [
                        "md": "text.document",
                        "json": "curlybraces",
                        "html": "chevron.left.forwardslash.chevron.right",
                        "csv": "tablecells",
                        "tsv": "tablecells",
                        "pdf": "doc.richtext",
                    ],
                    isScaffoldOnly: true
                ),
                probe: ExtensionProbeCapability(
                    supportedExtensions: ["txt", "md", "json", "html", "csv", "tsv", "png", "jpg", "jpeg", "pdf"]
                ),
                importer: nil,
                exporter: scaffoldExporter,
                validator: scaffoldValidator
            ),
        ]
    }
}

private struct ExtensionProbeCapability: ImportExportProbeCapability {
    private let supportedExtensions: Set<String>

    init(supportedExtensions: [String]) {
        self.supportedExtensions = Set(supportedExtensions.map { $0.lowercased() })
    }

    func probe(
        request: ImportExportProbeRequest,
        metadata: ImportExportCapabilityMetadata
    ) -> ImportExportProbeResult? {
        let ext = request.fileExtension
        guard !ext.isEmpty, supportedExtensions.contains(ext) else { return nil }
        return ImportExportProbeResult(matchedExtension: ext, capabilityId: metadata.id)
    }
}

private struct PlainTextAttachmentImportCapability: ImportExportImportCapability {
    func importFile(
        request: ImportExportImportRequest,
        metadata _: ImportExportCapabilityMetadata
    ) throws -> ImportExportImportResult {
        let content = try DocumentParser.parsePlainText(url: request.url)
        let attachment = try DocumentParser.makeDocumentAttachment(
            filename: request.filename,
            content: content,
            fileSize: request.fileSize
        )
        return ImportExportImportResult(attachments: [attachment])
    }
}

private struct RichDocumentAttachmentImportCapability: ImportExportImportCapability {
    func importFile(
        request: ImportExportImportRequest,
        metadata _: ImportExportCapabilityMetadata
    ) throws -> ImportExportImportResult {
        let content: String
        switch request.url.pathExtension.lowercased() {
        case "doc":
            content = try DocumentParser.parseRichDocument(url: request.url, type: .docFormat)
        case "rtf", "rtfd":
            content = try DocumentParser.parseRichDocument(url: request.url, type: .rtf)
        case "html", "htm":
            content = try DocumentParser.parseRichDocument(url: request.url, type: .html)
        default:
            content = try DocumentParser.parseRichDocument(url: request.url)
        }
        let attachment = try DocumentParser.makeDocumentAttachment(
            filename: request.filename,
            content: content,
            fileSize: request.fileSize
        )
        return ImportExportImportResult(attachments: [attachment])
    }
}

private struct PDFDocumentAttachmentImportCapability: ImportExportImportCapability {
    func importFile(
        request: ImportExportImportRequest,
        metadata _: ImportExportCapabilityMetadata
    ) throws -> ImportExportImportResult {
        let attachments = try DocumentParser.parsePDFWithFallback(
            url: request.url,
            filename: request.filename,
            fileSize: request.fileSize
        )
        return ImportExportImportResult(attachments: attachments)
    }
}

private struct DelimitedTextAttachmentExportCapability: ImportExportExportCapability {
    func exportFile(
        request: ImportExportExportRequest,
        metadata _: ImportExportCapabilityMetadata
    ) throws -> ImportExportExportResult {
        try ImportExportDocumentExporter.exportDelimitedText(request: request)
    }
}

private struct PDFDocumentAttachmentExportCapability: ImportExportExportCapability {
    func exportFile(
        request: ImportExportExportRequest,
        metadata _: ImportExportCapabilityMetadata
    ) throws -> ImportExportExportResult {
        try ImportExportDocumentExporter.exportPDF(request: request)
    }
}

private struct ScaffoldOnlyArtifactExportCapability: ImportExportExportCapability {
    func exportFile(
        request _: ImportExportExportRequest,
        metadata: ImportExportCapabilityMetadata
    ) throws -> ImportExportExportResult {
        throw ImportExportScaffoldOnlyError.notImplemented(metadata.id)
    }
}

private struct ScaffoldOnlyArtifactValidationCapability: ImportExportValidateCapability {
    func validate(
        request _: ImportExportValidationRequest,
        metadata: ImportExportCapabilityMetadata
    ) -> ImportExportValidationResult {
        ImportExportValidationResult(
            issues: [
                ImportExportValidationIssue(
                    severity: .info,
                    code: "registry.scaffold_only",
                    message: "Validation is scaffold-only for \(metadata.displayName) in this slice."
                )
            ]
        )
    }
}
