// Copyright 2026 Osaurus AI. All rights reserved.

import Foundation

/// Decoded output from `scripts/live-proof/classify-runtime-proof-summary.py`.
///
/// The classifier owns live-artifact parsing. This type intentionally models
/// only the fields needed for the read-only matrix so the UI/docs layer cannot
/// invent new proof claims from raw harness data.
public struct RuntimeProofClassificationReport: Codable, Sendable, Equatable {
    public var generatedAt: String?
    public var summaryPath: String?
    public var manifestPath: String?
    public var artifactRoot: String?
    public var verdictCounts: [String: Int]
    public var requiredRowsNotProven: [String]
    public var passed: Bool
    public var rows: [RuntimeProofClassificationRow]
    public var issueCoverage: [String: RuntimeProofIssueCoverage]

    public init(
        generatedAt: String? = nil,
        summaryPath: String? = nil,
        manifestPath: String? = nil,
        artifactRoot: String? = nil,
        verdictCounts: [String: Int] = [:],
        requiredRowsNotProven: [String] = [],
        passed: Bool = false,
        rows: [RuntimeProofClassificationRow] = [],
        issueCoverage: [String: RuntimeProofIssueCoverage] = [:]
    ) {
        self.generatedAt = generatedAt
        self.summaryPath = summaryPath
        self.manifestPath = manifestPath
        self.artifactRoot = artifactRoot
        self.verdictCounts = verdictCounts
        self.requiredRowsNotProven = requiredRowsNotProven
        self.passed = passed
        self.rows = rows
        self.issueCoverage = issueCoverage
    }

    private enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case summaryPath = "summary_path"
        case manifestPath = "manifest_path"
        case artifactRoot = "artifact_root"
        case verdictCounts = "verdict_counts"
        case requiredRowsNotProven = "required_rows_not_proven"
        case passed
        case rows
        case issueCoverage = "issue_coverage"
    }
}

public enum RuntimeProofResilienceSignal: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case tokensPerSecond = "tokens_per_second"
    case cache
    case markerLeak = "marker_leak"
    case cancellation
    case crashProof = "crash_proof"

    public var displayName: String {
        switch self {
        case .tokensPerSecond:
            return "Token/s"
        case .cache:
            return "Cache"
        case .markerLeak:
            return "Marker leak"
        case .cancellation:
            return "Cancellation"
        case .crashProof:
            return "Crash proof"
        }
    }
}

public struct RuntimeProofTokenRateEvidence: Codable, Sendable, Equatable {
    public var completionTokens: Int?
    public var elapsedSeconds: Double?
    public var tokensPerSecond: Double?

    public init(
        completionTokens: Int? = nil,
        elapsedSeconds: Double? = nil,
        tokensPerSecond: Double? = nil
    ) {
        self.completionTokens = completionTokens
        self.elapsedSeconds = elapsedSeconds
        self.tokensPerSecond = tokensPerSecond
    }

    private enum CodingKeys: String, CodingKey {
        case completionTokens = "completion_tokens"
        case elapsedSeconds = "elapsed_seconds"
        case tokensPerSecond = "tokens_per_second"
    }
}

public struct RuntimeProofSignalEvidence: Codable, Sendable, Equatable {
    public var verdict: RuntimeProofVerdict
    public var summary: String
    public var evidencePaths: [String]
    public var metrics: [String: Double]

    public init(
        verdict: RuntimeProofVerdict = .unproven,
        summary: String = "",
        evidencePaths: [String] = [],
        metrics: [String: Double] = [:]
    ) {
        self.verdict = verdict
        self.summary = summary
        self.evidencePaths = evidencePaths
        self.metrics = metrics
    }

    private enum CodingKeys: String, CodingKey {
        case verdict
        case summary
        case evidencePaths = "evidence_paths"
        case metrics
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.verdict = try container.decodeIfPresent(RuntimeProofVerdict.self, forKey: .verdict) ?? .unproven
        self.summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        self.evidencePaths = try container.decodeIfPresent([String].self, forKey: .evidencePaths) ?? []
        self.metrics = try container.decodeIfPresent([String: Double].self, forKey: .metrics) ?? [:]
    }
}

public struct RuntimeProofClassificationRow: Codable, Sendable, Equatable {
    public var id: String
    public var model: String?
    public var family: String?
    public var priority: String?
    public var requirements: [String]
    public var artifactPaths: [String]
    public var summaryPath: String?
    public var verdict: RuntimeProofVerdict
    public var acceptableForProvenClaim: Bool
    public var blockers: [RuntimeProofMatrixMessage]
    public var warnings: [RuntimeProofMatrixMessage]
    public var failedChecks: [String]
    public var cacheDelta: [String: Double]
    public var tokenRates: [String: RuntimeProofTokenRateEvidence]
    public var resilienceEvidence: [String: RuntimeProofSignalEvidence]

    public init(
        id: String,
        model: String? = nil,
        family: String? = nil,
        priority: String? = nil,
        requirements: [String] = [],
        artifactPaths: [String] = [],
        summaryPath: String? = nil,
        verdict: RuntimeProofVerdict,
        acceptableForProvenClaim: Bool = false,
        blockers: [RuntimeProofMatrixMessage] = [],
        warnings: [RuntimeProofMatrixMessage] = [],
        failedChecks: [String] = [],
        cacheDelta: [String: Double] = [:],
        tokenRates: [String: RuntimeProofTokenRateEvidence] = [:],
        resilienceEvidence: [String: RuntimeProofSignalEvidence] = [:]
    ) {
        self.id = id
        self.model = model
        self.family = family
        self.priority = priority
        self.requirements = requirements
        self.artifactPaths = artifactPaths
        self.summaryPath = summaryPath
        self.verdict = verdict
        self.acceptableForProvenClaim = acceptableForProvenClaim
        self.blockers = blockers
        self.warnings = warnings
        self.failedChecks = failedChecks
        self.cacheDelta = cacheDelta
        self.tokenRates = tokenRates
        self.resilienceEvidence = resilienceEvidence
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case model
        case family
        case priority
        case requirements
        case artifactPaths = "artifact_paths"
        case summaryPath = "summary_path"
        case verdict
        case acceptableForProvenClaim = "acceptable_for_proven_claim"
        case blockers
        case warnings
        case failedChecks = "failed_checks"
        case cacheDelta = "cache_delta"
        case tokenRates = "token_rates"
        case resilienceEvidence = "resilience_evidence"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.family = try container.decodeIfPresent(String.self, forKey: .family)
        self.priority = try container.decodeIfPresent(String.self, forKey: .priority)
        self.requirements = try container.decodeIfPresent([String].self, forKey: .requirements) ?? []
        self.artifactPaths = try container.decodeIfPresent([String].self, forKey: .artifactPaths) ?? []
        self.summaryPath = try container.decodeIfPresent(String.self, forKey: .summaryPath)
        self.verdict = try container.decodeIfPresent(RuntimeProofVerdict.self, forKey: .verdict) ?? .unproven
        self.acceptableForProvenClaim =
            try container.decodeIfPresent(Bool.self, forKey: .acceptableForProvenClaim) ?? false
        self.blockers = try container.decodeIfPresent([RuntimeProofMatrixMessage].self, forKey: .blockers) ?? []
        self.warnings = try container.decodeIfPresent([RuntimeProofMatrixMessage].self, forKey: .warnings) ?? []
        self.failedChecks = try container.decodeIfPresent([String].self, forKey: .failedChecks) ?? []
        self.cacheDelta = try container.decodeIfPresent([String: Double].self, forKey: .cacheDelta) ?? [:]
        self.tokenRates =
            try container.decodeIfPresent([String: RuntimeProofTokenRateEvidence].self, forKey: .tokenRates) ?? [:]
        self.resilienceEvidence =
            try container.decodeIfPresent(
                [String: RuntimeProofSignalEvidence].self,
                forKey: .resilienceEvidence
            ) ?? [:]
    }
}

public struct RuntimeProofIssueCoverage: Codable, Sendable, Equatable {
    public var verdict: RuntimeProofVerdict
    public var note: String
    public var rows: [String]
    public var requiredRowsNotProven: [String]

    public init(
        verdict: RuntimeProofVerdict,
        note: String,
        rows: [String] = [],
        requiredRowsNotProven: [String] = []
    ) {
        self.verdict = verdict
        self.note = note
        self.rows = rows
        self.requiredRowsNotProven = requiredRowsNotProven
    }

    private enum CodingKeys: String, CodingKey {
        case verdict
        case note
        case rows
        case requiredRowsNotProven = "required_rows_not_proven"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.verdict = try container.decode(RuntimeProofVerdict.self, forKey: .verdict)
        self.note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        self.rows = try container.decodeIfPresent([String].self, forKey: .rows) ?? []
        self.requiredRowsNotProven =
            try container.decodeIfPresent([String].self, forKey: .requiredRowsNotProven) ?? []
    }
}

public struct RuntimeProofMatrixMessage: Codable, Sendable, Equatable {
    public var requirement: String?
    public var message: String

    public init(requirement: String? = nil, message: String) {
        self.requirement = requirement
        self.message = message
    }
}

public struct RuntimeProofMatrixRow: Codable, Sendable, Equatable {
    public var id: String
    public var model: String
    public var family: String
    public var priority: String
    public var verdict: RuntimeProofVerdict
    public var requirements: [String]
    public var evidencePointers: [String]
    public var blockers: [String]
    public var isSchemaOnly: Bool

    public init(
        id: String,
        model: String,
        family: String,
        priority: String,
        verdict: RuntimeProofVerdict,
        requirements: [String],
        evidencePointers: [String],
        blockers: [String],
        isSchemaOnly: Bool = false
    ) {
        self.id = id
        self.model = model
        self.family = family
        self.priority = priority
        self.verdict = verdict
        self.requirements = requirements
        self.evidencePointers = evidencePointers
        self.blockers = blockers
        self.isSchemaOnly = isSchemaOnly
    }
}

public struct RuntimeProofMatrixSurface: Codable, Sendable, Equatable {
    public var generatedAt: String
    public var sourceClassificationPath: String?
    public var artifactRoot: String?
    public var verdictCounts: [String: Int]
    public var rows: [RuntimeProofMatrixRow]
    public var issueCoverage: [String: RuntimeProofIssueCoverage]

    public init(
        generatedAt: String,
        sourceClassificationPath: String?,
        artifactRoot: String?,
        verdictCounts: [String: Int],
        rows: [RuntimeProofMatrixRow],
        issueCoverage: [String: RuntimeProofIssueCoverage]
    ) {
        self.generatedAt = generatedAt
        self.sourceClassificationPath = sourceClassificationPath
        self.artifactRoot = artifactRoot
        self.verdictCounts = verdictCounts
        self.rows = rows
        self.issueCoverage = issueCoverage
    }
}

public struct RuntimeResilienceDashboardRow: Codable, Sendable, Equatable {
    public var id: String
    public var model: String
    public var family: String
    public var priority: String
    public var verdict: RuntimeProofVerdict
    public var signalEvidence: [String: RuntimeProofSignalEvidence]
    public var evidencePointers: [String]
    public var blockers: [String]
    public var failedChecks: [String]
    public var isSchemaOnly: Bool

    public init(
        id: String,
        model: String,
        family: String,
        priority: String,
        verdict: RuntimeProofVerdict,
        signalEvidence: [String: RuntimeProofSignalEvidence],
        evidencePointers: [String],
        blockers: [String],
        failedChecks: [String] = [],
        isSchemaOnly: Bool = false
    ) {
        self.id = id
        self.model = model
        self.family = family
        self.priority = priority
        self.verdict = verdict
        self.signalEvidence = signalEvidence
        self.evidencePointers = evidencePointers
        self.blockers = blockers
        self.failedChecks = failedChecks
        self.isSchemaOnly = isSchemaOnly
    }
}

public struct RuntimeResilienceDashboardSurface: Codable, Sendable, Equatable {
    public var generatedAt: String
    public var sourceClassificationPath: String?
    public var artifactRoot: String?
    public var verdictCounts: [String: Int]
    public var signalCounts: [String: [String: Int]]
    public var rows: [RuntimeResilienceDashboardRow]
    public var issueCoverage: [String: RuntimeProofIssueCoverage]

    public init(
        generatedAt: String,
        sourceClassificationPath: String?,
        artifactRoot: String?,
        verdictCounts: [String: Int],
        signalCounts: [String: [String: Int]],
        rows: [RuntimeResilienceDashboardRow],
        issueCoverage: [String: RuntimeProofIssueCoverage]
    ) {
        self.generatedAt = generatedAt
        self.sourceClassificationPath = sourceClassificationPath
        self.artifactRoot = artifactRoot
        self.verdictCounts = verdictCounts
        self.signalCounts = signalCounts
        self.rows = rows
        self.issueCoverage = issueCoverage
    }
}

public enum RuntimeProofMatrixReporter {
    public static let markdownBeginMarker = "<!-- BEGIN RUNTIME PROOF MATRIX -->"
    public static let markdownEndMarker = "<!-- END RUNTIME PROOF MATRIX -->"
    public static let dashboardMarkdownBeginMarker = "<!-- BEGIN RUNTIME RESILIENCE DASHBOARD -->"
    public static let dashboardMarkdownEndMarker = "<!-- END RUNTIME RESILIENCE DASHBOARD -->"

    public static func decodeClassification(data: Data) throws -> RuntimeProofClassificationReport {
        let decoder = JSONDecoder()
        return try decoder.decode(RuntimeProofClassificationReport.self, from: data)
    }

    public static func surface(
        from report: RuntimeProofClassificationReport,
        sourceClassificationPath: String? = nil,
        generatedAt: String? = nil
    ) -> RuntimeProofMatrixSurface {
        let rows = matrixRows(from: report)
        return RuntimeProofMatrixSurface(
            generatedAt: generatedAt ?? report.generatedAt ?? "unknown",
            sourceClassificationPath: sourceClassificationPath,
            artifactRoot: report.artifactRoot,
            verdictCounts: verdictCounts(for: rows),
            rows: rows,
            issueCoverage: report.issueCoverage
        )
    }

    public static func matrixRows(from report: RuntimeProofClassificationReport) -> [RuntimeProofMatrixRow] {
        let liveRows = report.rows.map(matrixRow(from:))
        let existing = Set(liveRows.map(\.id))
        let schemaRows = requiredSchemaRows.filter { !existing.contains($0.id) }
        return (liveRows + schemaRows).sorted(by: rowSort)
    }

    public static func dashboardSurface(
        from report: RuntimeProofClassificationReport,
        sourceClassificationPath: String? = nil,
        generatedAt: String? = nil
    ) -> RuntimeResilienceDashboardSurface {
        let rows = dashboardRows(from: report)
        return RuntimeResilienceDashboardSurface(
            generatedAt: generatedAt ?? report.generatedAt ?? "unknown",
            sourceClassificationPath: sourceClassificationPath,
            artifactRoot: report.artifactRoot,
            verdictCounts: verdictCounts(for: rows),
            signalCounts: signalCounts(for: rows),
            rows: rows,
            issueCoverage: report.issueCoverage
        )
    }

    public static func dashboardRows(from report: RuntimeProofClassificationReport)
        -> [RuntimeResilienceDashboardRow]
    {
        let liveRows = report.rows.map(dashboardRow(from:))
        let existing = Set(liveRows.map(\.id))
        let schemaRows = requiredSchemaRows
            .filter { !existing.contains($0.id) }
            .map(dashboardRow(fromSchemaRow:))
        return (liveRows + schemaRows).sorted(by: dashboardRowSort)
    }

    public static func dashboardMarkdown(
        from report: RuntimeProofClassificationReport,
        sourceClassificationPath: String? = nil,
        generatedAt: String? = nil
    ) -> String {
        let surface = dashboardSurface(
            from: report,
            sourceClassificationPath: sourceClassificationPath,
            generatedAt: generatedAt
        )
        let source = surface.sourceClassificationPath ?? report.summaryPath ?? "PROOF_CLASSIFICATION.json"
        let verdictSummary = RuntimeProofVerdict.allCases
            .map { "\($0.rawValue)=\(surface.verdictCounts[$0.rawValue, default: 0])" }
            .joined(separator: ", ")
        let signalSummary = RuntimeProofResilienceSignal.allCases
            .map { signal -> String in
                let counts = surface.signalCounts[signal.rawValue, default: [:]]
                let values = RuntimeProofVerdict.allCases
                    .map { "\($0.rawValue)=\(counts[$0.rawValue, default: 0])" }
                    .joined(separator: ", ")
                return "\(signal.displayName) \(values)"
            }
            .joined(separator: "; ")
        let crashCoverage = surface.issueCoverage["#1228"]

        var lines: [String] = [
            dashboardMarkdownBeginMarker,
            "",
            "Generated from \(escapeMarkdown(source)) at \(escapeMarkdown(surface.generatedAt)).",
            "",
            "Verdicts: \(escapeMarkdown(verdictSummary))",
            "",
            "Signals: \(escapeMarkdown(signalSummary))",
            "",
            "Crash/cancellation issue coverage: \(escapeMarkdown(crashCoverage?.verdict.rawValue ?? "unproven")) - \(escapeMarkdown(crashCoverage?.note ?? "not recorded"))",
            "",
            "| Row | Model | Verdict | Token/s | Cache | Marker leak | Cancellation | Crash proof | Blockers |",
            "|---|---|---|---|---|---|---|---|---|",
        ]
        for row in surface.rows {
            lines.append(
                [
                    row.id,
                    row.model,
                    row.verdict.rawValue,
                    signalCell(row, .tokensPerSecond),
                    signalCell(row, .cache),
                    signalCell(row, .markerLeak),
                    signalCell(row, .cancellation),
                    signalCell(row, .crashProof),
                    row.blockers.isEmpty ? "none" : row.blockers.joined(separator: "<br>"),
                ]
                .map(escapeMarkdown)
                .joined(separator: " | ")
                .withMarkdownTablePipes()
            )
        }
        lines.append("")
        lines.append(dashboardMarkdownEndMarker)
        return lines.joined(separator: "\n") + "\n"
    }

    public static func markdownMatrix(
        from report: RuntimeProofClassificationReport,
        sourceClassificationPath: String? = nil,
        generatedAt: String? = nil
    ) -> String {
        let surface = surface(
            from: report,
            sourceClassificationPath: sourceClassificationPath,
            generatedAt: generatedAt
        )
        var lines: [String] = [
            markdownBeginMarker,
            "",
            "Generated from \(escapeMarkdown(surface.sourceClassificationPath ?? report.summaryPath ?? "PROOF_CLASSIFICATION.json")) at \(escapeMarkdown(surface.generatedAt)).",
            "",
            "| Row | Model | Family | Verdict | Requirements | Evidence | Blockers |",
            "|---|---|---|---|---|---|---|",
        ]
        for row in surface.rows {
            lines.append(
                [
                    row.id,
                    row.model,
                    row.family,
                    row.verdict.rawValue,
                    row.requirements.joined(separator: ", "),
                    row.evidencePointers.isEmpty ? "none" : row.evidencePointers.joined(separator: "<br>"),
                    row.blockers.isEmpty ? "none" : row.blockers.joined(separator: "<br>"),
                ]
                .map(escapeMarkdown)
                .joined(separator: " | ")
                .withMarkdownTablePipes()
            )
        }
        lines.append("")
        lines.append(markdownEndMarker)
        return lines.joined(separator: "\n") + "\n"
    }

    public static func replaceMarkedMatrix(in document: String, with matrixMarkdown: String) -> String {
        guard
            let begin = document.range(of: markdownBeginMarker),
            let end = document.range(of: markdownEndMarker, range: begin.upperBound ..< document.endIndex)
        else {
            let separator = document.hasSuffix("\n") ? "\n" : "\n\n"
            return document + separator + matrixMarkdown
        }
        return String(document[..<begin.lowerBound]) + matrixMarkdown + String(document[end.upperBound...])
    }

    private static func matrixRow(from row: RuntimeProofClassificationRow) -> RuntimeProofMatrixRow {
        let evidence = uniqueNonEmpty([row.summaryPath].compactMap { $0 } + row.artifactPaths)
        let blockers = row.blockers.map { message in
            if let requirement = message.requirement, !requirement.isEmpty {
                return "\(requirement): \(message.message)"
            }
            return message.message
        }
        return RuntimeProofMatrixRow(
            id: row.id,
            model: row.model ?? row.id,
            family: row.family ?? "unknown",
            priority: row.priority ?? "unspecified",
            verdict: row.verdict,
            requirements: normalizedRequirements(row.requirements),
            evidencePointers: evidence,
            blockers: blockers,
            isSchemaOnly: false
        )
    }

    private static func dashboardRow(from row: RuntimeProofClassificationRow) -> RuntimeResilienceDashboardRow {
        let evidence = uniqueNonEmpty([row.summaryPath].compactMap { $0 } + row.artifactPaths)
        let blockers = blockerStrings(from: row.blockers)
        let signalEvidence = Dictionary(
            uniqueKeysWithValues: RuntimeProofResilienceSignal.allCases.map { signal in
                (
                    signal.rawValue,
                    normalizedSignalEvidence(
                        signal,
                        row: row,
                        fallbackEvidence: evidence
                    )
                )
            }
        )
        return RuntimeResilienceDashboardRow(
            id: row.id,
            model: row.model ?? row.id,
            family: row.family ?? "unknown",
            priority: row.priority ?? "unspecified",
            verdict: row.verdict,
            signalEvidence: signalEvidence,
            evidencePointers: evidence,
            blockers: blockers,
            failedChecks: row.failedChecks,
            isSchemaOnly: false
        )
    }

    private static func dashboardRow(fromSchemaRow row: RuntimeProofMatrixRow) -> RuntimeResilienceDashboardRow {
        let signalEvidence = Dictionary(
            uniqueKeysWithValues: RuntimeProofResilienceSignal.allCases.map { signal in
                (
                    signal.rawValue,
                    RuntimeProofSignalEvidence(
                        verdict: .unproven,
                        summary: schemaSignalSummary(signal, requirements: row.requirements),
                        evidencePaths: []
                    )
                )
            }
        )
        return RuntimeResilienceDashboardRow(
            id: row.id,
            model: row.model,
            family: row.family,
            priority: row.priority,
            verdict: row.verdict,
            signalEvidence: signalEvidence,
            evidencePointers: row.evidencePointers,
            blockers: row.blockers,
            isSchemaOnly: true
        )
    }

    private static func normalizedSignalEvidence(
        _ signal: RuntimeProofResilienceSignal,
        row: RuntimeProofClassificationRow,
        fallbackEvidence: [String]
    ) -> RuntimeProofSignalEvidence {
        if let evidence = row.resilienceEvidence[signal.rawValue] {
            var normalized = evidence
            if normalized.evidencePaths.isEmpty {
                normalized.evidencePaths = fallbackEvidence
            }
            return normalized
        }
        return fallbackSignalEvidence(signal, row: row, fallbackEvidence: fallbackEvidence)
    }

    private static func fallbackSignalEvidence(
        _ signal: RuntimeProofResilienceSignal,
        row: RuntimeProofClassificationRow,
        fallbackEvidence: [String]
    ) -> RuntimeProofSignalEvidence {
        let requirements = Set(row.requirements)
        let blockers = blockerStrings(from: row.blockers)
        let rowFailed = row.verdict == .failed

        switch signal {
        case .tokensPerSecond:
            if let best = bestTokenRate(row.tokenRates) {
                return RuntimeProofSignalEvidence(
                    verdict: .proven,
                    summary: "\(best.turn): \(String(format: "%.2f", best.rate)) token/s",
                    evidencePaths: fallbackEvidence
                )
            }
            return RuntimeProofSignalEvidence(
                verdict: rowFailed ? .failed : .partial,
                summary: blockers.first { $0.hasPrefix("tokens_per_second:") } ?? "no positive token/s was recorded",
                evidencePaths: fallbackEvidence
        )
        case .cache:
            if requirements.contains("cache_hit") {
                let hasCacheBlocker = blockers.contains { $0.hasPrefix("cache_hit:") }
                let verdict: RuntimeProofVerdict = hasCacheBlocker ? (rowFailed ? .failed : .partial) : .proven
                return RuntimeProofSignalEvidence(
                    verdict: verdict,
                    summary: verdict == .proven
                        ? "topology-specific cache evidence passed"
                        : "required topology-specific cache evidence is incomplete",
                    evidencePaths: fallbackEvidence,
                    metrics: row.cacheDelta
                )
            }
            if !row.cacheDelta.isEmpty {
                return RuntimeProofSignalEvidence(
                    verdict: .partial,
                    summary: "cache counters were recorded, but this row does not require cache-hit proof",
                    evidencePaths: fallbackEvidence,
                    metrics: row.cacheDelta
                )
            }
            return RuntimeProofSignalEvidence(
                verdict: .unproven,
                summary: "no cache evidence was recorded for this row",
                evidencePaths: fallbackEvidence
            )
        case .markerLeak:
            if blockers.contains(where: { $0.hasPrefix("no_parser_marker_leak:") }) {
                return RuntimeProofSignalEvidence(
                    verdict: rowFailed ? .failed : .partial,
                    summary: "parser/runtime marker leak checks failed",
                    evidencePaths: fallbackEvidence
                )
            }
            let verdict: RuntimeProofVerdict = requirements.contains("no_parser_marker_leak") ? .proven : .unproven
            return RuntimeProofSignalEvidence(
                verdict: verdict,
                summary: verdict == .proven
                    ? "no parser/runtime marker leak detected in recorded output"
                    : "marker-leak evidence was not recorded",
                evidencePaths: fallbackEvidence
            )
        case .cancellation:
            return RuntimeProofSignalEvidence(
                verdict: .unproven,
                summary: "no cancellation cleanup proof was recorded for this row",
                evidencePaths: fallbackEvidence
            )
        case .crashProof:
            return RuntimeProofSignalEvidence(
                verdict: rowFailed ? .failed : .unproven,
                summary: rowFailed
                    ? "row failed or server health did not survive the proof run"
                    : "no crash/health evidence was recorded for this row",
                evidencePaths: fallbackEvidence
            )
        }
    }

    private static func schemaSignalSummary(
        _ signal: RuntimeProofResilienceSignal,
        requirements: [String]
    ) -> String {
        switch signal {
        case .tokensPerSecond:
            return requirements.contains("tokens_per_second")
                ? "requires a live artifact with token/s"
                : "token/s evidence is not part of this schema row"
        case .cache:
            return requirements.contains("cache_hit")
                ? "requires topology-specific cache evidence"
                : "cache evidence is not part of this schema row"
        case .markerLeak:
            return requirements.contains("no_parser_marker_leak")
                ? "requires live output without parser/runtime marker leakage"
                : "marker-leak evidence is not part of this schema row"
        case .cancellation:
            return "requires live cancellation cleanup evidence before it can be proven"
        case .crashProof:
            return "requires crash/health artifacts before it can be proven"
        }
    }

    private static func bestTokenRate(_ rates: [String: RuntimeProofTokenRateEvidence]) -> (turn: String, rate: Double)? {
        rates.compactMap { key, value -> (String, Double)? in
            guard let tokens = value.completionTokens, tokens > 0, let rate = value.tokensPerSecond, rate > 0 else {
                return nil
            }
            return (key, rate)
        }
        .max { lhs, rhs in lhs.1 < rhs.1 }
    }

    private static func signalCell(
        _ row: RuntimeResilienceDashboardRow,
        _ signal: RuntimeProofResilienceSignal
    ) -> String {
        let evidence = row.signalEvidence[signal.rawValue] ?? RuntimeProofSignalEvidence()
        return "\(evidence.verdict.rawValue): \(evidence.summary)<br>\(markdownLinks(evidence.evidencePaths))"
    }

    private static func markdownLinks(_ paths: [String], limit: Int = 3) -> String {
        let unique = uniqueNonEmpty(paths)
        guard !unique.isEmpty else { return "no links" }
        var links = unique.prefix(limit).enumerated().map { index, path in
            "[\(index + 1)](\(path))"
        }
        if unique.count > limit {
            links.append("+\(unique.count - limit) more")
        }
        return links.joined(separator: ", ")
    }

    private static func blockerStrings(from messages: [RuntimeProofMatrixMessage]) -> [String] {
        messages.map { message in
            if let requirement = message.requirement, !requirement.isEmpty {
                return "\(requirement): \(message.message)"
            }
            return message.message
        }
    }

    private static let requiredSchemaRows: [RuntimeProofMatrixRow] = [
        RuntimeProofMatrixRow(
            id: "issue-903-system-prompt-injection-schema",
            model: "all local chat runtimes",
            family: "cross-family",
            priority: "schema-required",
            verdict: .unproven,
            requirements: [
                "visible_output",
                "tokens_per_second",
                "no_parser_marker_leak",
                "multi_turn_coherency",
                "system_prompt_injection",
            ],
            evidencePointers: [],
            blockers: [
                "requires a live artifact with an explicit system-prompt injection probe, visible output, token/s, multi-turn coherency, and no parser marker leakage"
            ],
            isSchemaOnly: true
        ),
        RuntimeProofMatrixRow(
            id: "issue-1163-hy3-harmony-retro-validation-schema",
            model: "Hy3/harmony local rows",
            family: "hy3",
            priority: "schema-required",
            verdict: .unproven,
            requirements: [
                "visible_output",
                "tokens_per_second",
                "no_parser_marker_leak",
                "multi_turn_coherency",
            ],
            evidencePointers: [],
            blockers: [
                "requires a Hy3/harmony live artifact; sibling model rows or source-only parser checks do not prove this issue"
            ],
            isSchemaOnly: true
        ),
    ]

    private static func normalizedRequirements(_ requirements: [String]) -> [String] {
        requirements
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
    }

    private static func uniqueNonEmpty(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values where !value.isEmpty && !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }
        return result
    }

    private static func verdictCounts(for rows: [RuntimeProofMatrixRow]) -> [String: Int] {
        Dictionary(grouping: rows, by: { $0.verdict.rawValue })
            .mapValues(\.count)
            .merging(
                Dictionary(uniqueKeysWithValues: RuntimeProofVerdict.allCases.map { ($0.rawValue, 0) }),
                uniquingKeysWith: { lhs, _ in lhs }
            )
    }

    private static func verdictCounts(for rows: [RuntimeResilienceDashboardRow]) -> [String: Int] {
        Dictionary(grouping: rows, by: { $0.verdict.rawValue })
            .mapValues(\.count)
            .merging(
                Dictionary(uniqueKeysWithValues: RuntimeProofVerdict.allCases.map { ($0.rawValue, 0) }),
                uniquingKeysWith: { lhs, _ in lhs }
            )
    }

    private static func signalCounts(for rows: [RuntimeResilienceDashboardRow]) -> [String: [String: Int]] {
        Dictionary(
            uniqueKeysWithValues: RuntimeProofResilienceSignal.allCases.map { signal in
                let verdicts = rows.map {
                    $0.signalEvidence[signal.rawValue]?.verdict.rawValue ?? RuntimeProofVerdict.unproven.rawValue
                }
                let counts = Dictionary(grouping: verdicts, by: { $0 })
                    .mapValues(\.count)
                    .merging(
                        Dictionary(uniqueKeysWithValues: RuntimeProofVerdict.allCases.map { ($0.rawValue, 0) }),
                        uniquingKeysWith: { lhs, _ in lhs }
                    )
                return (signal.rawValue, counts)
            }
        )
    }

    private static func rowSort(_ lhs: RuntimeProofMatrixRow, _ rhs: RuntimeProofMatrixRow) -> Bool {
        let left = [lhs.family, lhs.model, lhs.id]
        let right = [rhs.family, rhs.model, rhs.id]
        return left.lexicographicallyPrecedes(right)
    }

    private static func dashboardRowSort(
        _ lhs: RuntimeResilienceDashboardRow,
        _ rhs: RuntimeResilienceDashboardRow
    ) -> Bool {
        let left = [lhs.family, lhs.model, lhs.id]
        let right = [rhs.family, rhs.model, rhs.id]
        return left.lexicographicallyPrecedes(right)
    }

    private static func escapeMarkdown(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "|", with: "\\|")
    }
}

extension String {
    fileprivate func withMarkdownTablePipes() -> String {
        "| \(self) |"
    }
}
