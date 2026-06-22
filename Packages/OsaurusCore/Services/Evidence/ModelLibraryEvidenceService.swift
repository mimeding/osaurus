//
//  ModelLibraryEvidenceService.swift
//  osaurus
//
//  Read-only aggregation over evidence report registry summaries and caller-
//  supplied model detail observations.
//

import Foundation

public final class ModelLibraryEvidenceService {
    private static let modelIdentifierKeys: Set<String> = [
        "bundleid",
        "hfmodelid",
        "huggingfacemodelid",
        "model",
        "modelid",
        "modelidentifier",
        "modelname",
        "resolvedmodel",
        "resolvedmodelid",
        "runtimemodel",
        "runtimemodelid",
        "targetmodel",
    ]

    private static let tokenRateKeySuffixes: Set<String> = [
        "completiontokenspersecond",
        "completiontokpersecond",
        "completiontps",
        "decodetps",
        "gentps",
        "tokpersec",
        "tokenspersecond",
        "tokenspersec",
        "tokenpersecond",
        "tokenpersec",
        "tokenspers",
        "tokpers",
        "tps",
    ]

    private static let generationProofKinds: Set<EvidenceReportKind> = [
        .benchmark,
        .liveProof,
        .runTrace,
        .runtime,
    ]

    private let registry: EvidenceReportRegistryService?

    public init(registry: EvidenceReportRegistryService? = nil) {
        self.registry = registry
    }

    public func snapshot(
        for query: ModelLibraryEvidenceQuery,
        context: ModelLibraryEvidenceContext = ModelLibraryEvidenceContext()
    ) -> ModelLibraryEvidenceSnapshot {
        snapshot(
            for: query,
            context: context,
            reports: registry?.list() ?? []
        )
    }

    public func snapshot(
        for query: ModelLibraryEvidenceQuery,
        context: ModelLibraryEvidenceContext = ModelLibraryEvidenceContext(),
        registrySnapshot: EvidenceReportRegistrySnapshot
    ) -> ModelLibraryEvidenceSnapshot {
        snapshot(
            for: query,
            context: context,
            reports: registrySnapshot.reports
        )
    }

    public func snapshot(
        for query: ModelLibraryEvidenceQuery,
        context: ModelLibraryEvidenceContext = ModelLibraryEvidenceContext(),
        reports: [EvidenceReportSummary]
    ) -> ModelLibraryEvidenceSnapshot {
        let matchingReports = reports
            .filter { reportMatches($0, query: query) }
            .sorted(by: Self.sortReports)
        let digests = matchingReports.map(reportDigest)
        let tokenRates = digests.flatMap(\.tokenRates)
            .sorted(by: Self.sortTokenRates)
        let memoryNotes = (
            context.memoryNotes
                + matchingReports.flatMap(memoryNotes)
        ).sorted(by: Self.sortMemoryNotes)
        let blockers = blockers(
            compatibility: context.compatibility,
            cacheImport: context.cacheImport,
            reports: digests,
            memoryNotes: memoryNotes
        )
        let warnings = warnings(
            compatibility: context.compatibility,
            cacheImport: context.cacheImport,
            reports: digests,
            memoryNotes: memoryNotes
        )

        return ModelLibraryEvidenceSnapshot(
            modelID: query.modelID,
            displayName: query.displayName,
            status: aggregateStatus(
                compatibility: context.compatibility,
                cacheImport: context.cacheImport,
                reports: digests,
                memoryNotes: memoryNotes
            ),
            compatibility: context.compatibility,
            cacheImport: context.cacheImport,
            reports: digests,
            tokenRates: tokenRates,
            memoryNotes: memoryNotes,
            blockers: blockers,
            warnings: warnings
        )
    }

    public func snapshots(
        for queries: [ModelLibraryEvidenceQuery],
        contextsByModelID: [String: ModelLibraryEvidenceContext] = [:],
        reports: [EvidenceReportSummary]
    ) -> [ModelLibraryEvidenceSnapshot] {
        queries.map { query in
            snapshot(
                for: query,
                context: contextsByModelID[query.modelID] ?? ModelLibraryEvidenceContext(),
                reports: reports
            )
        }
    }

    private func reportDigest(_ report: EvidenceReportSummary) -> ModelLibraryEvidenceReportDigest {
        let tokenRates = tokenRates(in: report)
        let baseStatus = status(from: report)
        let generationReport = isGenerationReport(report)
        var status = baseStatus
        var notes = report.artifact.message.map { [$0] } ?? []

        if generationReport, baseStatus == .supported {
            if tokenRates.isEmpty {
                status = .partial
                notes.append(
                    "Generation proof is missing token/s metadata and cannot support a ready claim."
                )
            } else if !tokenRates.contains(where: { $0.tokensPerSecond > 0 }) {
                status = .partial
                notes.append(
                    "Generation proof recorded token/s, but no positive token/s value is present."
                )
            }
        } else if generationReport, baseStatus == .partial, tokenRates.isEmpty {
            notes.append("Partial generation proof is missing token/s metadata.")
        }

        return ModelLibraryEvidenceReportDigest(
            id: report.id,
            kind: report.kind,
            source: report.source,
            artifactPath: report.artifact.path,
            artifactAvailability: report.artifact.availability,
            reportStatus: report.status,
            status: status,
            isGenerationProof: generationReport,
            counts: report.counts,
            completedAt: report.completedAt,
            tokenRates: tokenRates,
            notes: notes
        )
    }

    private func aggregateStatus(
        compatibility: ModelLibraryCompatibilityEvidence?,
        cacheImport: ModelLibraryCacheImportEvidence?,
        reports: [ModelLibraryEvidenceReportDigest],
        memoryNotes: [ModelLibraryMemoryNote]
    ) -> ModelLibraryEvidenceStatus {
        var statuses = reports.map(\.status) + memoryNotes.map(\.status)
        if let compatibility {
            statuses.append(compatibility.status)
        }
        if let cacheImport {
            statuses.append(cacheImport.status)
        }

        if statuses.contains(.unsupported) {
            return .unsupported
        }

        let hasSupportedGenerationProof = reports.contains { report in
            report.isGenerationProof && report.status == .supported
        }
        let hasPartialEvidence = statuses.contains(.partial)
        let hasPositiveEvidence = statuses.contains(.supported) || hasPartialEvidence

        if hasSupportedGenerationProof, !hasPartialEvidence {
            return .supported
        }
        if hasPositiveEvidence {
            return .partial
        }
        return .unproven
    }

    private func status(from report: EvidenceReportSummary) -> ModelLibraryEvidenceStatus {
        switch report.artifact.availability {
        case .available:
            break
        case .unavailable:
            return .unproven
        case .error:
            return .unsupported
        }

        switch report.status {
        case .passed:
            return .supported
        case .partial:
            return .partial
        case .failed, .blocked, .error:
            return .unsupported
        case .unavailable, .unknown:
            return .unproven
        }
    }

    private func reportMatches(
        _ report: EvidenceReportSummary,
        query: ModelLibraryEvidenceQuery
    ) -> Bool {
        let identifiers = normalizedModelIdentifiers(for: query)
        guard !identifiers.isEmpty else { return false }

        let reportIdentifiers = report.metadata.reduce(into: Set<String>()) { output, element in
            guard Self.modelIdentifierKeys.contains(Self.normalizedKey(element.key)) else {
                return
            }
            for value in Self.modelIdentifierValues(from: element.value) {
                output.insert(value)
            }
        }
        return !identifiers.isDisjoint(with: reportIdentifiers)
    }

    private func normalizedModelIdentifiers(for query: ModelLibraryEvidenceQuery) -> Set<String> {
        var identifiers = query.aliases
        identifiers.insert(query.modelID)
        if let displayName = query.displayName {
            identifiers.insert(displayName)
        }
        return Set(identifiers.compactMap(Self.normalizedIdentifier))
    }

    private func tokenRates(in report: EvidenceReportSummary) -> [ModelLibraryTokenRateEvidence] {
        report.metadata.compactMap { element in
            guard Self.isTokenRateKey(element.key),
                  let tokensPerSecond = Self.parseNonNegativeDouble(element.value) else {
                return nil
            }
            return ModelLibraryTokenRateEvidence(
                reportID: report.id,
                source: report.source,
                metadataKey: element.key,
                rawValue: element.value,
                tokensPerSecond: tokensPerSecond
            )
        }
        .sorted(by: Self.sortTokenRates)
    }

    private func isGenerationReport(_ report: EvidenceReportSummary) -> Bool {
        if Self.generationProofKinds.contains(report.kind) {
            return true
        }

        if Self.metadataFlag(
            report.metadata,
            keys: [
                "generation",
                "generationproof",
                "generatestokens",
                "istokengeneration",
                "requirestokenspersecond",
                "requirestps",
                "tokenspersecondrequired",
            ]
        ) {
            return true
        }

        let evidenceRole = firstMetadataValue(
            in: report.metadata,
            keys: ["evidencerole"]
        )?.lowercased() ?? ""
        return evidenceRole.contains("generation")
            || evidenceRole.contains("runtimeproof")
            || evidenceRole.contains("liveproof")
    }

    private func memoryNotes(in report: EvidenceReportSummary) -> [ModelLibraryMemoryNote] {
        let note = firstMetadataValue(
            in: report.metadata,
            keys: [
                "memorynote",
                "memorynotes",
                "ramnote",
                "memorysafetynote",
            ]
        )
        let footprint = firstMetadataValue(
            in: report.metadata,
            keys: [
                "physicalfootprintbytes",
                "ramfootprintbytes",
                "memoryfootprintbytes",
            ]
        ).flatMap(Self.parseInt64)
        let limit = firstMetadataValue(
            in: report.metadata,
            keys: [
                "limitbytes",
                "memorylimitbytes",
                "ramlimitbytes",
            ]
        ).flatMap(Self.parseInt64)
        let explicitStatus = firstMetadataValue(
            in: report.metadata,
            keys: [
                "memorystatus",
                "ramstatus",
                "memorysafetystatus",
            ]
        ).flatMap(Self.statusValue)

        let ramWithinLimit = firstMetadataValue(
            in: report.metadata,
            keys: [
                "ramwithinlimit",
                "memorywithinlimit",
            ]
        ).flatMap(Self.booleanValue)

        guard note != nil || footprint != nil || limit != nil || explicitStatus != nil || ramWithinLimit != nil else {
            return []
        }

        let status: ModelLibraryEvidenceStatus
        if let explicitStatus {
            status = explicitStatus
        } else if let ramWithinLimit {
            status = ramWithinLimit == .truthy ? .supported : .unsupported
        } else {
            status = .partial
        }

        return [
            ModelLibraryMemoryNote(
                status: status,
                source: report.source,
                note: note ?? "Memory evidence is present in report metadata.",
                physicalFootprintBytes: footprint,
                limitBytes: limit
            )
        ]
    }

    private func firstMetadataValue(
        in metadata: [String: String],
        keys: [String]
    ) -> String? {
        for key in keys {
            let normalized = Self.normalizedKey(key)
            let matches = metadata
                .filter { element in
                    Self.normalizedKey(element.key) == normalized
                }
                .sorted { lhs, rhs in
                    lhs.key < rhs.key
                }
            if let value = matches
                .lazy
                .compactMap({ $0.value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty })
                .first {
                return value
            }
        }
        return nil
    }

    private func blockers(
        compatibility: ModelLibraryCompatibilityEvidence?,
        cacheImport: ModelLibraryCacheImportEvidence?,
        reports: [ModelLibraryEvidenceReportDigest],
        memoryNotes: [ModelLibraryMemoryNote]
    ) -> [String] {
        var blockers: [String] = []
        if let compatibility, compatibility.status == .unsupported {
            blockers.append("Compatibility preflight: \(compatibility.reason)")
        }
        if let cacheImport, cacheImport.status == .unsupported {
            blockers.append(
                "Cache/import state: import=\(cacheImport.importState.rawValue), cache=\(cacheImport.cacheState.rawValue)"
            )
        }
        blockers += reports
            .filter { $0.status == .unsupported }
            .map { "Evidence report \($0.id) is \($0.reportStatus.rawValue)." }
        blockers += memoryNotes
            .filter { $0.status == .unsupported }
            .map { "Memory evidence from \($0.source): \($0.note)" }
        return blockers.sorted()
    }

    private func warnings(
        compatibility: ModelLibraryCompatibilityEvidence?,
        cacheImport: ModelLibraryCacheImportEvidence?,
        reports: [ModelLibraryEvidenceReportDigest],
        memoryNotes: [ModelLibraryMemoryNote]
    ) -> [String] {
        var warnings: [String] = []
        if let compatibility, compatibility.status == .partial {
            warnings.append("Compatibility preflight is partial: \(compatibility.reason)")
        }
        if let cacheImport, cacheImport.status == .partial {
            warnings.append(
                "Cache/import state is partial: import=\(cacheImport.importState.rawValue), cache=\(cacheImport.cacheState.rawValue)"
            )
        }
        warnings += reports
            .filter { $0.status == .partial || $0.status == .unproven }
            .flatMap { report -> [String] in
                if report.notes.isEmpty {
                    return ["Evidence report \(report.id) is \(report.status.rawValue)."]
                }
                return report.notes.map { "Evidence report \(report.id): \($0)" }
            }
        warnings += memoryNotes
            .filter { $0.status == .partial || $0.status == .unproven }
            .map { "Memory evidence from \($0.source): \($0.note)" }
        return warnings.sorted()
    }

    private static func metadataFlag(
        _ metadata: [String: String],
        keys: Set<String>
    ) -> Bool {
        metadata.contains { element in
            keys.contains(normalizedKey(element.key)) && booleanValue(element.value) == .truthy
        }
    }

    private static func statusValue(_ rawValue: String) -> ModelLibraryEvidenceStatus? {
        let normalized = normalizedIdentifier(rawValue)?
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        switch normalized {
        case "passed", "proven", "ready", "supported", "ok":
            return .supported
        case "partial", "warning", "warnings", "blockedpending":
            return .partial
        case "blocked", "failed", "error", "unsupported":
            return .unsupported
        case "missing", "unknown", "unavailable", "unproven":
            return .unproven
        default:
            return nil
        }
    }

    private enum MetadataBoolean {
        case truthy
        case falsey
    }

    private static func booleanValue(_ rawValue: String) -> MetadataBoolean? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "y", "passed", "pass":
            return .truthy
        case "0", "false", "no", "n", "failed", "fail":
            return .falsey
        default:
            return nil
        }
    }

    private static func isTokenRateKey(_ key: String) -> Bool {
        let normalized = normalizedKey(key)
        if normalized == "tps" {
            return true
        }
        if normalized.hasSuffix("tps"), !normalized.hasSuffix("https") {
            return true
        }
        return tokenRateKeySuffixes.contains(normalized)
            || tokenRateKeySuffixes
                .subtracting(["tps"])
                .contains { normalized.hasSuffix($0) }
    }

    private static func modelIdentifierValues(from rawValue: String) -> Set<String> {
        let delimiters = CharacterSet(charactersIn: ",;|\n")
        return Set(rawValue
            .components(separatedBy: delimiters)
            .compactMap(normalizedIdentifier))
    }

    private static func normalizedIdentifier(_ rawValue: String) -> String? {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizedKey(_ key: String) -> String {
        var output = ""
        for scalar in key.lowercased().unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            output.unicodeScalars.append(scalar)
        }
        return output
    }

    private static func parseNonNegativeDouble(_ rawValue: String) -> Double? {
        guard let value = parseDouble(rawValue), value >= 0, value.isFinite else {
            return nil
        }
        return value
    }

    private static func parseInt64(_ rawValue: String) -> Int64? {
        guard let value = parseDouble(rawValue), value >= 0, value.isFinite else { return nil }
        return Int64(exactly: value.rounded())
    }

    private static func parseDouble(_ rawValue: String) -> Double? {
        let direct = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        if let value = Double(direct) {
            return value
        }

        let allowed = CharacterSet(charactersIn: "+-0123456789.eE")
        var current = ""
        for scalar in direct.unicodeScalars {
            if allowed.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if let value = Double(current) {
                return value
            } else {
                current.removeAll(keepingCapacity: true)
            }
        }
        return Double(current)
    }

    private static func sortReports(
        _ lhs: EvidenceReportSummary,
        _ rhs: EvidenceReportSummary
    ) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        if lhs.source != rhs.source {
            return lhs.source < rhs.source
        }
        if lhs.completedAt != rhs.completedAt {
            return (lhs.completedAt ?? .distantPast) > (rhs.completedAt ?? .distantPast)
        }
        return lhs.id < rhs.id
    }

    private static func sortTokenRates(
        _ lhs: ModelLibraryTokenRateEvidence,
        _ rhs: ModelLibraryTokenRateEvidence
    ) -> Bool {
        if lhs.tokensPerSecond != rhs.tokensPerSecond {
            return lhs.tokensPerSecond > rhs.tokensPerSecond
        }
        if lhs.source != rhs.source {
            return lhs.source < rhs.source
        }
        return lhs.reportID < rhs.reportID
    }

    private static func sortMemoryNotes(
        _ lhs: ModelLibraryMemoryNote,
        _ rhs: ModelLibraryMemoryNote
    ) -> Bool {
        if lhs.status.rawValue != rhs.status.rawValue {
            return lhs.status.rawValue < rhs.status.rawValue
        }
        if lhs.source != rhs.source {
            return lhs.source < rhs.source
        }
        return lhs.note < rhs.note
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
