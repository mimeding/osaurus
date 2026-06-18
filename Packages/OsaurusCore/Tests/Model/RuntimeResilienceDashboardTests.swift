// Copyright 2026 Osaurus AI. All rights reserved.

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Runtime resilience dashboard")
struct RuntimeResilienceDashboardTests {
    @Test("dashboard surface preserves per-signal evidence without promoting schema rows")
    func dashboardSurfacePreservesSignalEvidence() throws {
        let report = try RuntimeProofMatrixReporter.decodeClassification(data: Self.fixtureData)

        let surface = RuntimeProofMatrixReporter.dashboardSurface(
            from: report,
            sourceClassificationPath: "/tmp/runtime/PROOF_CLASSIFICATION.json",
            generatedAt: "2026-06-18T00:00:00Z"
        )

        #expect(surface.generatedAt == "2026-06-18T00:00:00Z")
        #expect(surface.verdictCounts["proven"] == 1)
        #expect(surface.verdictCounts["unproven"] == 2)
        #expect(surface.signalCounts["tokens_per_second"]?["proven"] == 1)
        #expect(surface.signalCounts["cancellation"]?["proven"] == 1)
        #expect(surface.signalCounts["cancellation"]?["unproven"] == 2)

        let liveRow = try #require(surface.rows.first { $0.id == "gemma4-text-required" })
        #expect(liveRow.signalEvidence["tokens_per_second"]?.summary.contains("18.40 token/s") == true)
        #expect(liveRow.signalEvidence["cache"]?.evidencePaths.contains("/tmp/runtime/gemma/cache-after.json") == true)
        #expect(liveRow.signalEvidence["marker_leak"]?.verdict == .proven)
        #expect(liveRow.signalEvidence["crash_proof"]?.verdict == .proven)

        let promptInjection = try #require(
            surface.rows.first { $0.id == "issue-903-system-prompt-injection-schema" }
        )
        #expect(promptInjection.isSchemaOnly)
        #expect(promptInjection.verdict == .unproven)
        #expect(promptInjection.signalEvidence["tokens_per_second"]?.verdict == .unproven)
    }

    @Test("dashboard markdown renders links and issue coverage")
    func dashboardMarkdownRendersLinksAndCoverage() throws {
        let report = try RuntimeProofMatrixReporter.decodeClassification(data: Self.fixtureData)

        let markdown = RuntimeProofMatrixReporter.dashboardMarkdown(
            from: report,
            sourceClassificationPath: "/tmp/runtime/PROOF_CLASSIFICATION.json",
            generatedAt: "2026-06-18T00:00:00Z"
        )

        #expect(markdown.contains(RuntimeProofMatrixReporter.dashboardMarkdownBeginMarker))
        #expect(markdown.contains("| Row | Model | Verdict | Token/s | Cache | Marker leak | Cancellation | Crash proof |"))
        #expect(markdown.contains("Crash/cancellation issue coverage: partial"))
        #expect(markdown.contains("[1](/tmp/runtime/gemma/SUMMARY.json)"))
        #expect(markdown.contains("issue-1163-hy3-harmony-retro-validation-schema"))
    }

    private static let fixtureData = Data(
        """
        {
          "generated_at": "2026-06-18T00:00:00Z",
          "summary_path": "/tmp/runtime/SUMMARY.json",
          "manifest_path": "scripts/live-proof/family-runtime-chat-matrix.json",
          "artifact_root": "/tmp/runtime",
          "verdict_counts": {
            "proven": 1,
            "partial": 0,
            "failed": 0,
            "unproven": 0
          },
          "required_rows_not_proven": [],
          "passed": true,
          "rows": [
            {
              "id": "gemma4-text-required",
              "model": "Gemma4 text",
              "family": "gemma4",
              "priority": "required",
              "requirements": [
                "visible_output",
                "tokens_per_second",
                "no_parser_marker_leak",
                "multi_turn_coherency",
                "cache_hit",
                "cancellation"
              ],
              "artifact_paths": [
                "/tmp/runtime/gemma/SUMMARY.json"
              ],
              "summary_path": "/tmp/runtime/gemma/SUMMARY.json",
              "verdict": "proven",
              "acceptable_for_proven_claim": true,
              "blockers": [],
              "warnings": [],
              "failed_checks": [],
              "cache_delta": {
                "block_disk_hits": 2
              },
              "token_rates": {
                "turn2": {
                  "completion_tokens": 42,
                  "elapsed_seconds": 2.28,
                  "tokens_per_second": 18.4
                }
              },
              "resilience_evidence": {
                "tokens_per_second": {
                  "verdict": "proven",
                  "summary": "turn2: 18.40 token/s over 42 completion tokens",
                  "evidence_paths": ["/tmp/runtime/gemma/SUMMARY.json"],
                  "metrics": {"token_rates_turn2_tokens_per_second": 18.4}
                },
                "cache": {
                  "verdict": "proven",
                  "summary": "topology-specific cache evidence passed",
                  "evidence_paths": ["/tmp/runtime/gemma/SUMMARY.json", "/tmp/runtime/gemma/cache-after.json"],
                  "metrics": {"cache_delta_block_disk_hits": 2}
                },
                "marker_leak": {
                  "verdict": "proven",
                  "summary": "no parser/runtime marker leak detected in recorded output",
                  "evidence_paths": ["/tmp/runtime/gemma/SUMMARY.json", "/tmp/runtime/gemma/response.json"],
                  "metrics": {}
                },
                "cancellation": {
                  "verdict": "proven",
                  "summary": "cancellation cleanup checks passed: cancellation_cleaned_up",
                  "evidence_paths": ["/tmp/runtime/gemma/SUMMARY.json", "/tmp/runtime/gemma/health-after.json"],
                  "metrics": {}
                },
                "crash_proof": {
                  "verdict": "proven",
                  "summary": "server stayed healthy with no in-flight work after the row",
                  "evidence_paths": ["/tmp/runtime/gemma/SUMMARY.json", "/tmp/runtime/gemma/health-after.json"],
                  "metrics": {}
                }
              }
            }
          ],
          "issue_coverage": {
            "#1228": {
              "verdict": "partial",
              "note": "crash closure needs reporter-aligned crash and cancellation artifacts; dashboard rows only surface existing evidence",
              "rows": ["gemma4-text-required"]
            }
          }
        }
        """.utf8
    )
}
