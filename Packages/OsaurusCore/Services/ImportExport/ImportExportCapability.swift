import Foundation

enum ImportExportCapabilityRole: String, Codable, Sendable, CaseIterable, Hashable {
    case probe
    case `import`
    case export
    case validate
}

enum ImportExportRuntimeKind: String, Codable, Sendable {
    case builtIn
    case sidecar
    case passthrough
}

enum ImportExportPromptSafetyStatus: String, Codable, Sendable {
    case plainText
    case extractedText
    case renderedPreview
    case artifactOnly
    case scaffoldOnly
}

enum ImportExportActiveContentRisk: String, Codable, Sendable {
    case none
    case low
    case medium
    case high
    case unknown
}

struct ImportExportTrustMetadata: Codable, Sendable, Equatable {
    let runtime: ImportExportRuntimeKind
    let promptSafety: ImportExportPromptSafetyStatus
    let activeContentRisk: ImportExportActiveContentRisk
    let notes: [String]
}

struct ImportExportCapabilityMetadata: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let displayName: String
    let supportedExtensions: [String]
    let utTypeIdentifiers: [String]
    let roles: Set<ImportExportCapabilityRole>
    let canonicalTarget: String?
    let trust: ImportExportTrustMetadata
    let runtimeRequirements: [String]
    let fidelityNotes: [String]
    let defaultIconSymbolName: String?
    let iconSymbolNamesByExtension: [String: String]
    let isScaffoldOnly: Bool
}

struct ImportExportProbeRequest: Sendable {
    let url: URL

    var fileExtension: String {
        url.pathExtension.lowercased()
    }
}

struct ImportExportProbeResult: Sendable, Equatable {
    let matchedExtension: String
    let capabilityId: String
}

protocol ImportExportProbeCapability: Sendable {
    func probe(
        request: ImportExportProbeRequest,
        metadata: ImportExportCapabilityMetadata
    ) -> ImportExportProbeResult?
}

struct ImportExportImportRequest: Sendable {
    let url: URL
    let filename: String
    let fileSize: Int
}

struct ImportExportImportResult: Sendable, Equatable {
    let attachments: [Attachment]
}

protocol ImportExportImportCapability: Sendable {
    func importFile(
        request: ImportExportImportRequest,
        metadata: ImportExportCapabilityMetadata
    ) throws -> ImportExportImportResult
}

struct ImportExportExportRequest: Sendable {
    let destinationURL: URL
    let formatExtension: String
}

struct ImportExportExportResult: Sendable, Equatable {
    let outputURL: URL
}

protocol ImportExportExportCapability: Sendable {
    func exportFile(
        request: ImportExportExportRequest,
        metadata: ImportExportCapabilityMetadata
    ) throws -> ImportExportExportResult
}

struct ImportExportValidationRequest: Sendable {
    let url: URL
    let detectedExtension: String?
}

enum ImportExportValidationSeverity: String, Codable, Sendable {
    case info
    case warning
    case error
}

struct ImportExportValidationIssue: Codable, Sendable, Equatable {
    let severity: ImportExportValidationSeverity
    let code: String
    let message: String
}

struct ImportExportValidationResult: Sendable, Equatable {
    let issues: [ImportExportValidationIssue]

    static let empty = ImportExportValidationResult(issues: [])
}

protocol ImportExportValidateCapability: Sendable {
    func validate(
        request: ImportExportValidationRequest,
        metadata: ImportExportCapabilityMetadata
    ) -> ImportExportValidationResult
}

struct ImportExportCapabilityRegistration: Sendable {
    let metadata: ImportExportCapabilityMetadata
    let probe: (any ImportExportProbeCapability)?
    let importer: (any ImportExportImportCapability)?
    let exporter: (any ImportExportExportCapability)?
    let validator: (any ImportExportValidateCapability)?
}

struct ImportExportCapabilityProbeResolution: Sendable {
    let metadata: ImportExportCapabilityMetadata
    let matchedExtension: String
}

struct ImportExportCapabilityImportResolution: Sendable {
    let metadata: ImportExportCapabilityMetadata
    let matchedExtension: String
    let importer: any ImportExportImportCapability
}
