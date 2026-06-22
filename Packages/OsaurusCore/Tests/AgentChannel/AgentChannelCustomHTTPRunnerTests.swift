//
//  AgentChannelCustomHTTPRunnerTests.swift
//  osaurusTests
//
//  Security and routing coverage for JSON-backed custom agent channels.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Agent Channel custom HTTP runner", .serialized)
struct AgentChannelCustomHTTPRunnerTests {
    @Test func sendMessageRendersBoundedRequestAndRedactsSecrets() async throws {
        try await Self.withIsolatedAgentChannelConfiguration(
            connection: Self.webhookConnection(writeEnabled: true)
        ) {
            let secret = "custom-channel-secret-token"
            let session = CustomHTTPStubProtocol.session { request in
                #expect(request.httpMethod == "POST")
                #expect(request.url?.scheme == "https")
                #expect(request.url?.host == "hooks.example.test")
                #expect(
                    request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath }
                        == "/api/rooms/alerts%2Fprod/messages"
                )
                #expect(request.url?.query?.contains("thread=incident-42") == true)
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(secret)")
                let body = String(data: request.httpBodyStreamData ?? request.httpBody ?? Data(), encoding: .utf8)
                #expect(body == #"{"text":"Ship \"now\""}"#)
                return (
                    200,
                    Data(#"{"id":"msg-1","content":"sent with custom-channel-secret-token"}"#.utf8),
                    ["content-type": "application/json"]
                )
            }
            let runner = AgentChannelCustomHTTPRunner(
                session: session,
                secretResolver: StaticCustomHTTPSecretResolver(secrets: ["bearer": secret])
            )
            let service = AgentChannelConnectionService(
                discordService: DiscordConnectionService(
                    client: FakeAgentChannelDiscordAPIClient(),
                    credentialStore: InMemoryAgentChannelDiscordCredentials()
                ),
                customHTTPRunner: runner
            )

            let result = try await service.sendMessage(
                connectionId: "ops-webhook",
                roomId: "alerts/prod",
                content: #"Ship "now""#,
                confirmSend: true
            )

            #expect(result["connection_id"] as? String == "ops-webhook")
            #expect(result["standard_kind"] as? String == "message_sent")
            #expect(result["http_status"] as? Int == 200)
            #expect(String(describing: result).contains("[REDACTED:AGENT_CHANNEL_SECRET]"))
            #expect(!String(describing: result).contains(secret))
            #expect(await CustomHTTPStubProtocol.requestCount() == 1)
        }
    }

    @Test func draftMessagePreviewsRequestWithoutNetworkAndRedactsSecrets() async throws {
        try await Self.withIsolatedAgentChannelConfiguration(
            connection: Self.webhookConnection(writeEnabled: false)
        ) {
            let secret = "custom-channel-secret-token"
            let session = CustomHTTPStubProtocol.session { _ in
                Issue.record("Draft preview must not execute HTTP")
                return (200, Data(), [:])
            }
            let runner = AgentChannelCustomHTTPRunner(
                session: session,
                secretResolver: StaticCustomHTTPSecretResolver(secrets: ["bearer": secret])
            )
            let service = AgentChannelConnectionService(
                discordService: DiscordConnectionService(
                    client: FakeAgentChannelDiscordAPIClient(),
                    credentialStore: InMemoryAgentChannelDiscordCredentials()
                ),
                customHTTPRunner: runner
            )

            let draft = try service.draftMessage(
                connectionId: "ops-webhook",
                roomId: "alerts/prod",
                content: "Preview only"
            )

            #expect(draft["requires_send_confirmation"] as? Bool == true)
            #expect(String(describing: draft).contains("[REDACTED:AGENT_CHANNEL_SECRET]"))
            #expect(!String(describing: draft).contains(secret))
            #expect(await CustomHTTPStubProtocol.requestCount() == 0)
        }
    }

    @Test func writeActionsRequireWriteEnabledAndConfirmation() async throws {
        try await Self.withIsolatedAgentChannelConfiguration(
            connection: Self.webhookConnection(writeEnabled: false)
        ) {
            let runner = AgentChannelCustomHTTPRunner(
                session: CustomHTTPStubProtocol.session { _ in
                    Issue.record("Disabled write must not execute HTTP")
                    return (200, Data(), [:])
                },
                secretResolver: StaticCustomHTTPSecretResolver(secrets: ["bearer": "custom-channel-secret-token"])
            )
            let service = AgentChannelConnectionService(
                discordService: DiscordConnectionService(
                    client: FakeAgentChannelDiscordAPIClient(),
                    credentialStore: InMemoryAgentChannelDiscordCredentials()
                ),
                customHTTPRunner: runner
            )

            await #expect(throws: AgentChannelCustomHTTPRunnerError.writeDisabled("ops-webhook")) {
                try await service.sendMessage(
                    connectionId: "ops-webhook",
                    roomId: "alerts/prod",
                    content: "Ship it",
                    confirmSend: true
                )
            }

            try AgentChannelConfigurationStore.save(
                AgentChannelConfiguration(connections: [Self.webhookConnection(writeEnabled: true)])
            )

            await #expect(throws: AgentChannelCustomHTTPRunnerError.writeConfirmationRequired) {
                try await service.sendMessage(
                    connectionId: "ops-webhook",
                    roomId: "alerts/prod",
                    content: "Ship it",
                    confirmSend: false
                )
            }
            #expect(await CustomHTTPStubProtocol.requestCount() == 0)
        }
    }

    @Test func rejectsUnsafeURLsMethodsHeadersAndTemplates() async throws {
        let manager = AgentChannelConnectionManager()

        try await Self.withIsolatedAgentChannelConfiguration(connection: nil) {
            #expect(throws: AgentChannelConnectionManagerError.invalidCustomHTTPBaseURL("http://127.0.0.1:8080")) {
                try manager.upsertConnection(Self.webhookConnection(baseURL: "http://127.0.0.1:8080"))
            }

            #expect(throws: AgentChannelConnectionManagerError.invalidCustomHTTPBaseURL("https://metadata.local")) {
                try manager.upsertConnection(Self.webhookConnection(baseURL: "https://metadata.local"))
            }

            #expect(throws: AgentChannelConnectionManagerError.invalidCustomHTTPBaseURL("https://[fc00::1]")) {
                try manager.upsertConnection(Self.webhookConnection(baseURL: "https://[fc00::1]"))
            }

            #expect(throws: AgentChannelConnectionManagerError.invalidCustomHTTPMethod(
                action: "send_message",
                method: "TRACE"
            )) {
                try manager.upsertConnection(Self.webhookConnection(method: "TRACE"))
            }

            #expect(throws: AgentChannelConnectionManagerError.invalidCustomHTTPHeader(
                action: "send_message",
                header: "Authorization"
            )) {
                try manager.upsertConnection(Self.webhookConnection(headerValue: "Bearer ok\r\nInjected: value"))
            }

            try manager.upsertConnection(Self.webhookConnection(baseURL: "https://fc-provider.example.test"))
        }

        try await Self.withIsolatedAgentChannelConfiguration(
            connection: Self.webhookConnection(bodyTemplate: #"{"text":"${missing}"}"#, writeEnabled: true)
        ) {
            let runner = AgentChannelCustomHTTPRunner(
                session: CustomHTTPStubProtocol.session { _ in
                    Issue.record("Malformed template must not execute HTTP")
                    return (200, Data(), [:])
                },
                secretResolver: StaticCustomHTTPSecretResolver(secrets: ["bearer": "custom-channel-secret-token"])
            )
            await #expect(throws: AgentChannelCustomHTTPRunnerError.unsupportedPlaceholder("missing")) {
                try await runner.sendMessage(
                    connection: Self.webhookConnection(bodyTemplate: #"{"text":"${missing}"}"#, writeEnabled: true),
                    roomId: "alerts/prod",
                    content: "Ship it",
                    confirmSend: true
                )
            }
        }
    }

    @Test func responseCapsAndHTTPErrorMappingDoNotLeakSecrets() async throws {
        try await Self.withIsolatedAgentChannelConfiguration(
            connection: Self.webhookConnection(writeEnabled: true)
        ) {
            let secret = "custom-channel-secret-token"
            let errorRunner = AgentChannelCustomHTTPRunner(
                session: CustomHTTPStubProtocol.session { _ in
                    (500, Data(#"{"error":"custom-channel-secret-token failed"}"#.utf8), [:])
                },
                secretResolver: StaticCustomHTTPSecretResolver(secrets: ["bearer": secret])
            )

            await #expect(throws: AgentChannelCustomHTTPRunnerError.httpError(
                status: 500,
                body: #"{"error":"[REDACTED:AGENT_CHANNEL_SECRET] failed"}"#
            )) {
                try await errorRunner.sendMessage(
                    connection: Self.webhookConnection(writeEnabled: true),
                    roomId: "alerts/prod",
                    content: "Ship it",
                    confirmSend: true
                )
            }

            let capRunner = AgentChannelCustomHTTPRunner(
                session: CustomHTTPStubProtocol.session { _ in
                    (200, Data(repeating: 65, count: 512 * 1024 + 1), [:])
                },
                secretResolver: StaticCustomHTTPSecretResolver(secrets: ["bearer": secret])
            )

            await #expect(throws: AgentChannelCustomHTTPRunnerError.responseTooLarge(512 * 1024 + 1)) {
                try await capRunner.sendMessage(
                    connection: Self.webhookConnection(writeEnabled: true),
                    roomId: "alerts/prod",
                    content: "Ship it",
                    confirmSend: true
                )
            }
        }
    }

    @Test func agentChannelToolRoutesCustomHTTPFailuresAsStructuredEnvelopes() async throws {
        try await Self.withIsolatedAgentChannelConfiguration(
            connection: Self.webhookConnection(writeEnabled: true)
        ) {
            let runner = AgentChannelCustomHTTPRunner(
                session: CustomHTTPStubProtocol.session { _ in
                    Issue.record("Missing confirmation must not execute HTTP")
                    return (200, Data(), [:])
                },
                secretResolver: StaticCustomHTTPSecretResolver(secrets: ["bearer": "custom-channel-secret-token"])
            )
            let service = AgentChannelConnectionService(
                discordService: DiscordConnectionService(
                    client: FakeAgentChannelDiscordAPIClient(),
                    credentialStore: InMemoryAgentChannelDiscordCredentials()
                ),
                customHTTPRunner: runner
            )
            let tool = AgentChannelSendMessageTool(service: service)

            let envelope = try await tool.execute(
                argumentsJSON:
                    #"{"connection_id":"ops-webhook","room_id":"alerts/prod","content":"Ship it","confirm_send":false}"#
            )

            #expect(envelope.contains(#""ok":false"#))
            #expect(envelope.contains(#""kind":"rejected""#))
            #expect(envelope.contains("confirm_send"))
            #expect(await CustomHTTPStubProtocol.requestCount() == 0)
        }
    }

    private static func webhookConnection(
        baseURL: String = "https://hooks.example.test/api",
        method: String = "POST",
        headerValue: String = "Bearer ${secret:bearer}",
        bodyTemplate: String = #"{"text":"${content}"}"#,
        writeEnabled: Bool = true
    ) -> AgentChannelConnection {
        AgentChannelConnection(
            id: "ops-webhook",
            name: "Ops Webhook",
            kind: .customHTTP,
            supportedActions: [.diagnostics, .draftMessage, .sendMessage],
            writeRoomAllowlist: ["alerts/prod"],
            writeEnabled: writeEnabled,
            secrets: [
                AgentChannelSecretReference(name: "bearer", keychainId: "ops_webhook_token"),
            ],
            customHTTP: AgentChannelCustomHTTPConfiguration(
                baseURL: baseURL,
                actions: [
                    "send_message": AgentChannelCustomHTTPAction(
                        method: method,
                        path: "/rooms/{room_id}/messages",
                        query: ["thread": "incident-42"],
                        headers: ["Authorization": headerValue],
                        bodyTemplate: bodyTemplate,
                        responseMapping: AgentChannelCustomHTTPResponseMapping(
                            idPath: "id",
                            contentPath: "content"
                        )
                    ),
                ]
            )
        )
    }

    private static func withIsolatedAgentChannelConfiguration(
        connection: AgentChannelConnection?,
        body: @Sendable () async throws -> Void
    ) async throws {
        try await StoragePathsTestLock.shared.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-agent-channel-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let previousDirectory = AgentChannelConfigurationStore.overrideDirectory
            AgentChannelConfigurationStore.overrideDirectory = directory
            defer {
                AgentChannelConfigurationStore.overrideDirectory = previousDirectory
                try? FileManager.default.removeItem(at: directory)
            }
            if let connection {
                try AgentChannelConfigurationStore.save(AgentChannelConfiguration(connections: [connection]))
            }
            try await body()
        }
    }
}

private struct StaticCustomHTTPSecretResolver: AgentChannelCustomHTTPSecretResolving {
    let secrets: [String: String]

    func secret(named name: String, for _: AgentChannelConnection) -> String? {
        secrets[name]
    }
}

private final class CustomHTTPStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) throws -> (Int, Data, [String: String]))?
    nonisolated(unsafe) private static var requests = [URLRequest]()

    static func session(
        handler: @escaping @Sendable (URLRequest) throws -> (Int, Data, [String: String])
    ) -> URLSession {
        self.handler = handler
        requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CustomHTTPStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func requestCount() async -> Int {
        requests.count
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            Self.requests.append(request)
            let (status, data, headers) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension URLRequest {
    var httpBodyStreamData: Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class FakeAgentChannelDiscordAPIClient: DiscordAPIClientProtocol, @unchecked Sendable {
    func currentUser(token _: String) async throws -> DiscordBotIdentity {
        DiscordBotIdentity(id: "bot", username: "osaurus", globalName: "Osaurus", bot: true)
    }

    func guild(id: String, token _: String) async throws -> DiscordGuild {
        DiscordGuild(id: id, name: "Test")
    }

    func channels(guildId _: String, token _: String) async throws -> [DiscordChannel] {
        []
    }

    func messages(channelId _: String, token _: String, limit _: Int) async throws -> [DiscordMessage] {
        []
    }

    func sendMessage(channelId _: String, content _: String, token _: String) async throws -> DiscordMessage {
        DiscordMessage(
            id: "sent",
            channelId: "channel",
            content: "sent",
            timestamp: "2026-06-19T20:00:00.000000+00:00",
            author: DiscordMessageAuthor(id: "bot", username: "osaurus", globalName: "Osaurus", bot: true),
            attachments: []
        )
    }
}

private final class InMemoryAgentChannelDiscordCredentials: DiscordCredentialStorage, @unchecked Sendable {
    private var token: String?

    func saveBotToken(_ token: String) -> Bool {
        self.token = token
        return true
    }

    func botToken() -> String? {
        token
    }

    func hasBotToken() -> Bool {
        token != nil
    }

    func deleteBotToken() -> Bool {
        token = nil
        return true
    }
}
