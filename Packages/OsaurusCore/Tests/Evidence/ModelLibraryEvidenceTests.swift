//
//  ModelLibraryEvidenceTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Model library evidence center")
struct ModelLibraryEvidenceTests {
    @Test
    func supportedRuntimeProofRequiresPositiveTokenRate() throws {
        let fixture = try ModelEvidenceFixture()
        let report = try fixture.registerReport(
            kind: .liveProof,
            status: .passed,
            metadata: [
                "model_id": "osaurus/gemma4-jang4m",
                "usage.tokens_per_second": "29.1 tok/s",
            ]
        )
        let service = ModelLibraryEvidenceService()

        let snapshot = service.snapshot(
            for: ModelLibraryEvidenceQuery(modelID: "osaurus/gemma4-jang4m"),
            reports: [report]
        )

        #expect(snapshot.status == .supported)
        #expect(snapshot.reports.map(\.status) == [.supported])
        #expect(snapshot.tokenRates.map(\.tokensPerSecond) == [29.1])
        #expect(snapshot.warnings.isEmpty)
    }

    @Test
    func passedGenerationReportWithoutTokenRateDowngradesToPartial() throws {
        let fixture = try ModelEvidenceFixture()
        let report = try fixture.registerReport(
            kind: .benchmark,
            status: .passed,
            metadata: [
                "model_id": "osaurus/qwen-mxfp4",
            ]
        )
        let service = ModelLibraryEvidenceService()

        let snapshot = service.snapshot(
            for: ModelLibraryEvidenceQuery(modelID: "osaurus/qwen-mxfp4"),
            reports: [report]
        )

        #expect(snapshot.status == .partial)
        #expect(snapshot.reports.map(\.status) == [.partial])
        #expect(snapshot.tokenRates.isEmpty)
        #expect(snapshot.warnings.contains { $0.contains("missing token/s") })
    }

    @Test
    func missingEvidenceStaysUnproven() throws {
        let fixture = try ModelEvidenceFixture()
        let missingReport = fixture.registerMissingReport(
            kind: .runtime,
            status: .passed,
            metadata: [
                "model_id": "osaurus/missing-proof",
                "tokens_per_second": "17.2",
            ]
        )
        let service = ModelLibraryEvidenceService()

        let noMatch = service.snapshot(
            for: ModelLibraryEvidenceQuery(modelID: "osaurus/no-evidence"),
            reports: [missingReport]
        )
        let missingArtifact = service.snapshot(
            for: ModelLibraryEvidenceQuery(modelID: "osaurus/missing-proof"),
            reports: [missingReport]
        )

        #expect(noMatch.status == .unproven)
        #expect(noMatch.reports.isEmpty)
        #expect(missingArtifact.status == .unproven)
        #expect(missingArtifact.reports.map(\.artifactAvailability) == [.unavailable])
        #expect(missingArtifact.reports.map(\.status) == [.unproven])
    }

    @Test
    func cacheImportStateAggregatesConservatively() {
        let service = ModelLibraryEvidenceService()
        let partialCache = ModelLibraryEvidenceContext(
            cacheImport: ModelLibraryCacheImportEvidence(
                importState: .downloaded,
                cacheState: .enabledNoHit,
                source: "model-detail"
            )
        )
        let failedImport = ModelLibraryEvidenceContext(
            cacheImport: ModelLibraryCacheImportEvidence(
                importState: .failed,
                cacheState: .hitProven,
                source: "model-detail"
            )
        )

        let partial = service.snapshot(
            for: ModelLibraryEvidenceQuery(modelID: "osaurus/cache-partial"),
            context: partialCache,
            reports: []
        )
        let unsupported = service.snapshot(
            for: ModelLibraryEvidenceQuery(modelID: "osaurus/cache-failed"),
            context: failedImport,
            reports: []
        )

        #expect(partial.cacheImport?.status == .partial)
        #expect(partial.status == .partial)
        #expect(partial.warnings.contains { $0.contains("Cache/import state is partial") })
        #expect(unsupported.cacheImport?.status == .unsupported)
        #expect(unsupported.status == .unsupported)
        #expect(unsupported.blockers.contains { $0.contains("Cache/import state") })
    }

    @Test
    func unsupportedPreflightDominatesPassedProofWithoutCoercingReportDigest() throws {
        let fixture = try ModelEvidenceFixture()
        let report = try fixture.registerReport(
            kind: .liveProof,
            status: .passed,
            metadata: [
                "model_id": "osaurus/longcat",
                "tokens_per_second": "9.4",
            ]
        )
        let context = ModelLibraryEvidenceContext(
            compatibility: ModelLibraryCompatibilityEvidence(
                status: .unsupported,
                reason: "unsupportedLongCat",
                detail: "Native runtime support is not available."
            )
        )
        let service = ModelLibraryEvidenceService()

        let snapshot = service.snapshot(
            for: ModelLibraryEvidenceQuery(modelID: "osaurus/longcat"),
            context: context,
            reports: [report]
        )

        #expect(snapshot.status == .unsupported)
        #expect(snapshot.reports.map(\.status) == [.supported])
        #expect(snapshot.blockers.contains { $0.contains("Compatibility preflight") })
    }

    @Test
    func failedReportsAndMemoryLimitFailuresAreUnsupported() throws {
        let fixture = try ModelEvidenceFixture()
        let failedReport = try fixture.registerReport(
            kind: .runtime,
            status: .failed,
            metadata: [
                "model_id": "osaurus/memory-row",
                "tokens_per_second": "0",
                "memory_note": "Physical footprint exceeded the configured limit.",
                "ram_within_limit": "false",
            ]
        )
        let service = ModelLibraryEvidenceService()

        let snapshot = service.snapshot(
            for: ModelLibraryEvidenceQuery(modelID: "osaurus/memory-row"),
            reports: [failedReport]
        )

        #expect(snapshot.status == .unsupported)
        #expect(snapshot.reports.map(\.status) == [.unsupported])
        #expect(snapshot.memoryNotes.map(\.status) == [.unsupported])
        #expect(snapshot.blockers.contains { $0.contains("Physical footprint exceeded") })
    }

    @Test
    func malformedNumericMetadataDoesNotTrapOrPromoteProof() throws {
        let fixture = try ModelEvidenceFixture()
        let report = try fixture.registerReport(
            kind: .liveProof,
            status: .passed,
            metadata: [
                "model_id": "osaurus/malformed-numbers",
                "tokens_per_second": "1e309",
                "physical_footprint_bytes": "1e30",
                "memory_limit_bytes": "NaN",
                "ram_within_limit": "true",
            ]
        )
        let service = ModelLibraryEvidenceService()

        let snapshot = service.snapshot(
            for: ModelLibraryEvidenceQuery(modelID: "osaurus/malformed-numbers"),
            reports: [report]
        )

        #expect(snapshot.status == .partial)
        #expect(snapshot.reports.map(\.status) == [.partial])
        #expect(snapshot.tokenRates.isEmpty)
        #expect(snapshot.memoryNotes.map(\.physicalFootprintBytes) == [nil])
        #expect(snapshot.memoryNotes.map(\.limitBytes) == [nil])
        #expect(snapshot.warnings.contains { $0.contains("missing token/s") })
    }

    @Test
    func metadataLookupUsesDeterministicPrecedence() throws {
        let fixture = try ModelEvidenceFixture()
        let report = try fixture.registerReport(
            kind: .runtime,
            status: .passed,
            metadata: [
                "model_id": "osaurus/memory-precedence",
                "tokens_per_second": "21.5",
                "memory_note": "Preferred memory note.",
                "ram_note": "Fallback RAM note.",
                "ram_within_limit": "true",
            ]
        )
        let service = ModelLibraryEvidenceService()

        let snapshot = service.snapshot(
            for: ModelLibraryEvidenceQuery(modelID: "osaurus/memory-precedence"),
            reports: [report]
        )

        #expect(snapshot.status == .supported)
        #expect(snapshot.memoryNotes.map(\.note) == ["Preferred memory note."])
    }

    @Test
    func exactTPSKeyAndAliasesCanSupportRuntimeProof() throws {
        let fixture = try ModelEvidenceFixture()
        let report = try fixture.registerReport(
            kind: .runtime,
            status: .passed,
            metadata: [
                "model_id": "other/model; osaurus/alias-target",
                "tps": "12.5",
            ]
        )
        let service = ModelLibraryEvidenceService()

        let snapshot = service.snapshot(
            for: ModelLibraryEvidenceQuery(
                modelID: "osaurus/canonical-target",
                aliases: ["osaurus/alias-target"]
            ),
            reports: [report]
        )

        #expect(snapshot.status == .supported)
        #expect(snapshot.reports.map(\.status) == [.supported])
        #expect(snapshot.tokenRates.map(\.tokensPerSecond) == [12.5])
    }

    @Test
    func metadataFlaggedGenerationProofCanSupportSnapshot() throws {
        let fixture = try ModelEvidenceFixture()
        let report = try fixture.registerReport(
            kind: .eval,
            status: .passed,
            metadata: [
                "model_id": "osaurus/metadata-generation",
                "evidence_role": "generation",
                "decode_tps": "31.25",
            ]
        )
        let service = ModelLibraryEvidenceService()

        let snapshot = service.snapshot(
            for: ModelLibraryEvidenceQuery(modelID: "osaurus/metadata-generation"),
            reports: [report]
        )

        #expect(snapshot.status == .supported)
        #expect(snapshot.reports.map(\.isGenerationProof) == [true])
        #expect(snapshot.reports.map(\.status) == [.supported])
        #expect(snapshot.tokenRates.map(\.metadataKey) == ["decode_tps"])
        #expect(snapshot.tokenRates.map(\.tokensPerSecond) == [31.25])
    }

    @Test
    func tokenRateKeyAliasesAvoidHTTPSSuffixFalsePositive() throws {
        let fixture = try ModelEvidenceFixture()
        let report = try fixture.registerReport(
            kind: .runtime,
            status: .passed,
            metadata: [
                "model_id": "osaurus/token-rate-aliases",
                "request_https": "44.0",
                "completion_tps": "18.5",
                "tokens_per_sec": "19.5",
            ]
        )
        let service = ModelLibraryEvidenceService()

        let snapshot = service.snapshot(
            for: ModelLibraryEvidenceQuery(modelID: "osaurus/token-rate-aliases"),
            reports: [report]
        )

        #expect(snapshot.status == .supported)
        #expect(snapshot.tokenRates.map(\.metadataKey) == ["tokens_per_sec", "completion_tps"])
        #expect(snapshot.tokenRates.map(\.tokensPerSecond) == [19.5, 18.5])
    }

    @Test
    func looseTPSSuffixDoesNotPromoteGenerationProof() throws {
        let fixture = try ModelEvidenceFixture()
        let report = try fixture.registerReport(
            kind: .liveProof,
            status: .passed,
            metadata: [
                "model_id": "osaurus/https-row",
                "request_https": "44.0",
            ]
        )
        let service = ModelLibraryEvidenceService()

        let snapshot = service.snapshot(
            for: ModelLibraryEvidenceQuery(modelID: "osaurus/https-row"),
            reports: [report]
        )

        #expect(snapshot.status == .partial)
        #expect(snapshot.reports.map(\.status) == [.partial])
        #expect(snapshot.tokenRates.isEmpty)
        #expect(snapshot.warnings.contains { $0.contains("missing token/s") })
    }

    @Test
    func artifactErrorsAreUnsupportedNotSuccessful() throws {
        let fixture = try ModelEvidenceFixture()
        let report = fixture.registerErrorReport(
            kind: .benchmark,
            status: .passed,
            metadata: [
                "model_id": "osaurus/error-artifact",
                "tokens_per_second": "18.0",
            ]
        )
        let service = ModelLibraryEvidenceService()

        let snapshot = service.snapshot(
            for: ModelLibraryEvidenceQuery(modelID: "osaurus/error-artifact"),
            reports: [report]
        )

        #expect(snapshot.status == .unsupported)
        #expect(snapshot.reports.map(\.artifactAvailability) == [.error])
        #expect(snapshot.reports.map(\.reportStatus) == [.error])
        #expect(snapshot.reports.map(\.status) == [.unsupported])
        #expect(snapshot.blockers.contains { $0.contains("Evidence report") })
    }

    @Test
    func statusTaxonomyUsesUnsupportedPartialSupportedUnprovenOrder() {
        #expect(ModelLibraryEvidenceStatus.aggregate([.supported, .partial]) == .partial)
        #expect(ModelLibraryEvidenceStatus.aggregate([.supported, .unsupported]) == .unsupported)
        #expect(ModelLibraryEvidenceStatus.aggregate([.unproven]) == .unproven)
        #expect(ModelLibraryEvidenceStatus.aggregate([]) == .unproven)
        #expect(ModelLibraryImportState.incomplete.evidenceStatus == .unsupported)
        #expect(ModelLibraryCacheState.notObserved.evidenceStatus == .unproven)
        #expect(ModelLibraryCacheState.coldStored.evidenceStatus == .partial)
    }
}

private struct ModelEvidenceFixture {
    let root: URL
    let registry: EvidenceReportRegistryService
    private let currentDate: Date

    init() throws {
        currentDate = Date(timeIntervalSince1970: 1_750_000_000)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let date = currentDate
        registry = EvidenceReportRegistryService(now: { date })
    }

    func registerReport(
        kind: EvidenceReportKind,
        status: EvidenceReportStatus,
        metadata: [String: String],
        artifactName: String = UUID().uuidString
    ) throws -> EvidenceReportSummary {
        let artifact = try writeArtifact(named: "\(artifactName).json")
        return registry.register(
            EvidenceReportDescriptor(
                kind: kind,
                source: "model-evidence-tests",
                artifactURL: artifact,
                status: status,
                counts: EvidenceReportCounts(total: 1, passed: status == .passed ? 1 : 0),
                completedAt: currentDate,
                metadata: metadata
            )
        )
    }

    func registerMissingReport(
        kind: EvidenceReportKind,
        status: EvidenceReportStatus,
        metadata: [String: String]
    ) -> EvidenceReportSummary {
        registry.register(
            EvidenceReportDescriptor(
                kind: kind,
                source: "model-evidence-tests",
                artifactURL: root.appendingPathComponent("missing-\(UUID().uuidString).json"),
                status: status,
                counts: EvidenceReportCounts(total: 1, passed: status == .passed ? 1 : 0),
                completedAt: currentDate,
                metadata: metadata
            )
        )
    }

    func registerErrorReport(
        kind: EvidenceReportKind,
        status: EvidenceReportStatus,
        metadata: [String: String]
    ) -> EvidenceReportSummary {
        registry.register(
            EvidenceReportDescriptor(
                kind: kind,
                source: "model-evidence-tests",
                artifactURL: root.appendingPathComponent("error-\(UUID().uuidString).json"),
                status: status,
                counts: EvidenceReportCounts(total: 1, passed: status == .passed ? 1 : 0),
                completedAt: currentDate,
                metadata: metadata,
                artifactError: "Artifact descriptor failed to load."
            )
        )
    }

    private func writeArtifact(named relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{\"ok\":true}".utf8).write(to: url)
        return url
    }
}
