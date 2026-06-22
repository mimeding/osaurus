//
//  WorkspaceContextSourceWorkbenchTests.swift
//  osaurusTests
//
//  Locks the model boundary between memory, agent DB, sandbox context,
//  uploaded files, workspace knowledge, and citations. The workbench should
//  inventory provenance and freshness without reading or duplicating the
//  underlying source payloads.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct WorkspaceContextSourceWorkbenchTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    @Test
    func deduplicatesWithinKindButKeepsBoundaryKindsSeparate() {
        let oldKnowledge = source(
            id: "kb-old",
            kind: .workspaceKnowledge,
            stableId: "file:/repo/README.md",
            version: "v1",
            observedAt: now.addingTimeInterval(-60)
        )
        let newKnowledge = source(
            id: "kb-new",
            kind: .workspaceKnowledge,
            stableId: "file:/repo/README.md",
            version: "v1",
            observedAt: now
        )
        let memory = source(
            id: "memory-readme",
            kind: .memory,
            stableId: "file:/repo/README.md",
            version: "v1",
            observedAt: now
        )

        let inventory = WorkspaceContextSourceWorkbench.buildInventory(
            sources: [oldKnowledge, newKnowledge, memory],
            now: now
        )

        #expect(inventory.duplicateGroups.count == 1)
        #expect(inventory.duplicateGroups.first?.canonicalSourceId == "kb-new")
        #expect(inventory.duplicateGroups.first?.duplicateSourceIds == ["kb-old"])
        #expect(inventory.record(id: "kb-old")?.duplicateOf == "kb-new")
        #expect(inventory.record(id: "memory-readme")?.duplicateOf == nil)

        let effectiveIds = Set(inventory.effectiveSources.map(\.id))
        #expect(effectiveIds == ["kb-new", "memory-readme"])
        #expect(inventory.record(id: "memory-readme")?.boundaryContract.payloadPolicy == .metadataOnly)
        #expect(inventory.record(id: "kb-new")?.boundaryContract.payloadPolicy == .metadataAndAnchorsOnly)
    }

    @Test
    func staleIndexCitationAndProvenanceWarningsAreRecorded() {
        let uploaded = source(
            id: "upload-1",
            kind: .uploadedFile,
            stableId: "attachment:upload-1",
            version: "upload-v2",
            observedAt: now,
            index: .indexed(version: "upload-v2", at: now)
        )
        let knowledge = source(
            id: "kb-1",
            kind: .workspaceKnowledge,
            stableId: "file:/repo/Guide.md",
            version: "guide-v2",
            observedAt: now.addingTimeInterval(-600),
            index: .indexed(version: "guide-v1", at: now.addingTimeInterval(-590)),
            citations: [
                WorkspaceContextCitation(
                    id: "cite-upload",
                    sourceId: "upload-1",
                    label: "Upload citation",
                    sourceVersion: "upload-v1",
                    anchor: WorkspaceContextCitationAnchor(
                        kind: .fileRange,
                        locator: "Upload.txt:1-2",
                        startLine: 1,
                        endLine: 2
                    )
                )
            ]
        )
        let policy = WorkspaceContextSourceWorkbenchPolicy(provenanceMaxAge: 120)

        let inventory = WorkspaceContextSourceWorkbench.buildInventory(
            sources: [uploaded, knowledge],
            policy: policy,
            now: now
        )

        let record = inventory.record(id: "kb-1")
        #expect(record?.state == .stale)
        #expect(
            record?.staleness.reasons.isSuperset(
                of: Set([
                    .indexVersionMismatch,
                    .citationVersionMismatch,
                    .provenanceExpired,
                ])
            ) == true
        )

        let warningKinds = Set(record?.warnings.map(\.kind) ?? [])
        #expect(warningKinds.contains(.indexStale))
        #expect(warningKinds.contains(.citationStale))
        #expect(warningKinds.contains(.staleProvenance))
        #expect(inventory.record(id: "upload-1")?.state == .active)
    }

    @Test
    func malformedMissingAndMissingCitationSourcesAreHandled() {
        let blankId = source(
            id: "  ",
            kind: .uploadedFile,
            stableId: "attachment:bad",
            version: "v1",
            observedAt: now
        )
        let missingProvenance = WorkspaceContextSourceInput(
            id: "no-provenance",
            kind: .workspaceKnowledge,
            displayName: "No Provenance"
        )
        let missingSource = source(
            id: "missing-file",
            kind: .workspaceKnowledge,
            stableId: "file:/repo/Missing.md",
            version: "missing-v1",
            sourceExists: false,
            observedAt: now,
            index: .indexed(version: "missing-v1", at: now)
        )
        let citationCarrier = source(
            id: "citation-carrier",
            kind: .citation,
            stableId: "citation-set:1",
            version: "citations-v1",
            observedAt: now,
            citations: [
                WorkspaceContextCitation(
                    id: "",
                    sourceId: "missing-file",
                    label: "Malformed citation"
                ),
                WorkspaceContextCitation(
                    id: "cite-absent",
                    sourceId: "absent-source",
                    label: "Missing source",
                    anchor: WorkspaceContextCitationAnchor(
                        kind: .externalReference,
                        locator: "absent-source"
                    )
                ),
                WorkspaceContextCitation(
                    id: "cite-no-anchor",
                    sourceId: "missing-file",
                    label: "No anchor"
                ),
            ]
        )

        let inventory = WorkspaceContextSourceWorkbench.buildInventory(
            sources: [blankId, missingProvenance, missingSource, citationCarrier],
            now: now
        )

        #expect(inventory.rejectedSources.count == 2)
        #expect(inventory.record(id: "missing-file")?.state == .missing)
        #expect(inventory.record(id: "missing-file")?.isEffective == false)
        #expect(inventory.record(id: "citation-carrier")?.state == .malformed)

        let warningKinds = Set(inventory.warnings.map(\.kind))
        #expect(warningKinds.contains(.malformedSource))
        #expect(warningKinds.contains(.sourceMissing))
        #expect(warningKinds.contains(.malformedCitation))
        #expect(warningKinds.contains(.citationSourceMissing))
        #expect(warningKinds.contains(.citationAnchorMissing))
    }

    @Test
    func duplicateCitationWarningsReceiveStableUniqueIds() {
        let carrier = source(
            id: "citation-carrier",
            kind: .citation,
            stableId: "citation-set:dupes",
            version: "citations-v1",
            observedAt: now,
            citations: [
                WorkspaceContextCitation(id: "", sourceId: "missing-file", label: "Malformed A"),
                WorkspaceContextCitation(id: "", sourceId: "missing-file", label: "Malformed B"),
                WorkspaceContextCitation(
                    id: "missing-a",
                    sourceId: "same-missing-source",
                    label: "Missing A",
                    anchor: WorkspaceContextCitationAnchor(kind: .externalReference, locator: "missing")
                ),
                WorkspaceContextCitation(
                    id: "missing-b",
                    sourceId: "same-missing-source",
                    label: "Missing B",
                    anchor: WorkspaceContextCitationAnchor(kind: .externalReference, locator: "missing")
                ),
            ]
        )

        let inventory = WorkspaceContextSourceWorkbench.buildInventory(
            sources: [carrier],
            now: now
        )

        let citationWarnings = inventory.record(id: "citation-carrier")?.warnings.filter {
            $0.kind == .malformedCitation || $0.kind == .citationSourceMissing
        } ?? []
        #expect(citationWarnings.count == 4)
        #expect(Set(citationWarnings.map(\.id)).count == citationWarnings.count)
        #expect(inventory.record(id: "citation-carrier")?.state == .malformed)
    }

    @Test
    func perAgentEnablementControlsEffectiveSources() {
        let agentA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
        let agentB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
        let memoryA = source(
            id: "memory-a",
            kind: .memory,
            stableId: "memory:agent-a",
            version: "m1",
            agentId: agentA,
            observedAt: now
        )
        let dbA = source(
            id: "db-a",
            kind: .agentDatabase,
            stableId: "db:agent-a",
            version: "db1",
            agentId: agentA,
            observedAt: now
        )
        let sandboxA = source(
            id: "sandbox-a",
            kind: .sandboxContext,
            stableId: "sandbox:agent-a",
            version: "s1",
            agentId: agentA,
            observedAt: now
        )
        let memoryB = source(
            id: "memory-b",
            kind: .memory,
            stableId: "memory:agent-b",
            version: "m1",
            agentId: agentB,
            observedAt: now
        )
        let policy = WorkspaceContextSourceWorkbenchPolicy(
            enabledKindsByAgent: [agentA: [.memory, .sandboxContext]],
            disabledSourceIdsByAgent: [agentA: ["sandbox-a"]]
        )

        let inventory = WorkspaceContextSourceWorkbench.buildInventory(
            sources: [memoryA, dbA, sandboxA, memoryB],
            activeAgentId: agentA,
            policy: policy,
            now: now
        )

        #expect(inventory.effectiveSources.map(\.id) == ["memory-a"])
        #expect(inventory.record(id: "db-a")?.state == .disabled)
        #expect(inventory.record(id: "sandbox-a")?.state == .disabled)
        #expect(inventory.record(id: "memory-b")?.state == .disabled)

        let warningKinds = Set(inventory.warnings.map(\.kind))
        #expect(warningKinds.contains(.disabledForAgent))
        #expect(warningKinds.contains(.agentScopeMismatch))
    }

    @Test
    func canonicalDedupePrefersEnabledSourceForActiveAgent() {
        let agentA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
        let disabledNewer = source(
            id: "kb-disabled-newer",
            kind: .workspaceKnowledge,
            stableId: "file:/repo/Shared.md",
            version: "v2",
            agentId: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!,
            observedAt: now.addingTimeInterval(60)
        )
        let enabledOlder = source(
            id: "kb-enabled-older",
            kind: .workspaceKnowledge,
            stableId: "file:/repo/Shared.md",
            version: "v1",
            agentId: agentA,
            observedAt: now
        )

        let inventory = WorkspaceContextSourceWorkbench.buildInventory(
            sources: [disabledNewer, enabledOlder],
            activeAgentId: agentA,
            now: now
        )

        #expect(inventory.duplicateGroups.first?.canonicalSourceId == "kb-enabled-older")
        #expect(inventory.record(id: "kb-disabled-newer")?.duplicateOf == "kb-enabled-older")
        #expect(inventory.record(id: "kb-enabled-older")?.duplicateOf == nil)
        #expect(inventory.effectiveSources.map(\.id) == ["kb-enabled-older"])
    }

    @Test
    func presenterSummarizesInventoryWithoutRecomputingBoundaries() {
        let current = source(
            id: "memory-a",
            kind: .memory,
            stableId: "memory:agent-a",
            version: "m1",
            observedAt: now
        )
        let stale = source(
            id: "kb-a",
            kind: .workspaceKnowledge,
            stableId: "file:/repo/A.md",
            version: "v2",
            observedAt: now,
            index: .indexed(version: "v1", at: now)
        )
        let inventory = WorkspaceContextSourceWorkbench.buildInventory(
            sources: [current, stale],
            now: now
        )

        let rows = WorkspaceContextSourceWorkbenchPresenter.rows(for: inventory)
        let summary = WorkspaceContextSourceWorkbenchPresenter.summary(for: inventory)

        #expect(rows.map(\.statusLabel) == ["Current", "Stale"])
        #expect(rows.first?.badges.contains(WorkspaceContextSourceAuthority.memoryService.rawValue) == true)
        #expect(summary.totalSources == 2)
        #expect(summary.effectiveSources == 2)
        #expect(summary.staleSources == 1)
    }

    private func source(
        id: String,
        kind: WorkspaceContextSourceKind,
        stableId: String,
        version: String,
        sourceExists: Bool = true,
        agentId: UUID? = nil,
        observedAt: Date,
        index: WorkspaceContextIndexState? = nil,
        citations: [WorkspaceContextCitation] = []
    ) -> WorkspaceContextSourceInput {
        WorkspaceContextSourceInput(
            id: id,
            kind: kind,
            displayName: "\(kind.displayName) \(id.trimmingCharacters(in: .whitespacesAndNewlines))",
            agentId: agentId,
            provenance: WorkspaceContextSourceProvenance(
                stableId: stableId,
                origin: kind.expectedOrigin,
                displayPath: stableId,
                sourceVersion: version,
                observedAt: observedAt,
                modifiedAt: observedAt,
                sourceExists: sourceExists
            ),
            index: index ?? defaultIndex(for: kind, version: version, at: observedAt),
            citations: citations
        )
    }

    private func defaultIndex(
        for kind: WorkspaceContextSourceKind,
        version: String,
        at date: Date
    ) -> WorkspaceContextIndexState? {
        guard kind.requiresIndexFreshness else { return nil }
        return .indexed(version: version, at: date)
    }
}

private extension WorkspaceContextIndexState {
    static func indexed(version: String, at date: Date) -> WorkspaceContextIndexState {
        WorkspaceContextIndexState(
            status: .indexed,
            indexedAt: date,
            indexedSourceVersion: version,
            citationCount: 0
        )
    }
}
