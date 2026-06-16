//
//  HTTPHandlerEndpointTests.swift
//  OsaurusCoreTests
//
//  Handler-level coverage relocated from the (now-deleted) `Router.swift`
//  unit tests. The legacy `Router` was a dead reference dispatcher; the
//  production HTTP path is fully owned by `HTTPHandler`. These tests boot a
//  real NIO server (loopback-trusted, so the protected routes pass the auth
//  gate without a token) and assert the same endpoint behavior the old
//  `router_*` tests covered: `/health`, `/`, `/models`, `/v1/models`, and a
//  404 for an unknown path.
//

import Foundation
@preconcurrency import MLXLMCommon
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct HTTPHandlerEndpointTests {

    @Test func health_endpoint_returns_healthy_json() async throws {
        let server = try await startServer()
        defer { Task { await server.shutdown() } }

        let (data, resp) = try await URLSession.shared.data(
            from: URL(string: "http://\(server.host):\(server.port)/health")!
        )
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["status"] as? String == "healthy")
    }

    @Test func root_endpoint_returns_banner() async throws {
        let server = try await startServer()
        defer { Task { await server.shutdown() } }

        let (data, resp) = try await URLSession.shared.data(
            from: URL(string: "http://\(server.host):\(server.port)/")!
        )
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("Osaurus Server is running"))
    }

    @Test func models_endpoint_returns_list() async throws {
        let server = try await startServer()
        defer { Task { await server.shutdown() } }

        let (data, resp) = try await URLSession.shared.data(
            from: URL(string: "http://\(server.host):\(server.port)/models")!
        )
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)
        let modelsResponse = try JSONDecoder().decode(ModelsResponse.self, from: data)
        #expect(modelsResponse.object == "list")
        #expect(modelsResponse.data.count >= 0)

        // OpenAI-compatible alias.
        let (_, resp2) = try await URLSession.shared.data(
            from: URL(string: "http://\(server.host):\(server.port)/v1/models")!
        )
        #expect((resp2 as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test func unknown_path_returns_404() async throws {
        let server = try await startServer()
        defer { Task { await server.shutdown() } }

        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/unknown")!)
        request.httpMethod = "POST"
        let (_, resp) = try await URLSession.shared.data(for: request)
        #expect((resp as? HTTPURLResponse)?.statusCode == 404)
    }

    @Test func runtimeSettings_get_returnsPersistedSnapshot() async throws {
        let dir = try makeTempDirectory()
        try await withOverriddenRuntimeSettingsDirectory(dir) {
            var settings = VMLXServerRuntimeSettings()
            settings.generation.temperature = 0.31
            ServerRuntimeSettingsStore.save(settings)

            let server = try await startServer()
            defer { Task { await server.shutdown() } }

            let (data, resp) = try await URLSession.shared.data(
                from: URL(string: "http://\(server.host):\(server.port)/admin/runtime-settings")!
            )

            #expect((resp as? HTTPURLResponse)?.statusCode == 200)
            let decoded = try JSONDecoder().decode(RuntimeSettingsResponse.self, from: data)
            #expect(decoded.status == "ok")
            #expect(decoded.settings.generation.temperature == 0.31)
        }
    }

    @Test func runtimeSettings_put_persistsAndReportsRuntimeEffects() async throws {
        let dir = try makeTempDirectory()
        try await withOverriddenRuntimeSettingsDirectory(dir) {
            let initial = VMLXServerRuntimeSettings()
            ServerRuntimeSettingsStore.save(initial)

            let server = try await startServer()
            defer { Task { await server.shutdown() } }

            var next = initial
            next.generation.temperature = 0.42
            next.concurrency.maxConcurrentSequences = 2
            let (data, resp) = try await putRuntimeSettings(next, server: server)

            #expect((resp as? HTTPURLResponse)?.statusCode == 200)
            let decoded = try JSONDecoder().decode(RuntimeSettingsResponse.self, from: data)
            #expect(decoded.settings.generation.temperature == 0.42)
            #expect(decoded.settings.concurrency.maxConcurrentSequences == 2)
            #expect(decoded.effects?.runtimeConfigInvalidated == true)
            #expect(decoded.effects?.loadedModelRefreshNeeded == false)

            ServerRuntimeSettingsStore.invalidateSnapshot()
            let persisted = ServerRuntimeSettingsStore.snapshot()
            #expect(persisted.generation.temperature == 0.42)
            #expect(persisted.concurrency.maxConcurrentSequences == 2)
        }
    }

    @Test func runtimeSettings_put_performanceChange_refreshesLoadedModel() async throws {
        // Decode-performance levers (compiled decode + tied-head codec) are
        // applied at model LOAD, so toggling them must evict the resident model
        // — otherwise the UI toggle silently no-ops until a manual reload.
        let dir = try makeTempDirectory()
        try await withOverriddenRuntimeSettingsDirectory(dir) {
            let initial = VMLXServerRuntimeSettings()
            ServerRuntimeSettingsStore.save(initial)

            let server = try await startServer()
            defer { Task { await server.shutdown() } }

            // Tied-head change alone: live via reload, no restart required.
            var headOnly = initial
            headOnly.performance = VMLXServerPerformanceSettings(
                tiedHeadCodec: .q6,
                compiledDecode: false
            )
            let (headData, headResp) = try await putRuntimeSettings(headOnly, server: server)
            #expect((headResp as? HTTPURLResponse)?.statusCode == 200)
            let headDecoded = try JSONDecoder().decode(RuntimeSettingsResponse.self, from: headData)
            #expect(headDecoded.effects?.loadedModelRefreshNeeded == true)
            #expect(headDecoded.effects?.compiledDecodeRestartRequired == false)
            #expect(headDecoded.settings.effectivePerformance.tiedHeadCodec == .q6)

            // Compiled-decode toggle: a process-startup lever, so the response
            // must report restart_required (it cannot engage mid-session).
            var next = headOnly
            next.performance = VMLXServerPerformanceSettings(
                tiedHeadCodec: .q6,
                compiledDecode: true
            )
            let (data, resp) = try await putRuntimeSettings(next, server: server)

            #expect((resp as? HTTPURLResponse)?.statusCode == 200)
            let decoded = try JSONDecoder().decode(RuntimeSettingsResponse.self, from: data)
            #expect(decoded.effects?.loadedModelRefreshNeeded == true)
            #expect(decoded.effects?.compiledDecodeRestartRequired == true)
            #expect(decoded.settings.effectivePerformance.compiledDecode == true)
            #expect(decoded.settings.effectivePerformance.tiedHeadCodec == .q6)
        }
    }

    @Test func runtimeSettings_put_rejectsNetworkRebindChanges() async throws {
        let dir = try makeTempDirectory()
        try await withOverriddenRuntimeSettingsDirectory(dir) {
            let initial = VMLXServerRuntimeSettings()
            ServerRuntimeSettingsStore.save(initial)

            let server = try await startServer()
            defer { Task { await server.shutdown() } }

            var next = initial
            next.network.port = 4242
            let (_, resp) = try await putRuntimeSettings(next, server: server)

            #expect((resp as? HTTPURLResponse)?.statusCode == 400)
            ServerRuntimeSettingsStore.invalidateSnapshot()
            let persisted = ServerRuntimeSettingsStore.snapshot()
            #expect(persisted.network.port == initial.network.port)
        }
    }

    @Test func runtimeSettings_put_rejectsValidationErrors() async throws {
        let dir = try makeTempDirectory()
        try await withOverriddenRuntimeSettingsDirectory(dir) {
            let initial = VMLXServerRuntimeSettings()
            ServerRuntimeSettingsStore.save(initial)

            let server = try await startServer()
            defer { Task { await server.shutdown() } }

            var next = initial
            next.concurrency.maxConcurrentSequences = 0
            let (data, resp) = try await putRuntimeSettings(next, server: server)

            #expect((resp as? HTTPURLResponse)?.statusCode == 400)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let error = obj?["error"] as? [String: Any]
            #expect(error?["type"] as? String == "invalid_request_error")

            ServerRuntimeSettingsStore.invalidateSnapshot()
            let persisted = ServerRuntimeSettingsStore.snapshot()
            #expect(persisted.concurrency.maxConcurrentSequences == initial.concurrency.maxConcurrentSequences)
        }
    }

    // MARK: - Agent metadata resolution

    /// A paired remote peer addresses agent metadata by the agent's crypto
    /// address (the stable identity it knows), not the host-local UUID. The
    /// host must resolve that address via `AgentIdentityRegistry` so model
    /// discovery returns the real metadata instead of `invalid_agent_id`
    /// (which degraded the remote model picker to `["default"]`).
    @Test func getAgent_byCryptoAddress_resolvesMetadata() async throws {
        let server = try await startServer()
        defer { Task { await server.shutdown() } }

        try await ChatHistoryTestStorage.run {
            let hostAgentId = UUID()
            let address = "0xfeed000000000000000000000000000000000099"
            let agent = Agent(
                id: hostAgentId,
                name: "Metadata Peer",
                defaultModel: "fake-metadata-model",
                isBuiltIn: false,
                agentIndex: 0,
                agentAddress: address
            )
            AgentManager.shared.add(agent)
            AgentIdentityRegistry.shared.update(
                addresses: [address],
                indices: [0],
                addressByAgentId: [hostAgentId: address]
            )
            defer {
                AgentIdentityRegistry.shared.update(addresses: [], indices: [], addressByAgentId: [:])
            }

            // Address resolves to this agent's metadata.
            let (data, resp) = try await URLSession.shared.data(
                from: URL(string: "http://\(server.host):\(server.port)/agents/\(address)")!
            )
            #expect((resp as? HTTPURLResponse)?.statusCode == 200)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(obj?["id"] as? String == hostAgentId.uuidString)
            #expect(obj?["default_model"] as? String == "fake-metadata-model")

            // An address with no registry mapping still fails closed.
            let unknown = "0xdead000000000000000000000000000000000000"
            let (badData, badResp) = try await URLSession.shared.data(
                from: URL(string: "http://\(server.host):\(server.port)/agents/\(unknown)")!
            )
            #expect((badResp as? HTTPURLResponse)?.statusCode == 400)
            #expect(String(decoding: badData, as: UTF8.self).contains("invalid_agent_id"))

            _ = await AgentManager.shared.delete(id: hostAgentId)
        }
    }

    @Test func agents_get_exposesDefaultAgentConfigurationForLoopback() async throws {
        try await withIsolatedAgentState {
            DefaultAgentConfigurationStore.save(
                DefaultAgentConfiguration(
                    defaultModel: "global-chat-model",
                    toolSelectionMode: .manual,
                    manualToolNames: ["global_tool"],
                    manualSkillNames: ["global_skill"],
                    creationDefaults: AgentCreationDefaults(
                        defaultModel: "global-create-model",
                        temperature: 0.25,
                        maxTokens: 128,
                        toolSelectionMode: .manual,
                        manualToolNames: ["global_tool"],
                        manualSkillNames: ["global_skill"],
                        autoSpeak: false,
                        ttsVoice: "global-voice"
                    )
                )
            )

            let server = try await startServer()
            defer { Task { await server.shutdown() } }

            let (data, response) = try await jsonRequest("/agents", server: server)

            #expect(response.statusCode == 200)
            let decoded = try JSONDecoder().decode(AgentListEnvelope.self, from: data)
            let defaultAgent = try #require(decoded.agents.first { $0.id == Agent.defaultId.uuidString })
            #expect(defaultAgent.is_built_in == true)
            #expect(defaultAgent.default_model == "global-chat-model")
            #expect(defaultAgent.tool_selection_mode == "manual")
            #expect(defaultAgent.manual_tool_names == ["global_tool"])
            #expect(defaultAgent.manual_skill_names == ["global_skill"])
            #expect(defaultAgent.creation_defaults?.default_model == "global-create-model")
            #expect(defaultAgent.creation_defaults?.temperature == 0.25)
            #expect(defaultAgent.creation_defaults?.max_tokens == 128)
            #expect(defaultAgent.creation_defaults?.auto_speak == false)
            #expect(defaultAgent.creation_defaults?.tts_voice == "global-voice")
        }
    }

    @Test func agents_api_requiresAccessKeyWhenLoopbackTrustIsDisabled() async throws {
        let server = try await startServer(trustLoopback: false)
        defer { Task { await server.shutdown() } }

        let (_, response) = try await jsonRequest("/agents", server: server)

        #expect(response.statusCode == 401)
    }

    @Test func agents_post_appliesDefaultTeamAndRequestPrecedence() async throws {
        try await withIsolatedAgentState {
            DefaultAgentConfigurationStore.save(
                DefaultAgentConfiguration(
                    creationDefaults: AgentCreationDefaults(
                        defaultModel: "global-model",
                        temperature: 0.15,
                        maxTokens: 128,
                        toolSelectionMode: .manual,
                        manualToolNames: ["global_tool"],
                        manualSkillNames: ["global_skill"],
                        autoSpeak: false,
                        ttsVoice: "global-voice"
                    )
                )
            )

            let server = try await startServer()
            defer { Task { await server.shutdown() } }

            let (_, teamResponse) = try await jsonRequest(
                "/agents/teams/research",
                method: "PUT",
                body: [
                    "name": "Research",
                    "description": "Research defaults",
                    "defaults": [
                        "default_model": "team-model",
                        "manual_tool_names": ["search_memory"],
                        "auto_speak": true,
                    ],
                ],
                server: server
            )
            #expect(teamResponse.statusCode == 201)

            let (data, createResponse) = try await jsonRequest(
                "/agents",
                method: "POST",
                body: [
                    "name": "API Defaults Test \(UUID().uuidString)",
                    "team_id": "research",
                    "temperature": 0.7,
                    "tts_voice": "request-voice",
                ],
                server: server
            )

            #expect(createResponse.statusCode == 201)
            let created = try JSONDecoder().decode(AgentItemEnvelope.self, from: data).agent
            #expect(created.default_model == "team-model")
            #expect(created.temperature == 0.7)
            #expect(created.max_tokens == 128)
            #expect(created.tool_selection_mode == "manual")
            #expect(created.manual_tool_names == ["search_memory"])
            #expect(created.manual_skill_names == ["global_skill"])
            #expect(created.auto_speak == true)
            #expect(created.tts_voice == "request-voice")
            #expect(created.team_ids == ["research"])

            let createdId = try #require(UUID(uuidString: created.id))
            let persisted = try #require(AgentManager.shared.agent(for: createdId))
            #expect(persisted.defaultModel == "team-model")
            #expect(persisted.temperature == 0.7)
            #expect(persisted.maxTokens == 128)
            #expect(persisted.manualToolNames == ["search_memory"])
            #expect(persisted.manualSkillNames == ["global_skill"])
            #expect(AgentTeamConfigurationStore.teamIds(containing: createdId) == ["research"])
        }
    }

    @Test func agents_patch_updatesCustomAgentAndTeamMembership() async throws {
        try await withIsolatedAgentState {
            let server = try await startServer()
            defer { Task { await server.shutdown() } }

            for teamId in ["research", "operators"] {
                let (_, response) = try await jsonRequest(
                    "/agents/teams/\(teamId)",
                    method: "PUT",
                    body: ["name": teamId.capitalized],
                    server: server
                )
                #expect(response.statusCode == 201)
            }

            let (createData, createResponse) = try await jsonRequest(
                "/agents",
                method: "POST",
                body: [
                    "name": "Patch Target \(UUID().uuidString)",
                    "team_id": "research",
                ],
                server: server
            )
            #expect(createResponse.statusCode == 201)
            let created = try JSONDecoder().decode(AgentItemEnvelope.self, from: createData).agent

            let (patchData, patchResponse) = try await jsonRequest(
                "/agents/\(created.id)",
                method: "PATCH",
                body: [
                    "name": "Renamed Agent",
                    "default_model": "patched-model",
                    "tools_enabled": false,
                    "memory_enabled": false,
                    "tool_selection_mode": "manual",
                    "manual_skill_names": ["planner"],
                    "team_ids": ["operators"],
                ],
                server: server
            )

            #expect(patchResponse.statusCode == 200)
            let patched = try JSONDecoder().decode(AgentItemEnvelope.self, from: patchData).agent
            #expect(patched.name == "Renamed Agent")
            #expect(patched.default_model == "patched-model")
            #expect(patched.tools_enabled == false)
            #expect(patched.memory_enabled == false)
            #expect(patched.tool_selection_mode == "manual")
            #expect(patched.manual_skill_names == ["planner"])
            #expect(patched.team_ids == ["operators"])

            let agentId = try #require(UUID(uuidString: created.id))
            let persisted = try #require(AgentManager.shared.agent(for: agentId))
            #expect(persisted.name == "Renamed Agent")
            #expect(persisted.defaultModel == "patched-model")
            #expect(persisted.toolsEnabled == false)
            #expect(persisted.memoryEnabled == false)
            #expect(persisted.manualSkillNames == ["planner"])
            #expect(AgentTeamConfigurationStore.teamIds(containing: agentId) == ["operators"])
        }
    }

    @Test func agentDefault_patch_persistsCreationDefaults() async throws {
        try await withIsolatedAgentState {
            let server = try await startServer()
            defer { Task { await server.shutdown() } }

            let (data, response) = try await jsonRequest(
                "/agents/default",
                method: "PATCH",
                body: [
                    "creation_defaults": [
                        "default_model": "patched-default-model",
                        "manual_skill_names": ["planner"],
                    ],
                ],
                server: server
            )

            #expect(response.statusCode == 200)
            let patched = try JSONDecoder().decode(AgentItemEnvelope.self, from: data).agent
            #expect(patched.creation_defaults?.default_model == "patched-default-model")
            #expect(patched.creation_defaults?.manual_skill_names == ["planner"])

            let saved = DefaultAgentConfigurationStore.load()
            #expect(saved.creationDefaults.defaultModel == "patched-default-model")
            #expect(saved.creationDefaults.manualSkillNames == ["planner"])
        }
    }

    // MARK: - Test Server Bootstrap

    private struct TestServer {
        let group: MultiThreadedEventLoopGroup
        let channel: Channel
        let lease: HTTPServerTestLease
        let host: String
        let port: Int

        func shutdown() async {
            _ = try? await channel.close()
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                group.shutdownGracefully { _ in cont.resume() }
            }
            await lease.release()
        }
    }

    private func startServer(trustLoopback: Bool = true) async throws -> TestServer {
        let config = ServerConfiguration.default
        let lease = await HTTPServerTestLock.shared.acquire()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 256)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.pipeline.addHandler(
                            HTTPHandler(
                                configuration: config,
                                apiKeyValidator: .empty,
                                eventLoop: channel.eventLoop,
                                trustLoopback: trustLoopback
                            )
                        )
                    }
                }
                .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)

            let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
            let port = ch.localAddress?.port ?? 0
            return TestServer(group: group, channel: ch, lease: lease, host: "127.0.0.1", port: port)
        } catch {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                group.shutdownGracefully { _ in cont.resume() }
            }
            await lease.release()
            throw error
        }
    }

    private struct RuntimeSettingsResponse: Decodable {
        let status: String
        let settings: VMLXServerRuntimeSettings
        let effects: RuntimeSettingsEffects?
    }

    private struct AgentListEnvelope: Decodable {
        let agents: [AgentSummary]
    }

    private struct AgentItemEnvelope: Decodable {
        let agent: AgentSummary
    }

    private struct AgentSummary: Decodable {
        let id: String
        let name: String
        let default_model: String?
        let temperature: Float?
        let max_tokens: Int?
        let is_built_in: Bool
        let tools_enabled: Bool
        let memory_enabled: Bool
        let tool_selection_mode: String
        let manual_tool_names: [String]?
        let manual_skill_names: [String]?
        let auto_speak: Bool?
        let tts_voice: String?
        let team_ids: [String]
        let creation_defaults: AgentDefaultsSummary?
    }

    private struct AgentDefaultsSummary: Decodable {
        let default_model: String?
        let temperature: Float?
        let max_tokens: Int?
        let tool_selection_mode: String?
        let manual_tool_names: [String]?
        let manual_skill_names: [String]?
        let auto_speak: Bool?
        let tts_voice: String?
    }

    private struct RuntimeSettingsEffects: Decodable {
        let loadedModelRefreshNeeded: Bool?
        let runtimeConfigInvalidated: Bool?
        let compiledDecodeRestartRequired: Bool?

        private enum CodingKeys: String, CodingKey {
            case loadedModelRefreshNeeded = "loaded_model_refresh_needed"
            case runtimeConfigInvalidated = "runtime_config_invalidated"
            case compiledDecodeRestartRequired = "compiled_decode_restart_required"
        }
    }

    private func putRuntimeSettings(
        _ settings: VMLXServerRuntimeSettings,
        server: TestServer
    ) async throws -> (Data, URLResponse) {
        var request = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/admin/runtime-settings")!
        )
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(settings)
        return try await URLSession.shared.data(for: request)
    }

    private func jsonRequest(
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        server: TestServer
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)\(path)")!)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, httpResponse)
    }

    private func makeTempDirectory(prefix: String = "osaurus-runtime-settings-endpoint") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    private func withOverriddenRuntimeSettingsDirectory(
        _ dir: URL,
        _ body: () async throws -> Void
    ) async throws {
        let previous = ServerRuntimeSettingsStore.overrideDirectory
        ServerRuntimeSettingsStore.overrideDirectory = dir
        ServerRuntimeSettingsStore.invalidateSnapshot()
        defer {
            ServerRuntimeSettingsStore.overrideDirectory = previous
            ServerRuntimeSettingsStore.invalidateSnapshot()
            try? FileManager.default.removeItem(at: dir)
        }
        try await body()
    }

    @MainActor
    private func withIsolatedAgentState(
        _ body: @MainActor @Sendable () async throws -> Void
    ) async throws {
        try await SandboxTestLock.runWithStoragePaths {
            let root = try makeTempDirectory(prefix: "osaurus-agent-config-endpoint")
            let configDir = root.appendingPathComponent("config", isDirectory: true)

            let previousRoot = OsaurusPaths.overrideRoot
            let previousDefaultDirectory = DefaultAgentConfigurationStore.overrideDirectory
            let previousTeamDirectory = AgentTeamConfigurationStore.overrideDirectory
            let previousAvailability = SandboxManager.State.shared.availability
            let previousStatus = SandboxManager.State.shared.status

            OsaurusPaths.overrideRoot = root
            DefaultAgentConfigurationStore.overrideDirectory = configDir
            AgentTeamConfigurationStore.overrideDirectory = configDir
            DefaultAgentConfigurationStore.resetCacheForTests()
            AgentTeamConfigurationStore.resetCacheForTests()
            SandboxManager.State.shared.availability = .unavailable(
                reason: "sandbox disabled for agent endpoint tests"
            )
            SandboxManager.State.shared.status = .notProvisioned
            AgentManager.shared.refresh()

            defer {
                AgentManager.shared.refresh()
                DefaultAgentConfigurationStore.overrideDirectory = previousDefaultDirectory
                AgentTeamConfigurationStore.overrideDirectory = previousTeamDirectory
                DefaultAgentConfigurationStore.resetCacheForTests()
                AgentTeamConfigurationStore.resetCacheForTests()
                OsaurusPaths.overrideRoot = previousRoot
                AgentManager.shared.refresh()
                SandboxManager.State.shared.availability = previousAvailability
                SandboxManager.State.shared.status = previousStatus
                try? FileManager.default.removeItem(at: root)
            }

            try await body()
        }
    }
}
