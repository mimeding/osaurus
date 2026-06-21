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

    @Test func agentWorkspaces_createListAndAttachSources() async throws {
        try await SandboxTestLock.runWithStoragePaths {
            let root = try makeTempDirectory(prefix: "osaurus-agent-workspace-http")
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            let agent = Agent(
                name: "WorkspaceHTTP-\(UUID().uuidString.prefix(6))",
                systemPrompt: "HTTP workspace test",
                agentAddress: "workspace-http-\(UUID().uuidString)"
            )

            do {
                AgentManager.shared.add(agent)
                let initialSource = root.appendingPathComponent("initial.md")
                try "Initial workspace facts.".write(to: initialSource, atomically: true, encoding: .utf8)
                let attachedSource = root.appendingPathComponent("attached.md")
                try "Attached workspace facts.".write(to: attachedSource, atomically: true, encoding: .utf8)

                let server = try await startServer()
                defer { Task { await server.shutdown() } }

                let create = AgentWorkspaceCreateBody(
                    name: "HTTP Workspace",
                    description: "Workspace created through HTTP.",
                    paths: [initialSource.path]
                )
                let (createData, createResp) = try await postJSON(
                    create,
                    path: "/agents/\(agent.id.uuidString)/workspaces",
                    server: server
                )
                #expect((createResp as? HTTPURLResponse)?.statusCode == 201)
                let created = try JSONDecoder().decode(AgentWorkspaceMutationBody.self, from: createData)
                #expect(created.workspace.name == "HTTP Workspace")
                #expect(created.workspace.sources.count == 1)

                let (listData, listResp) = try await URLSession.shared.data(
                    from: URL(string: "http://\(server.host):\(server.port)/agents/\(agent.id.uuidString)/workspaces")!
                )
                #expect((listResp as? HTTPURLResponse)?.statusCode == 200)
                let listed = try JSONDecoder().decode(AgentWorkspaceListBody.self, from: listData)
                #expect(listed.workspaces.map(\.id).contains(created.workspace.id))

                let attach = AgentWorkspaceSourcesBody(paths: [attachedSource.path])
                let (attachData, attachResp) = try await postJSON(
                    attach,
                    path: "/agents/\(agent.id.uuidString)/workspaces/\(created.workspace.id)/sources",
                    server: server
                )
                #expect((attachResp as? HTTPURLResponse)?.statusCode == 200)
                let attached = try JSONDecoder().decode(AgentWorkspaceMutationBody.self, from: attachData)
                #expect(attached.workspace.sources.count == 2)

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

    @Test func agentWorkspaces_remoteCallerCannotInspectHostSourcePath() async throws {
        try await SandboxTestLock.runWithStoragePaths {
            let root = try makeTempDirectory(prefix: "osaurus-agent-workspace-http-remote")
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            let agent = Agent(
                name: "WorkspaceHTTPRemote-\(UUID().uuidString.prefix(6))",
                systemPrompt: "HTTP workspace remote test",
                agentAddress: "workspace-http-remote-\(UUID().uuidString)"
            )

            do {
                AgentManager.shared.add(agent)
                let source = root.appendingPathComponent("remote.md")
                try "Remote caller must not receive this.".write(to: source, atomically: true, encoding: .utf8)
                let localWorkspace = try AgentWorkspaceStore.create(
                    agentId: agent.id,
                    name: "Local Workspace",
                    paths: [source.path],
                    sourceAuthorization: .trustedLocal
                )

                let server = try await startServer(
                    trustLoopback: false,
                    apiKeyValidator: .forAlice()
                )
                defer { Task { await server.shutdown() } }
                let token = try TokenBuilder.build(
                    privateKey: TestKeys.alicePrivateKey,
                    iss: TestKeys.aliceAddress,
                    aud: TestKeys.aliceAddress
                )
                let create = AgentWorkspaceCreateBody(
                    name: "Remote Workspace",
                    description: "Attempted remote source attach.",
                    paths: [source.path]
                )
                let (data, response) = try await postJSON(
                    create,
                    path: "/agents/\(agent.id.uuidString)/workspaces",
                    server: server,
                    authorization: "Bearer \(token)"
                )

                #expect((response as? HTTPURLResponse)?.statusCode == 403)
                let body = String(decoding: data, as: UTF8.self)
                #expect(body.contains("workspace_source_inspection_denied"))
                #expect(body.contains("Remote caller must not receive this") == false)

                let (listData, listResponse) = try await get(
                    path: "/agents/\(agent.id.uuidString)/workspaces",
                    server: server,
                    authorization: "Bearer \(token)"
                )
                #expect((listResponse as? HTTPURLResponse)?.statusCode == 200)
                let listed = try JSONDecoder().decode(AgentWorkspaceListBody.self, from: listData)
                let listedLocal = try #require(listed.workspaces.first { $0.id == localWorkspace.id.uuidString })
                let listedSource = try #require(listedLocal.sources.first)
                #expect(listedSource.path == source.lastPathComponent)
                #expect(listedSource.summary == nil)
                #expect(listedSource.error == nil)
                #expect(listedSource.byte_count == nil)
                #expect(listedSource.item_count == nil)
                #expect(listedSource.indexed_at == nil)
                let listBody = String(decoding: listData, as: UTF8.self)
                #expect(listBody.contains(source.path) == false)
                #expect(listBody.contains("Remote caller must not receive this") == false)

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

    private func startServer(
        trustLoopback: Bool = true,
        apiKeyValidator: APIKeyValidator = .empty
    ) async throws -> TestServer {
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
                                apiKeyValidator: apiKeyValidator,
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

    private struct AgentWorkspaceCreateBody: Encodable {
        let name: String
        let description: String
        let paths: [String]
    }

    private struct AgentWorkspaceSourcesBody: Encodable {
        let paths: [String]
    }

    private struct AgentWorkspaceListBody: Decodable {
        let workspaces: [AgentWorkspaceItemBody]
    }

    private struct AgentWorkspaceMutationBody: Decodable {
        let workspace: AgentWorkspaceItemBody
    }

    private struct AgentWorkspaceItemBody: Decodable {
        let id: String
        let name: String
        let sources: [AgentWorkspaceSourceBody]
    }

    private struct AgentWorkspaceSourceBody: Decodable {
        let path: String
        let status: String
        let byte_count: Int64?
        let item_count: Int?
        let summary: String?
        let error: String?
        let indexed_at: String?
    }

    private func get(
        path: String,
        server: TestServer,
        authorization: String? = nil
    ) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)\(path)")!)
        request.httpMethod = "GET"
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        return try await URLSession.shared.data(for: request)
    }

    private func postJSON<T: Encodable>(
        _ value: T,
        path: String,
        server: TestServer,
        authorization: String? = nil
    ) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(value)
        return try await URLSession.shared.data(for: request)
    }

    private func makeTempDirectory() throws -> URL {
        try makeTempDirectory(prefix: "osaurus-runtime-settings-endpoint")
    }

    private func makeTempDirectory(prefix: String) throws -> URL {
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
}
