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
                paths: [notes.path, fixtures.path, missing.path],
                sourceAuthorization: .trustedLocal
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

    @Test func sourceInspectionRequiresAuthorization() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }

            let notes = root.appendingPathComponent("notes.md")
            try "Local-only workspace facts.".write(to: notes, atomically: true, encoding: .utf8)

            let source = AgentWorkspaceStore.inspectSource(path: notes.path)

            #expect(source.status == .skipped)
            #expect(source.summary == nil)
            #expect(source.error?.contains("trusted local caller") == true)
        }
    }

    @Test func sourceInspectionHonorsScopedRootsAndSymlinkContainment() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let outside = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: outside) }

            let inside = root.appendingPathComponent("inside.md")
            try "Allowed workspace facts.".write(to: inside, atomically: true, encoding: .utf8)
            let secret = outside.appendingPathComponent("outside.md")
            try "Out-of-scope facts.".write(to: secret, atomically: true, encoding: .utf8)
            let link = root.appendingPathComponent("linked.md")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)

            let authorization = AgentWorkspaceSourceAuthorization.scopedRoots([root])
            let allowed = AgentWorkspaceStore.inspectSource(path: inside.path, authorization: authorization)
            let escaped = AgentWorkspaceStore.inspectSource(path: link.path, authorization: authorization)

            #expect(allowed.status == .indexed)
            #expect(allowed.summary?.contains("Allowed workspace facts") == true)
            #expect(escaped.status == .skipped)
            #expect(escaped.summary == nil)
            #expect(escaped.error?.contains("outside the authorized workspace roots") == true)
        }
    }

    @Test func sourceInspectionRefusesSecretFilesAndOmitsSecretFolderEntries() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }

            let env = root.appendingPathComponent(".env")
            try "TOKEN=should-not-leak".write(to: env, atomically: true, encoding: .utf8)
            let publicNotes = root.appendingPathComponent("README.md")
            try "Safe notes.".write(to: publicNotes, atomically: true, encoding: .utf8)
            let key = root.appendingPathComponent("server.pem")
            try "PRIVATE KEY should-not-list".write(to: key, atomically: true, encoding: .utf8)

            let secret = AgentWorkspaceStore.inspectSource(path: env.path, authorization: .trustedLocal)
            let folder = AgentWorkspaceStore.inspectSource(path: root.path, authorization: .trustedLocal)

            #expect(secret.status == .skipped)
            #expect(secret.summary == nil)
            #expect(secret.error?.contains("Sensitive source paths") == true)
            #expect(folder.status == .indexed)
            #expect(folder.summary?.contains("README.md") == true)
            #expect(folder.summary?.contains(".env") == false)
            #expect(folder.summary?.contains("server.pem") == false)
        }
    }

    @Test func promptSummaryRedactsSourcesWithoutFileReadCapability() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try makeTempDirectory()
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                try? FileManager.default.removeItem(at: root)
            }

            let notes = root.appendingPathComponent("project-notes.md")
            try "Roadmap item: private workspace detail.".write(
                to: notes,
                atomically: true,
                encoding: .utf8
            )

            let agentId = UUID()
            _ = try AgentWorkspaceStore.create(
                agentId: agentId,
                name: "Project Notes",
                paths: [notes.path],
                sourceAuthorization: .trustedLocal
            )

            let redacted = try #require(
                AgentWorkspaceStore.promptSummary(agentId: agentId, canReadSources: false)
            )
            #expect(redacted.workspaces[0].sources[0].summary == nil)
            #expect(redacted.workspaces[0].sources[0].path == "project-notes.md")

            let readable = try #require(
                AgentWorkspaceStore.promptSummary(agentId: agentId, canReadSources: true)
            )
            #expect(readable.workspaces[0].sources[0].summary?.contains("Roadmap item") == true)
            #expect(readable.workspaces[0].sources[0].path == notes.path)
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
