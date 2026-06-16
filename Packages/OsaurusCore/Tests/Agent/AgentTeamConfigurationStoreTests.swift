//
//  AgentTeamConfigurationStoreTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct AgentTeamConfigurationStoreTests {

    @MainActor
    private static func withTempOverride<T>(
        body: @MainActor () throws -> T
    ) async rethrows -> T {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-agent-teams-\(UUID().uuidString)",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let previous = AgentTeamConfigurationStore.overrideDirectory
        AgentTeamConfigurationStore.overrideDirectory = tmp
        AgentTeamConfigurationStore.resetCacheForTests()
        defer {
            AgentTeamConfigurationStore.overrideDirectory = previous
            AgentTeamConfigurationStore.resetCacheForTests()
            try? FileManager.default.removeItem(at: tmp)
        }
        return try body()
    }

    @Test
    @MainActor
    func roundTrip_normalizesMembershipAndDefaults() async throws {
        try await StoragePathsTestLock.shared.run {
            try await Self.withTempOverride {
                let agentA = UUID()
                let agentB = UUID()
                let team = AgentTeamConfiguration(
                    id: "research",
                    name: "Research",
                    description: "Reader agents",
                    memberAgentIds: [agentB, agentA, agentB],
                    defaults: AgentCreationDefaults(
                        defaultModel: "mlx-community/Qwen3-4B-Instruct",
                        manualToolNames: ["search_memory"],
                        ttsVoice: "nova"
                    )
                )

                AgentTeamConfigurationStore.save([team])
                AgentTeamConfigurationStore.resetCacheForTests()

                let reloaded = try #require(AgentTeamConfigurationStore.team(id: "research"))
                #expect(reloaded.memberAgentIds == [agentA, agentB].sorted { $0.uuidString < $1.uuidString })
                #expect(reloaded.defaults.defaultModel == "mlx-community/Qwen3-4B-Instruct")
                #expect(reloaded.defaults.manualToolNames == ["search_memory"])
                #expect(reloaded.defaults.ttsVoice == "nova")
            }
        }
    }

    @Test
    @MainActor
    func assignAgent_addsMembershipIdempotently() async throws {
        try await StoragePathsTestLock.shared.run {
            try await Self.withTempOverride {
                let agentId = UUID()
                AgentTeamConfigurationStore.upsert(
                    AgentTeamConfiguration(id: "ops", name: "Ops")
                )

                AgentTeamConfigurationStore.assign(agentId: agentId, toTeamId: "ops")
                AgentTeamConfigurationStore.assign(agentId: agentId, toTeamId: "ops")

                #expect(AgentTeamConfigurationStore.teamIds(containing: agentId) == ["ops"])
                let team = try #require(AgentTeamConfigurationStore.team(id: "ops"))
                #expect(team.memberAgentIds == [agentId])
            }
        }
    }

    @Test
    @MainActor
    func teamIdValidation_allowsStableURLSafeIdsOnly() {
        #expect(AgentTeamConfigurationStore.isValidTeamId("research-1"))
        #expect(AgentTeamConfigurationStore.isValidTeamId("ops_team"))
        #expect(!AgentTeamConfigurationStore.isValidTeamId(""))
        #expect(!AgentTeamConfigurationStore.isValidTeamId("has space"))
        #expect(!AgentTeamConfigurationStore.isValidTeamId("not/slash"))
    }
}
