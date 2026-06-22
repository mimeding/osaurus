//
//  ProviderRuntimeEvidenceDescriptorProducerTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Provider/runtime evidence descriptor producer")
struct ProviderRuntimeEvidenceDescriptorProducerTests {
    @Test
    func providerDiagnosticsRegisterThroughUnifiedRegistryWithRedactedMetadata() throws {
        let fixture = try EvidenceProducerFixture()
        let artifact = try fixture.writeArtifact(named: "provider/diagnostics.json")
        let report = ProviderDiagnosticReport(
            title: "Remote provider diagnostics",
            subtitle: "Acme | https://api.example.test/v1",
            rows: [
                ProviderDiagnosticRow(
                    id: "connection",
                    title: "Connection",
                    value: "Connected",
                    severity: .ok
                ),
                ProviderDiagnosticRow(
                    id: "proxy",
                    title: "Global proxy",
                    value: "Ignored",
                    severity: .warning
                ),
                ProviderDiagnosticRow(
                    id: "auth",
                    title: "Authentication",
                    value: "API key in Keychain",
                    severity: .ok
                ),
            ]
        )

        let descriptor = ProviderRuntimeEvidenceDescriptorProducer.providerDiagnosticsDescriptor(
            from: report,
            artifactURL: artifact,
            metadata: [
                "api_key": "sk-secret-value",
                "authorization": "Bearer secret-token",
                "provider": "acme",
            ]
        )
        let registry = EvidenceReportRegistryService(now: fixture.clock)

        registry.register(descriptor)

        let summary = try #require(registry.list(EvidenceReportFilter(kinds: [.provider])).first)
        #expect(summary.kind == .provider)
        #expect(summary.source == "provider-connectivity")
        #expect(summary.status == .partial)
        #expect(summary.counts.total == 3)
        #expect(summary.counts.passed == 2)
        #expect(summary.counts.warnings == 1)
        #expect(summary.metadata["api_key"] == "<redacted>")
        #expect(summary.metadata["authorization"] == "<redacted>")
        #expect(summary.metadata["provider"] == "acme")
        #expect(summary.metadata["row_ids"] == "connection,proxy,auth")
    }

    @Test
    func runtimeProofClassificationRegistersRowsAndSchemaGapsThroughUnifiedRegistry() throws {
        let fixture = try EvidenceProducerFixture()
        let artifact = try fixture.writeArtifact(named: "runtime/PROOF_CLASSIFICATION.json")
        let report = RuntimeProofClassificationReport(
            generatedAt: "2026-06-11T00:00:00Z",
            summaryPath: "/tmp/runtime/SUMMARY.json",
            manifestPath: "scripts/live-proof/family-runtime-chat-matrix.json",
            artifactRoot: "/tmp/runtime",
            requiredRowsNotProven: ["qwen-cache-partial"],
            passed: false,
            rows: [
                RuntimeProofClassificationRow(
                    id: "gemma4-text-required",
                    model: "Gemma4 text",
                    family: "gemma4",
                    priority: "required",
                    requirements: [
                        "visible_output",
                        "tokens_per_second",
                    ],
                    artifactPaths: ["/tmp/runtime/gemma4/SUMMARY.json"],
                    summaryPath: "/tmp/runtime/gemma4/SUMMARY.json",
                    verdict: .proven,
                    acceptableForProvenClaim: true
                ),
                RuntimeProofClassificationRow(
                    id: "qwen-cache-partial",
                    model: "Qwen cache",
                    family: "qwen",
                    priority: "required",
                    requirements: [
                        "tokens_per_second",
                        "cache_hit",
                    ],
                    artifactPaths: ["/tmp/runtime/qwen/SUMMARY.json"],
                    summaryPath: "/tmp/runtime/qwen/SUMMARY.json",
                    verdict: .partial,
                    blockers: [
                        RuntimeProofMatrixMessage(
                            requirement: "cache_hit",
                            message: "row lacks required cache evidence"
                        ),
                    ]
                ),
            ]
        )
        let registry = EvidenceReportRegistryService(now: fixture.clock)

        registry.register(
            ProviderRuntimeEvidenceDescriptorProducer.runtimeProofDescriptor(
                from: report,
                artifactURL: artifact
            )
        )

        let summary = try #require(registry.list(EvidenceReportFilter(kinds: [.runtime])).first)
        #expect(summary.source == "runtime-proof-classification")
        #expect(summary.status == .blocked)
        #expect(summary.artifact.availability == .available)
        #expect(summary.counts.total == 4)
        #expect(summary.counts.passed == 1)
        #expect(summary.counts.warnings == 1)
        #expect(summary.counts.blocked == 2)
        #expect(summary.completedAt == ISO8601DateFormatter().date(from: "2026-06-11T00:00:00Z"))
        #expect(summary.metadata["schema_only_rows"] == "2")
        #expect(summary.metadata["required_rows_not_proven"] == "qwen-cache-partial")
    }

    @Test
    func missingProviderAndRuntimeArtifactsRemainExplicitRegistryRows() throws {
        let fixture = try EvidenceProducerFixture()
        let providerPath = fixture.root
            .appendingPathComponent("missing/provider-diagnostics.json")
            .path
        let runtimePath = fixture.root
            .appendingPathComponent("missing/runtime-proof.json")
            .path
        let providerReport = ProviderDiagnosticReport(
            title: "Remote provider diagnostics",
            subtitle: "Missing | https://api.example.test/v1",
            rows: [
                ProviderDiagnosticRow(
                    id: "connection",
                    title: "Connection",
                    value: "Failed",
                    severity: .blocked
                ),
            ]
        )
        let runtimeReport = RuntimeProofClassificationReport(
            generatedAt: "2026-06-11T00:00:00Z",
            passed: true,
            rows: [
                RuntimeProofClassificationRow(
                    id: "gemma4-text-required",
                    verdict: .proven,
                    acceptableForProvenClaim: true
                ),
            ]
        )
        let registry = EvidenceReportRegistryService(now: fixture.clock)

        registry.register([
            ProviderRuntimeEvidenceDescriptorProducer.providerDiagnosticsDescriptor(
                from: providerReport,
                artifactPath: providerPath
            ),
            ProviderRuntimeEvidenceDescriptorProducer.runtimeProofDescriptor(
                from: runtimeReport,
                artifactPath: runtimePath
            ),
        ])

        let summaries = registry.list(EvidenceReportFilter(artifactAvailability: [.unavailable]))
        #expect(summaries.count == 2)
        #expect(Set(summaries.map(\.kind)) == [.provider, .runtime])
        #expect(summaries.allSatisfy { $0.status == .unavailable })
        #expect(summaries.allSatisfy { $0.artifact.message?.contains("not present") == true })
    }
}

private struct EvidenceProducerFixture {
    let root: URL
    let currentDate = Date(timeIntervalSince1970: 1_750_000_000)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    func clock() -> Date {
        currentDate
    }

    func writeArtifact(named relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{\"ok\":true}".utf8).write(to: url)
        return url
    }
}
