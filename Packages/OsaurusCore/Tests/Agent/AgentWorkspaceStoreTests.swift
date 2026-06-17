//
//  AgentWorkspaceStoreTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct AgentWorkspaceStoreTests {

    @Test func createPersistsSummarizesAndDeletesWorkspace() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try makeTempDirectory()
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                try? FileManager.default.removeItem(at: root)
            }

            let fixtures = root.appendingPathComponent("fixtures", isDirectory: true)
            try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
            let notes = fixtures.appendingPathComponent("notes.md")
            try """
            # Release Notes

            The workspace should summarize UTF-8 text without reading the whole file.
            """.write(to: notes, atomically: true, encoding: .utf8)
            try "alpha,beta,gamma\n".write(
                to: fixtures.appendingPathComponent("data.csv"),
                atomically: true,
                encoding: .utf8
            )

            let agentId = UUID()
            let missing = fixtures.appendingPathComponent("missing.txt")
            let workspace = try AgentWorkspaceStore.create(
                agentId: agentId,
                name: "  Knowledge Base  ",
                description: "  Project notes  ",
                paths: [notes.path, fixtures.path, missing.path]
            )

            #expect(workspace.name == "Knowledge Base")
            #expect(workspace.description == "Project notes")
            #expect(workspace.sources.count == 3)
            #expect(workspace.sources.contains { $0.kind == .file && $0.status == .indexed })
            #expect(workspace.sources.contains { $0.kind == .folder && $0.status == .indexed })
            #expect(workspace.sources.contains { $0.kind == .missing && $0.status == .error })

            let reloaded = try #require(AgentWorkspaceStore.load(agentId: agentId, workspaceId: workspace.id))
            #expect(reloaded.sources.count == 3)

            let summary = try #require(
                AgentWorkspaceStore.promptSummary(
                    agentId: agentId,
                    canReadSources: true,
                    maxSourceSummaryCharacters: 48
                )
            )
            #expect(summary.workspaces.count == 1)
            #expect(summary.workspaces[0].sources.contains { $0.summary?.contains("Release Notes") == true })

            try AgentWorkspaceStore.deleteAll(for: agentId)
            #expect(AgentWorkspaceStore.loadAll(agentId: agentId).isEmpty)
        }
    }

    private func makeTempDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-agent-workspace-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
