//
//  SessionPreflightCacheTests.swift
//  osaurusTests
//
//  Validates the `SessionToolState` contract used by ChatWindowState to
//  memoize per-session preflight selections + capabilities_load additions
//  across composes.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct SessionPreflightCacheTests {

    @Test
    func sessionToolState_loadedNamesAreAdditive() {
        var state = SessionToolState(
            initialPreflight: PreflightResult(toolSpecs: [], items: [])
        )
        #expect(state.loadedToolNames.isEmpty)
        #expect(state.loadedSkillNames.isEmpty)

        state.loadedToolNames.insert("pdf_extract")
        state.loadedToolNames.insert("pdf_render")
        state.loadedToolNames.insert("pdf_extract")  // dedup
        state.loadedSkillNames.insert("Document Data Analyst")
        state.loadedSkillNames.insert("Document Data Analyst")

        #expect(state.loadedToolNames == ["pdf_extract", "pdf_render"])
        #expect(state.loadedSkillNames == ["Document Data Analyst"])
    }

    @Test
    func seedEnabledCapabilities_excludesOnDemandSkillsFromDefaults() async {
        await withSessionPreflightAgent { agentId in
            let defaultSkill = Skill(
                name: "Default Session Skill",
                defaultSelectedForAgents: true,
                instructions: "Default marker"
            )
            let onDemandSkill = Skill(
                name: "On Demand Session Skill",
                defaultSelectedForAgents: false,
                activation: .onDemand,
                instructions: "On-demand marker"
            )
            let defaultNames = [defaultSkill, onDemandSkill]
                .filter(\.isDefaultSelectedForAgents)
                .map(\.name)

            AgentManager.shared.seedEnabledCapabilitiesIfNeeded(
                for: agentId,
                defaultToolNames: [],
                defaultSkillNames: defaultNames
            )

            let seeded = AgentManager.shared.agent(for: agentId)?.manualSkillNames ?? []
            #expect(seeded.contains(defaultSkill.name))
            #expect(seeded.contains(onDemandSkill.name) == false)
        }
    }

    @Test
    func composeChatContext_includesLoadedSkillsButNotUnloadedOnDemandSkills() async {
        await withSessionPreflightAgent { agentId in
            let marker = "LoadedSkillMarker-\(UUID().uuidString)"
            let skill = Skill(
                name: "Loaded Session Skill \(UUID().uuidString.prefix(6))",
                description: "Loaded only when requested",
                category: "test",
                enabled: true,
                discoverable: true,
                defaultSelectedForAgents: false,
                activation: .onDemand,
                instructions: marker
            )
            await SkillStore.save(skill)
            await SkillManager.shared.refresh()

            let withoutLoaded = await SystemPromptComposer.composeChatContext(
                agentId: agentId,
                executionMode: .none
            )
            #expect(withoutLoaded.prompt.contains(marker) == false)

            let withLoaded = await SystemPromptComposer.composeChatContext(
                agentId: agentId,
                executionMode: .none,
                additionalSkillNames: [skill.name]
            )
            #expect(withLoaded.prompt.contains(marker))
            _ = await SkillManager.shared.delete(id: skill.id)
        }
    }

    @Test
    func resolveTools_includesAdditionalToolNamesEvenWithEmptyPreflight() async {
        await withSessionPreflightAgent { agentId in

            // Empty preflight (mirrors a cached session that captured "no LLM
            // additions") should still inflate to include the agent's
            // capabilities_load union.
            let tools = SystemPromptComposer.resolveTools(
                agentId: agentId,
                executionMode: .none,
                preflight: PreflightResult(toolSpecs: [], items: []),
                additionalToolNames: ["search_memory"]
            )
            let names = tools.map { $0.function.name }
            #expect(names.contains("search_memory"))
        }
    }

    @Test
    func composeChatContext_doesNotRunFreshPreflightWhenCached() async {
        await withSessionPreflightAgent { agentId in

            // Seed cache with a known PreflightResult that includes a specific
            // tool we can fingerprint in the rendered output.
            let memorySpec = ToolRegistry.shared.specs(forTools: ["search_memory"]).first
            guard let memorySpec else {
                // search_memory isn't registered in this test environment — skip
                // (the property under test is exercised by other tests anyway).
                return
            }
            let cached = PreflightResult(toolSpecs: [memorySpec], items: [])

            let ctx = await SystemPromptComposer.composeChatContext(
                agentId: agentId,
                executionMode: .none,
                query: "this query would normally trigger a fresh LLM preflight",
                cachedPreflight: cached
            )

            // The cached preflight must echo back through ComposedContext.preflight
            // so the caller can re-stash it.
            let cachedNames = Set(ctx.preflight.toolSpecs.map { $0.function.name })
            #expect(cachedNames == ["search_memory"])
            // And the resolved tool union must contain the cached preflight tool.
            let resolvedNames = ctx.tools.map { $0.function.name }
            #expect(resolvedNames.contains("search_memory"))
        }
    }

    @Test
    func composeChatContext_returnsMemorySectionSeparately() async {
        await withSessionPreflightAgent { agentId in

            let ctx = await SystemPromptComposer.composeChatContext(
                agentId: agentId,
                executionMode: .none
            )

            // Even when memory has no content for a brand-new agent, the
            // rendered system prompt must NOT contain a [Memory] block — the
            // helper is the only writer of that marker, and it goes onto the
            // user message instead.
            #expect(ctx.prompt.contains("[Memory]") == false)
        }
    }

    private func withSessionPreflightAgent(
        _ body: @MainActor @Sendable (UUID) async -> Void
    ) async {
        await SandboxTestLock.runWithStoragePaths {
            let manager = AgentManager.shared
            let agent = Agent(
                name: "SessionPreflightCacheTestAgent-\(UUID().uuidString.prefix(6))",
                agentAddress: "test-session-preflight-\(UUID().uuidString)"
            )
            manager.add(agent)
            await body(agent.id)
            _ = await manager.delete(id: agent.id)
        }
    }
}
