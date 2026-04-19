//
//  SystemPromptComposerToolResolutionTests.swift
//  osaurusTests
//
//  Verifies the contract of `SystemPromptComposer.resolveTools` across the
//  matrix of (toolMode: auto|manual) x (executionMode: none|sandbox) x
//  (manualNames empty|set). These tests pin down the user-facing spec:
//   - Auto mode = always-loaded built-ins + preflight additions.
//   - Manual mode = strict user selection (PLUS sandbox built-ins when
//     execution mode is sandbox/autonomous).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct SystemPromptComposerToolResolutionTests {

    // MARK: - Helpers

    private func withSandboxAgent(
        autonomous: Bool,
        manualToolNames: [String]? = nil,
        body: (UUID) async -> Void
    ) async {
        let manager = AgentManager.shared
        let agent: Agent
        if let names = manualToolNames {
            agent = Agent(
                name: "ToolResolutionTestAgent-\(UUID().uuidString.prefix(6))",
                autonomousExec: autonomous ? AutonomousExecConfig(enabled: true) : nil,
                toolSelectionMode: .manual,
                manualToolNames: names
            )
        } else {
            agent = Agent(
                name: "ToolResolutionTestAgent-\(UUID().uuidString.prefix(6))",
                autonomousExec: autonomous ? AutonomousExecConfig(enabled: true) : nil
            )
        }
        manager.add(agent)
        defer { Task { _ = await manager.delete(id: agent.id) } }
        await body(agent.id)
    }

    private func registerSandboxBuiltins(_ body: () -> Void) {
        BuiltinSandboxTools.register(
            agentId: "tool-resolution-test",
            agentName: "tool-resolution-test",
            config: AutonomousExecConfig(enabled: true)
        )
        defer { ToolRegistry.shared.unregisterAllSandboxTools() }
        body()
    }

    // MARK: - Auto mode

    @Test
    func autoMode_includesAlwaysLoadedAndPreflightAdditions() async {
        await withSandboxAgent(autonomous: false) { agentId in
            let preflight = PreflightResult(toolSpecs: [], items: [])
            let tools = SystemPromptComposer.resolveTools(
                agentId: agentId,
                executionMode: .none,
                preflight: preflight
            )
            // Built-ins like capabilities_search must be present in auto mode.
            #expect(tools.contains { $0.function.name == "capabilities_search" })
        }
    }

    // MARK: - Manual mode (strict)

    @Test
    func manualMode_excludesAlwaysLoadedToolsWhenSandboxOff() async {
        await withSandboxAgent(autonomous: false, manualToolNames: ["render_chart"]) { agentId in
            let tools = SystemPromptComposer.resolveTools(
                agentId: agentId,
                executionMode: .none
            )
            // Manual mode is strict: nothing besides the user's selection.
            #expect(tools.count == 1)
            #expect(tools.first?.function.name == "render_chart")
            // Capability discovery tools must be absent.
            #expect(tools.contains { $0.function.name == "capabilities_search" } == false)
            // Memory/graph/charts built-ins must NOT leak in.
            #expect(tools.contains { $0.function.name == "search_working_memory" } == false)
        }
    }

    @Test
    func manualMode_includesSandboxBuiltinsWhenSandboxActive() async {
        await withSandboxAgent(autonomous: true, manualToolNames: ["render_chart"]) { agentId in
            registerSandboxBuiltins {
                let tools = SystemPromptComposer.resolveTools(
                    agentId: agentId,
                    executionMode: .sandbox
                )
                #expect(tools.contains { $0.function.name == "render_chart" })
                // Sandbox built-ins are additive when sandbox is active.
                #expect(tools.contains { $0.function.name == "sandbox_exec" })
                // Non-sandbox built-ins are still excluded.
                #expect(tools.contains { $0.function.name == "search_working_memory" } == false)
            }
        }
    }

    @Test
    func manualMode_emptyManualNames_yieldsOnlySandboxBuiltinsInSandboxMode() async {
        await withSandboxAgent(autonomous: true, manualToolNames: []) { agentId in
            registerSandboxBuiltins {
                let tools = SystemPromptComposer.resolveTools(
                    agentId: agentId,
                    executionMode: .sandbox
                )
                // No manual selection → only sandbox built-ins remain. The
                // built-in set includes `share_artifact` alongside the
                // `sandbox_*` family, so we assert membership in the live
                // registry's snapshot rather than a name prefix.
                let names = Set(tools.map { $0.function.name })
                let allowed = ToolRegistry.shared.builtInSandboxToolNamesSnapshot
                #expect(names.isSubset(of: allowed) || names.isEmpty)
                // Built-ins like capabilities_search MUST NOT be there.
                #expect(names.contains("capabilities_search") == false)
            }
        }
    }

    // MARK: - Tools disabled

    @Test
    func toolsDisabled_returnsEmpty() async {
        await withSandboxAgent(autonomous: true) { agentId in
            registerSandboxBuiltins {
                let tools = SystemPromptComposer.resolveTools(
                    agentId: agentId,
                    executionMode: .sandbox,
                    toolsDisabled: true
                )
                #expect(tools.isEmpty)
            }
        }
    }

    // MARK: - Auto-mode preflight query fallback

    @Test
    func resolvePreflightQuery_prefersExplicitQuery() {
        let messages: [ChatMessage] = [
            ChatMessage(role: "user", content: "old question")
        ]
        let resolved = SystemPromptComposer.resolvePreflightQuery(
            query: "fresh question",
            messages: messages
        )
        #expect(resolved == "fresh question")
    }

    @Test
    func resolvePreflightQuery_fallsBackToLastUserMessageWhenQueryEmpty() {
        let messages: [ChatMessage] = [
            ChatMessage(role: "user", content: "first"),
            ChatMessage(role: "assistant", content: "ok"),
            ChatMessage(role: "user", content: "second"),
        ]
        let resolved = SystemPromptComposer.resolvePreflightQuery(
            query: "",
            messages: messages
        )
        #expect(resolved == "second")
    }

    @Test
    func resolvePreflightQuery_returnsEmptyWhenNothingAvailable() {
        let resolved = SystemPromptComposer.resolvePreflightQuery(
            query: "",
            messages: []
        )
        #expect(resolved.isEmpty)
    }

    // MARK: - additionalToolNames

    @Test
    func resolveTools_autoMode_mergesAdditionalToolNames() async {
        await withSandboxAgent(autonomous: false) { agentId in
            // search_working_memory is a built-in always-loaded tool; ask the
            // resolver to also include `methods_save` via additionalToolNames
            // and verify it lands in the union without duplicates.
            let tools = SystemPromptComposer.resolveTools(
                agentId: agentId,
                executionMode: .none,
                additionalToolNames: ["methods_save"]
            )
            let names = tools.map { $0.function.name }
            #expect(names.contains("methods_save"))
            #expect(Set(names).count == names.count)
        }
    }

    // MARK: - canonicalToolOrder

    @Test
    func canonicalToolOrder_isStableAcrossInvocations() async {
        await withSandboxAgent(autonomous: true) { agentId in
            registerSandboxBuiltins {
                // Two compositions with identical inputs must return the
                // exact same tool ordering — that's what makes the rendered
                // <tools> block byte-stable across sends.
                let a = SystemPromptComposer.resolveTools(agentId: agentId, executionMode: .sandbox)
                let b = SystemPromptComposer.resolveTools(agentId: agentId, executionMode: .sandbox)
                let aNames = a.map { $0.function.name }
                let bNames = b.map { $0.function.name }
                #expect(aNames == bNames)

                // Sandbox built-ins must come first, capability tools next.
                if let firstSandbox = aNames.firstIndex(where: { $0.hasPrefix("sandbox_") }),
                    let firstCapability = aNames.firstIndex(of: "capabilities_search")
                {
                    #expect(firstSandbox < firstCapability)
                }
            }
        }
    }
}
