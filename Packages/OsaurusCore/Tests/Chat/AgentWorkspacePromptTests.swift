//
//  AgentWorkspacePromptTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct AgentWorkspacePromptTests {

    @Test func workspaceSummaryAppearsAsDynamicPromptSection() async throws {
        try await SandboxTestLock.runWithStoragePaths {
            let root = try makeTempDirectory()
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            let agent = Agent(
                name: "WorkspacePrompt-\(UUID().uuidString.prefix(6))",
                systemPrompt: "Use project context when it is available.",
                agentAddress: "workspace-prompt-\(UUID().uuidString)",
                toolsEnabled: false
            )

            do {
                AgentManager.shared.add(agent)
                let notes = root.appendingPathComponent("project-notes.md")
                try "Roadmap item: add durable agent workspaces.".write(
                    to: notes,
                    atomically: true,
                    encoding: .utf8
                )
                _ = try AgentWorkspaceStore.create(
                    agentId: agent.id,
                    name: "Project Notes",
                    description: "Planning notes for the agent.",
                    paths: [notes.path],
                    sourceAuthorization: .trustedLocal
                )

                let context = await SystemPromptComposer.composeChatContext(
                    agentId: agent.id,
                    executionMode: .none,
                    model: "unit-test-model",
                    toolsDisabled: true
                )

                let section = try #require(context.manifest.section("agentWorkspaces"))
                #expect(section.cacheability == .dynamic)
                #expect(context.prompt.contains("## Agent workspaces"))
                #expect(context.prompt.contains("Project Notes"))
                #expect(context.prompt.contains("Source summaries and full paths are hidden"))
                #expect(context.prompt.contains("Roadmap item") == false)
                #expect(context.prompt.contains(notes.path) == false)

                _ = await AgentManager.shared.delete(id: agent.id)
                OsaurusPaths.overrideRoot = previousRoot
                try? FileManager.default.removeItem(at: root)
            } catch {
                _ = await AgentManager.shared.delete(id: agent.id)
                OsaurusPaths.overrideRoot = previousRoot
                try? FileManager.default.removeItem(at: root)
                throw error
            }
        }
    }

    private func makeTempDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-agent-workspace-prompt-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
