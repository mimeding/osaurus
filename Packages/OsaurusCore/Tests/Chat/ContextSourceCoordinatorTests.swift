//
//  ContextSourceCoordinatorTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct ContextSourceCoordinatorTests {
    @Test func dynamicPromptSectionsAreDedupedAndOrderedByPrecedence() {
        let agentId = UUID()
        let workspace = ContextSourceCoordinator.agentWorkspace(agentId: agentId)
        let duplicateWorkspace = ContextSourcePromptSection(
            id: "agentWorkspacesDuplicate",
            label: "Duplicate",
            descriptor: workspace,
            content: "duplicate"
        )
        let sections = [
            ContextSourcePromptSection(
                id: "sandboxState",
                label: "Sandbox State",
                descriptor: ContextSourceCoordinator.sandboxLocal(agentId: agentId),
                content: "sandbox"
            ),
            ContextSourcePromptSection(
                id: "agentDBSchema",
                label: "Agent DB Schema",
                descriptor: ContextSourceCoordinator.agentDatabase(agentId: agentId),
                content: "db"
            ),
            ContextSourcePromptSection(
                id: "agentWorkspaces",
                label: "Agent Workspaces",
                descriptor: workspace,
                content: "workspace"
            ),
            duplicateWorkspace,
        ]

        let coordinated = ContextSourceCoordinator.coordinatedPromptSections(
            sections,
            slot: .systemPromptDynamic
        )

        #expect(coordinated.map(\.id) == ["agentWorkspaces", "agentDBSchema", "sandboxState"])
        #expect(coordinated.map(\.content) == ["workspace", "db", "sandbox"])
    }

    @Test func boundaryLedgerKeepsWorkspaceDistinctFromMemorySandboxAndScreen() {
        let agentId = UUID()
        let ledger = ContextSourceCoordinator.boundaryLedger(agentId: agentId)

        let byKind = Dictionary(uniqueKeysWithValues: ledger.map { ($0.kind, $0) })
        #expect(byKind[.agentWorkspace]?.injectionSlot == .systemPromptDynamic)
        #expect(byKind[.memory]?.injectionSlot == .latestUserMessagePrefix)
        #expect(byKind[.screen]?.privacyPath == .privacyFilteredUserMessage)
        #expect(byKind[.sandboxLocal]?.owner == .runtime)
        #expect(byKind[.hostWorkspace]?.owner == .user)

        let dedupeKeys = Set(ledger.map(\.dedupeKey))
        #expect(dedupeKeys.count == ledger.count)
        #expect(byKind[.agentWorkspace]?.dedupeKey != byKind[.memory]?.dedupeKey)
        #expect(byKind[.agentWorkspace]?.dedupeKey != byKind[.sandboxLocal]?.dedupeKey)
    }
}
