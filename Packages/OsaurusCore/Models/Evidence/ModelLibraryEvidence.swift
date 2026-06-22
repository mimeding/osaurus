//
//  ModelLibraryEvidence.swift
//  osaurus
//
//  Read-only model detail evidence projection. These types describe what local
//  artifacts and preflight inputs prove; they do not mutate model runtime state.
//

import Foundation

public enum ModelLibraryEvidenceStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case supported
    case partial
    case unsupported
    case unproven

    public static func aggregate(_ statuses: [ModelLibraryEvidenceStatus]) -> ModelLibraryEvidenceStatus {
        let concrete = statuses.filter { $0 != .unproven }
        if concrete.contains(.unsupported) {
            return .unsupported
        }
        if concrete.contains(.partial) {
            return .partial
        }
        if concrete.contains(.supported) {
            return .supported
        }
        return .unproven
    }
}

public enum ModelLibraryImportState: String, Codable, CaseIterable, Hashable, Sendable {
    case downloaded
    case imported
    case externalReadOnly = "external_read_only"
    case inProgress = "in_progress"
    case missing
    case incomplete
    case failed
    case unknown

    public var evidenceStatus: ModelLibraryEvidenceStatus {
        switch self {
        case .downloaded, .imported, .externalReadOnly:
            return .supported
        case .inProgress:
            return .partial
        case .incomplete, .failed:
            return .unsupported
        case .missing, .unknown:
            return .unproven
        }
    }
}

public enum ModelLibraryCacheState: String, Codable, CaseIterable, Hashable, Sendable {
    case hitProven = "hit_proven"
    case enabledNoHit = "enabled_no_hit"
    case coldStored = "cold_stored"
    case notObserved = "not_observed"
    case missing
    case failed
    case unsupported
    case unknown

    public var evidenceStatus: ModelLibraryEvidenceStatus {
        switch self {
        case .hitProven:
            return .supported
        case .enabledNoHit, .coldStored:
            return .partial
        case .failed, .unsupported:
            return .unsupported
        case .notObserved, .missing, .unknown:
            return .unproven
        }
    }
}

public struct ModelLibraryCompatibilityEvidence: Codable, Equatable, Hashable, Sendable {
    public var status: ModelLibraryEvidenceStatus
    public var reason: String
    public var detail: String?
    public var evidence: [String]

    public init(
        status: ModelLibraryEvidenceStatus,
        reason: String,
        detail: String? = nil,
        evidence: [String] = []
    ) {
        self.status = status
        self.reason = reason
        self.detail = detail
        self.evidence = evidence
    }
}

public struct ModelLibraryCacheImportEvidence: Codable, Equatable, Hashable, Sendable {
    public var importState: ModelLibraryImportState
    public var cacheState: ModelLibraryCacheState
    public var source: String?
    public var notes: [String]

    public init(
        importState: ModelLibraryImportState = .unknown,
        cacheState: ModelLibraryCacheState = .unknown,
        source: String? = nil,
        notes: [String] = []
    ) {
        self.importState = importState
        self.cacheState = cacheState
        self.source = source
        self.notes = notes
    }

    public var status: ModelLibraryEvidenceStatus {
        ModelLibraryEvidenceStatus.aggregate([
            importState.evidenceStatus,
            cacheState.evidenceStatus,
        ])
    }
}

public struct ModelLibraryMemoryNote: Codable, Equatable, Hashable, Sendable {
    public var status: ModelLibraryEvidenceStatus
    public var source: String
    public var note: String
    public var physicalFootprintBytes: Int64?
    public var limitBytes: Int64?

    public init(
        status: ModelLibraryEvidenceStatus,
        source: String,
        note: String,
        physicalFootprintBytes: Int64? = nil,
        limitBytes: Int64? = nil
    ) {
        self.status = status
        self.source = source
        self.note = note
        self.physicalFootprintBytes = physicalFootprintBytes
        self.limitBytes = limitBytes
    }
}

public struct ModelLibraryTokenRateEvidence: Codable, Equatable, Hashable, Sendable {
    public var reportID: String
    public var source: String
    public var metadataKey: String
    public var rawValue: String
    public var tokensPerSecond: Double

    public init(
        reportID: String,
        source: String,
        metadataKey: String,
        rawValue: String,
        tokensPerSecond: Double
    ) {
        self.reportID = reportID
        self.source = source
        self.metadataKey = metadataKey
        self.rawValue = rawValue
        self.tokensPerSecond = tokensPerSecond
    }
}

public struct ModelLibraryEvidenceReportDigest: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var kind: EvidenceReportKind
    public var source: String
    public var artifactPath: String
    public var artifactAvailability: EvidenceArtifactAvailability
    public var reportStatus: EvidenceReportStatus
    public var status: ModelLibraryEvidenceStatus
    public var isGenerationProof: Bool
    public var counts: EvidenceReportCounts
    public var completedAt: Date?
    public var tokenRates: [ModelLibraryTokenRateEvidence]
    public var notes: [String]

    public init(
        id: String,
        kind: EvidenceReportKind,
        source: String,
        artifactPath: String,
        artifactAvailability: EvidenceArtifactAvailability,
        reportStatus: EvidenceReportStatus,
        status: ModelLibraryEvidenceStatus,
        isGenerationProof: Bool = false,
        counts: EvidenceReportCounts,
        completedAt: Date? = nil,
        tokenRates: [ModelLibraryTokenRateEvidence] = [],
        notes: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.artifactPath = artifactPath
        self.artifactAvailability = artifactAvailability
        self.reportStatus = reportStatus
        self.status = status
        self.isGenerationProof = isGenerationProof
        self.counts = counts
        self.completedAt = completedAt
        self.tokenRates = tokenRates
        self.notes = notes
    }
}

public struct ModelLibraryEvidenceQuery: Equatable, Hashable, Sendable {
    public var modelID: String
    public var displayName: String?
    public var aliases: Set<String>

    public init(
        modelID: String,
        displayName: String? = nil,
        aliases: Set<String> = []
    ) {
        self.modelID = modelID
        self.displayName = displayName
        self.aliases = aliases
    }
}

public struct ModelLibraryEvidenceContext: Equatable, Sendable {
    public var compatibility: ModelLibraryCompatibilityEvidence?
    public var cacheImport: ModelLibraryCacheImportEvidence?
    public var memoryNotes: [ModelLibraryMemoryNote]

    public init(
        compatibility: ModelLibraryCompatibilityEvidence? = nil,
        cacheImport: ModelLibraryCacheImportEvidence? = nil,
        memoryNotes: [ModelLibraryMemoryNote] = []
    ) {
        self.compatibility = compatibility
        self.cacheImport = cacheImport
        self.memoryNotes = memoryNotes
    }
}

public struct ModelLibraryEvidenceSnapshot: Codable, Equatable, Sendable {
    public var modelID: String
    public var displayName: String?
    public var status: ModelLibraryEvidenceStatus
    public var compatibility: ModelLibraryCompatibilityEvidence?
    public var cacheImport: ModelLibraryCacheImportEvidence?
    public var reports: [ModelLibraryEvidenceReportDigest]
    public var tokenRates: [ModelLibraryTokenRateEvidence]
    public var memoryNotes: [ModelLibraryMemoryNote]
    public var blockers: [String]
    public var warnings: [String]

    public init(
        modelID: String,
        displayName: String? = nil,
        status: ModelLibraryEvidenceStatus,
        compatibility: ModelLibraryCompatibilityEvidence? = nil,
        cacheImport: ModelLibraryCacheImportEvidence? = nil,
        reports: [ModelLibraryEvidenceReportDigest] = [],
        tokenRates: [ModelLibraryTokenRateEvidence] = [],
        memoryNotes: [ModelLibraryMemoryNote] = [],
        blockers: [String] = [],
        warnings: [String] = []
    ) {
        self.modelID = modelID
        self.displayName = displayName
        self.status = status
        self.compatibility = compatibility
        self.cacheImport = cacheImport
        self.reports = reports
        self.tokenRates = tokenRates
        self.memoryNotes = memoryNotes
        self.blockers = blockers
        self.warnings = warnings
    }
}
