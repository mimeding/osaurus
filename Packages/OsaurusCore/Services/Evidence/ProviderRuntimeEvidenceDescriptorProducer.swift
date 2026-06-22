//
//  ProviderRuntimeEvidenceDescriptorProducer.swift
//  osaurus
//
//  Read-only adapters from existing provider/runtime evidence models into the
//  unified evidence report registry descriptor shape.
//

import Foundation

public enum ProviderRuntimeEvidenceDescriptorProducer {
    public static func providerDiagnosticsDescriptor(
        from report: ProviderDiagnosticReport,
        artifactPath: String,
        source: String = "provider-connectivity",
        metadata: [String: String] = [:]
    ) -> EvidenceReportDescriptor {
        let counts = providerCounts(for: report.rows)
        return EvidenceReportDescriptor(
            id: providerDescriptorID(source: source, artifactPath: artifactPath, subtitle: report.subtitle),
            kind: .provider,
            source: source,
            artifactPath: artifactPath,
            status: providerStatus(for: counts),
            counts: counts,
            metadata: providerMetadata(
                report: report,
                counts: counts,
                extra: metadata
            )
        )
    }

    public static func providerDiagnosticsDescriptor(
        from report: ProviderDiagnosticReport,
        artifactURL: URL,
        source: String = "provider-connectivity",
        metadata: [String: String] = [:]
    ) -> EvidenceReportDescriptor {
        providerDiagnosticsDescriptor(
            from: report,
            artifactPath: artifactURL.path,
            source: source,
            metadata: metadata
        )
    }

    public static func runtimeProofDescriptor(
        from report: RuntimeProofClassificationReport,
        artifactPath: String,
        source: String = "runtime-proof-classification",
        metadata: [String: String] = [:]
    ) -> EvidenceReportDescriptor {
        let rows = RuntimeProofMatrixReporter.matrixRows(from: report)
        let counts = runtimeProofCounts(for: rows)
        return EvidenceReportDescriptor(
            id: runtimeProofDescriptorID(source: source, artifactPath: artifactPath),
            kind: .runtime,
            source: source,
            artifactPath: artifactPath,
            status: runtimeProofStatus(for: counts, reportPassed: report.passed),
            counts: counts,
            completedAt: date(from: report.generatedAt),
            metadata: runtimeProofMetadata(
                report: report,
                rows: rows,
                counts: counts,
                extra: metadata
            )
        )
    }

    public static func runtimeProofDescriptor(
        from report: RuntimeProofClassificationReport,
        artifactURL: URL,
        source: String = "runtime-proof-classification",
        metadata: [String: String] = [:]
    ) -> EvidenceReportDescriptor {
        runtimeProofDescriptor(
            from: report,
            artifactPath: artifactURL.path,
            source: source,
            metadata: metadata
        )
    }

    private static func providerCounts(for rows: [ProviderDiagnosticRow]) -> EvidenceReportCounts {
        let ok = rows.filter { $0.severity == .ok }.count
        let warnings = rows.filter { $0.severity == .warning }.count
        let blocked = rows.filter { $0.severity == .blocked }.count

        return EvidenceReportCounts(
            total: rows.count,
            passed: ok,
            blocked: blocked,
            warnings: warnings
        )
    }

    private static func providerStatus(for counts: EvidenceReportCounts) -> EvidenceReportStatus {
        if counts.blocked > 0 {
            return .blocked
        }
        if counts.warnings > 0 {
            return .partial
        }
        return .passed
    }

    private static func providerMetadata(
        report: ProviderDiagnosticReport,
        counts: EvidenceReportCounts,
        extra: [String: String]
    ) -> [String: String] {
        [
            "diagnostic_title": report.title,
            "diagnostic_subtitle": report.subtitle,
            "ok_rows": "\(counts.passed)",
            "warning_rows": "\(counts.warnings)",
            "blocked_rows": "\(counts.blocked)",
            "info_rows": "\(infoRowCount(in: report.rows))",
            "row_ids": report.rows.map(\.id).joined(separator: ","),
        ].merging(extra, uniquingKeysWith: { _, extra in extra })
    }

    private static func infoRowCount(in rows: [ProviderDiagnosticRow]) -> Int {
        rows.filter { $0.severity == .info }.count
    }

    private static func runtimeProofCounts(for rows: [RuntimeProofMatrixRow]) -> EvidenceReportCounts {
        EvidenceReportCounts(
            total: rows.count,
            passed: rows.filter { $0.verdict == .proven }.count,
            failed: rows.filter { $0.verdict == .failed }.count,
            blocked: rows.filter { $0.verdict == .unproven }.count,
            warnings: rows.filter { $0.verdict == .partial }.count
        )
    }

    private static func runtimeProofStatus(
        for counts: EvidenceReportCounts,
        reportPassed: Bool
    ) -> EvidenceReportStatus {
        if counts.failed > 0 {
            return .failed
        }
        if counts.blocked > 0 {
            return .blocked
        }
        if counts.warnings > 0 || !reportPassed {
            return .partial
        }
        return .passed
    }

    private static func runtimeProofMetadata(
        report: RuntimeProofClassificationReport,
        rows: [RuntimeProofMatrixRow],
        counts: EvidenceReportCounts,
        extra: [String: String]
    ) -> [String: String] {
        var metadata: [String: String] = [
            "generated_at": report.generatedAt ?? "unknown",
            "passed": "\(report.passed)",
            "proven_rows": "\(counts.passed)",
            "partial_rows": "\(counts.warnings)",
            "failed_rows": "\(counts.failed)",
            "unproven_rows": "\(counts.blocked)",
            "schema_only_rows": "\(rows.filter(\.isSchemaOnly).count)",
            "required_rows_not_proven": report.requiredRowsNotProven.joined(separator: ","),
        ]

        if let summaryPath = report.summaryPath {
            metadata["summary_path"] = summaryPath
        }
        if let manifestPath = report.manifestPath {
            metadata["manifest_path"] = manifestPath
        }
        if let artifactRoot = report.artifactRoot {
            metadata["artifact_root"] = artifactRoot
        }

        return metadata.merging(extra, uniquingKeysWith: { _, extra in extra })
    }

    private static func providerDescriptorID(
        source: String,
        artifactPath: String,
        subtitle: String
    ) -> String {
        ["provider", source, artifactPath, subtitle].joined(separator: "|")
    }

    private static func runtimeProofDescriptorID(
        source: String,
        artifactPath: String
    ) -> String {
        ["runtime", source, artifactPath].joined(separator: "|")
    }

    private static func date(from value: String?) -> Date? {
        guard let value, !value.isEmpty else {
            return nil
        }
        return ISO8601DateFormatter().date(from: value)
    }
}
