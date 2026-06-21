//
//  DiscordConnectionTests.swift
//  osaurusTests
//
//  Unit and security coverage for the native Discord connection.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct DiscordConnectionTests {

    @Test func configurationPersistsAllowlistsButNeverBotToken() async throws {
        try await withIsolatedDiscordStores {
            let token = "discord-bot-token-super-secret"
            try DiscordConnectionService(client: FakeDiscordAPIClient()).saveBotToken(token)
            let configuration = DiscordConnectionConfiguration(
                configuredGuildIds: [" 111111111111111111 ", "111111111111111111"],
                readableChannelIds: ["222222222222222222"],
                writableChannelIds: ["333333333333333333"],
                writeEnabled: true,
                defaultReadLimit: 250
            )
            try DiscordConnectionService(client: FakeDiscordAPIClient()).saveConfiguration(configuration)

            let saved = DiscordConnectionConfigurationStore.load()
            #expect(saved.configuredGuildIds == ["111111111111111111"])
            #expect(saved.defaultReadLimit == 100)
            #expect(!DiscordConnectionConfiguration.isValidSnowflake("١١١١١١"))

            let disk = try String(
                contentsOf: DiscordConnectionConfigurationStore.configurationFileURL(),
                encoding: .utf8
            )
            #expect(disk.contains("222222222222222222"))
            #expect(!disk.contains(token))
            #expect(!disk.localizedCaseInsensitiveContains("bot_token"))
        }
    }

    @Test func diagnosticsRedactsTokenEchoedByTransportError() async throws {
        try await withIsolatedDiscordStores {
            let token = "discord-bot-token-super-secret"
            let fake = FakeDiscordAPIClient()
            await fake.setCurrentUserFailureEchoingToken()
            let service = DiscordConnectionService(client: fake)
            try service.saveBotToken(token)
            try service.saveConfiguration(
                DiscordConnectionConfiguration(configuredGuildIds: ["111111111111111111"])
            )

            let diagnostics = await service.diagnostics()
            #expect(diagnostics.tokenSaved)
            #expect(diagnostics.status == "token_invalid_or_unavailable")
            #expect(diagnostics.failures.joined(separator: " ").contains("[REDACTED:DISCORD_BOT_TOKEN]"))
            #expect(!diagnostics.failures.joined(separator: " ").contains(token))
            #expect(!String(describing: diagnostics.dictionary).contains(token))
        }
    }

    @Test func apiClientRedactsTokenEchoedByDiscordErrorBody() async throws {
        let token = "discord-bot-token-super-secret"
        let session = DiscordHTTPStubProtocol.session(
            statusCode: 403,
            body: #"{"message":"Discord echoed \#(token)"}"#
        )
        let client = DiscordAPIClient(
            baseURL: URL(string: "https://discord.test/api/v10")!,
            sessionProvider: { session }
        )

        do {
            let _: [DiscordMessage] = try await client.messages(
                channelId: "222222222222222222",
                token: token,
                limit: 1
            )
            Issue.record("Discord request should have failed")
        } catch let error as DiscordAPIError {
            #expect(error.localizedDescription.contains("[REDACTED:DISCORD_BOT_TOKEN]"))
            #expect(!error.localizedDescription.contains(token))
        }
    }

    @Test func readChannelReturnsBoundedMessagesForAllowlistedChannel() async throws {
        try await withIsolatedDiscordStores {
            let fake = FakeDiscordAPIClient()
            await fake.setMessages([
                "222222222222222222": [
                    .fixture(id: "9001", channelId: "222222222222222222", content: "eval reports landed"),
                    .fixture(id: "9002", channelId: "222222222222222222", content: "review requested"),
                ],
            ])
            let service = DiscordConnectionService(client: fake)
            try service.saveBotToken("discord-bot-token-super-secret")
            try service.saveConfiguration(
                DiscordConnectionConfiguration(
                    configuredGuildIds: ["111111111111111111"],
                    readableChannelIds: ["222222222222222222"],
                    defaultReadLimit: 2
                )
            )

            let result = try await service.readChannel(channelId: "222222222222222222", limit: nil)
            #expect(result["channel_id"] as? String == "222222222222222222")
            #expect(result["partial"] as? Bool == true)
            let messages = try #require(result["messages"] as? [[String: Any]])
            #expect(messages.count == 2)
            #expect(messages.first?["content"] as? String == "eval reports landed")
        }
    }

    @Test func readToolRejectsChannelsOutsideReadAllowlist() async throws {
        try await withIsolatedDiscordStores {
            let service = DiscordConnectionService(client: FakeDiscordAPIClient())
            try service.saveBotToken("discord-bot-token-super-secret")
            try service.saveConfiguration(
                DiscordConnectionConfiguration(readableChannelIds: ["222222222222222222"])
            )
            let tool = DiscordReadChannelTool(service: service)

            let result = try await tool.execute(
                argumentsJSON: #"{"channel_id":"333333333333333333"}"#
            )
            #expect(EnvelopeAssertions.failureKind(result) == "rejected")
            #expect(EnvelopeAssertions.failureMessage(result)?.contains("not allowlisted") == true)
        }
    }

    @Test func sendToolRequiresConfirmSendEvenWhenWriteAllowlisted() async throws {
        try await withIsolatedDiscordStores {
            let fake = FakeDiscordAPIClient()
            let service = DiscordConnectionService(client: fake)
            try service.saveBotToken("discord-bot-token-super-secret")
            try service.saveConfiguration(
                DiscordConnectionConfiguration(
                    writableChannelIds: ["333333333333333333"],
                    writeEnabled: true
                )
            )
            let tool = DiscordSendMessageTool(service: service)

            let result = try await tool.execute(
                argumentsJSON: #"{"channel_id":"333333333333333333","content":"Ship it","confirm_send":false}"#
            )
            #expect(EnvelopeAssertions.failureKind(result) == "invalid_args")
            #expect(await fake.sentMessageCount() == 0)
        }
    }

    @Test func sendToolPostsOnlyWhenWriteEnabledAllowlistedAndConfirmed() async throws {
        try await withIsolatedDiscordStores {
            let fake = FakeDiscordAPIClient()
            let service = DiscordConnectionService(client: fake)
            try service.saveBotToken("discord-bot-token-super-secret")
            try service.saveConfiguration(
                DiscordConnectionConfiguration(
                    writableChannelIds: ["333333333333333333"],
                    writeEnabled: true
                )
            )
            let tool = DiscordSendMessageTool(service: service)

            let result = try await tool.execute(
                argumentsJSON: #"{"channel_id":"333333333333333333","content":"Ship it","confirm_send":true}"#
            )
            let payload = try #require(EnvelopeAssertions.successPayload(result))
            #expect(payload["kind"] as? String == "discord_message_sent")
            #expect(await fake.sentMessageCount() == 1)
            #expect(await fake.lastSentContent() == "Ship it")
        }
    }

    @Test func sendToolRejectsMessagesAboveDiscordUTF16Limit() async throws {
        try await withIsolatedDiscordStores {
            let fake = FakeDiscordAPIClient()
            let service = DiscordConnectionService(client: fake)
            try service.saveBotToken("discord-bot-token-super-secret")
            try service.saveConfiguration(
                DiscordConnectionConfiguration(
                    writableChannelIds: ["333333333333333333"],
                    writeEnabled: true
                )
            )
            let tool = DiscordSendMessageTool(service: service)
            let emojiMessage = String(repeating: "😀", count: 1001)

            let result = try await tool.execute(
                argumentsJSON: #"{"channel_id":"333333333333333333","content":"\#(emojiMessage)","confirm_send":true}"#
            )

            #expect(EnvelopeAssertions.failureKind(result) == "invalid_args")
            #expect(await fake.sentMessageCount() == 0)
        }
    }

    @Test func agentChannelSendToolDispatchesThroughDiscordConnection() async throws {
        try await withIsolatedDiscordStores {
            let fake = FakeDiscordAPIClient()
            let discordService = DiscordConnectionService(client: fake)
            try discordService.saveBotToken("discord-bot-token-super-secret")
            try discordService.saveConfiguration(
                DiscordConnectionConfiguration(
                    writableChannelIds: ["333333333333333333"],
                    writeEnabled: true
                )
            )
            let channelService = AgentChannelConnectionService(discordService: discordService)
            let tool = AgentChannelSendMessageTool(service: channelService)

            let result = try await tool.execute(
                argumentsJSON:
                    #"{"connection_id":"discord","room_id":"333333333333333333","content":"Ship it","confirm_send":true}"#
            )
            let payload = try #require(EnvelopeAssertions.successPayload(result))
            #expect(payload["connection_id"] as? String == "discord")
            #expect(payload["standard_kind"] as? String == "message_sent")
            #expect(payload["kind"] as? String == "discord_message_sent")
            #expect(await fake.sentMessageCount() == 1)
        }
    }

    @Test func customAgentChannelCanBeDefinedWithPureJSON() async throws {
        try await withIsolatedDiscordStores {
            let json = """
            {
              "schemaVersion": 1,
              "connections": [
                {
                  "id": "ops-webhook",
                  "name": "Ops Webhook",
                  "kind": "custom_http",
                  "enabled": true,
                  "supportedActions": ["diagnostics", "send_message"],
                  "spaceAllowlist": ["ops"],
                  "readRoomAllowlist": [],
                  "writeRoomAllowlist": ["alerts"],
                  "writeEnabled": true,
                  "defaultReadLimit": 25,
                  "secrets": [
                    { "name": "bearer", "keychainId": "ops_webhook_token" }
                  ],
                  "customHTTP": {
                    "baseURL": "https://hooks.example.test",
                    "actions": {
                      "send_message": {
                        "method": "POST",
                        "path": "/rooms/{room_id}/messages",
                        "headers": {
                          "Authorization": "Bearer ${secret:bearer}"
                        },
                        "bodyTemplate": "{\\"text\\":\\"${content}\\"}"
                      }
                    }
                  }
                }
              ]
            }
            """
            try FileManager.default.createDirectory(
                at: AgentChannelConfigurationStore.configurationFileURL().deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try json.write(
                to: AgentChannelConfigurationStore.configurationFileURL(),
                atomically: true,
                encoding: .utf8
            )

            let config = AgentChannelConfigurationStore.load()
            let connection = try #require(config.connection(id: "ops-webhook"))
            #expect(connection.kind == .customHTTP)
            #expect(connection.supportedActions == [.diagnostics, .sendMessage])
            #expect(connection.writeRoomAllowlist == ["alerts"])
            #expect(connection.customHTTP?.actions["send_message"]?.method == "POST")

            let service = AgentChannelConnectionService(discordService: DiscordConnectionService(client: FakeDiscordAPIClient()))
            let diagnostics = await service.diagnostics(connectionId: "ops-webhook")
            #expect(diagnostics["status"] as? String == "configured_not_executable")
            #expect(diagnostics["custom_actions"] as? [String] == ["send_message"])
        }
    }

    @Test func findRecentMessagesScansOnlyReadableChannels() async throws {
        try await withIsolatedDiscordStores {
            let fake = FakeDiscordAPIClient()
            await fake.setMessages([
                "222222222222222222": [
                    .fixture(id: "9001", channelId: "222222222222222222", content: "eval reports landed"),
                ],
                "333333333333333333": [
                    .fixture(id: "9002", channelId: "333333333333333333", content: "eval secret"),
                ],
            ])
            let service = DiscordConnectionService(client: fake)
            try service.saveBotToken("discord-bot-token-super-secret")
            try service.saveConfiguration(
                DiscordConnectionConfiguration(readableChannelIds: ["222222222222222222"])
            )

            let result = try await service.findRecentMessages(
                query: "eval",
                channelIds: ["222222222222222222", "333333333333333333"],
                limitPerChannel: 10,
                maxMatches: 10
            )
            let channelIds = try #require(result["searched_channel_ids"] as? [String])
            #expect(channelIds == ["222222222222222222"])
            let messages = try #require(result["messages"] as? [[String: Any]])
            #expect(messages.count == 1)
            #expect(messages.first?["id"] as? String == "9001")
        }
    }

    @Test func nativeAgentChannelToolsAreDynamicButNotPluginOwned() async throws {
        let names = ToolRegistry.agentChannelToolNames.sorted()
        let (builtInNames, pluginNames) = await MainActor.run {
            (
                ToolRegistry.shared.builtInToolNames,
                names.filter { ToolRegistry.shared.isPluginTool($0) }
            )
        }
        #expect(pluginNames.isEmpty)

        for name in names {
            #expect(ToolRegistry.externallyDeniedToolNames.contains(name))
            #expect(!builtInNames.contains(name))
            #expect(!ToolRegistry.isDeniedForCurrentSurface(name))
            let denied = ChatExecutionContext.$isExternalSurface.withValue(true) {
                ToolRegistry.isDeniedForCurrentSurface(name)
            }
            #expect(denied)

            let envelope = ToolRegistry.externalSurfaceDenialEnvelope(tool: name)
            #expect(EnvelopeAssertions.failureKind(envelope) == "rejected")
            #expect(EnvelopeAssertions.failureMessage(envelope)?.contains("Osaurus app") == true)
        }

        for name in ToolRegistry.discordToolNames {
            #expect(ToolRegistry.externallyDeniedToolNames.contains(name))
        }
    }

    @Test func discordChannelIsConfiguredForWriteOnlySetups() async throws {
        try await withIsolatedDiscordStores {
            let service = DiscordConnectionService(client: FakeDiscordAPIClient())
            try service.saveBotToken("discord-bot-token-super-secret")
            try service.saveConfiguration(
                DiscordConnectionConfiguration(
                    writableChannelIds: ["333333333333333333"],
                    writeEnabled: true
                )
            )

            let channelService = AgentChannelConnectionService(discordService: service)
            let discordRow = try #require(
                channelService.listConnections().first { $0["id"] as? String == "discord" }
            )

            #expect(discordRow["configured"] as? Bool == true)
            #expect(discordRow["credential_saved"] as? Bool == true)
        }
    }

    private func withIsolatedDiscordStores(
        _ body: () async throws -> Void
    ) async throws {
        let previousDirectory = DiscordConnectionConfigurationStore.overrideDirectory
        let previousChannelDirectory = AgentChannelConfigurationStore.overrideDirectory
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-discord-tests-\(UUID().uuidString)", isDirectory: true)
        DiscordConnectionConfigurationStore.overrideDirectory = directory
        AgentChannelConfigurationStore.overrideDirectory = directory
        DiscordCredentialStore.deleteBotToken()
        defer {
            DiscordCredentialStore.deleteBotToken()
            DiscordConnectionConfigurationStore.overrideDirectory = previousDirectory
            AgentChannelConfigurationStore.overrideDirectory = previousChannelDirectory
            try? FileManager.default.removeItem(at: directory)
        }
        try await body()
    }
}

private actor FakeDiscordAPIClient: DiscordAPIClientProtocol {
    private var shouldEchoTokenFailure = false
    private var messagesByChannel: [String: [DiscordMessage]] = [:]
    private var sentMessages: [(channelId: String, content: String)] = []

    func setCurrentUserFailureEchoingToken() {
        shouldEchoTokenFailure = true
    }

    func setMessages(_ messagesByChannel: [String: [DiscordMessage]]) {
        self.messagesByChannel = messagesByChannel
    }

    func sentMessageCount() -> Int {
        sentMessages.count
    }

    func lastSentContent() -> String? {
        sentMessages.last?.content
    }

    func currentUser(token: String) async throws -> DiscordBotIdentity {
        if shouldEchoTokenFailure {
            throw DiscordAPIError.requestFailed("transport included token \(token)")
        }
        return DiscordBotIdentity(
            id: "444444444444444444",
            username: "osaurus-bot",
            globalName: "Osaurus",
            bot: true
        )
    }

    func guild(id: String, token: String) async throws -> DiscordGuild {
        DiscordGuild(id: id, name: "Test Guild")
    }

    func channels(guildId: String, token: String) async throws -> [DiscordChannel] {
        [
            DiscordChannel(
                id: "222222222222222222",
                guildId: guildId,
                name: "dev",
                type: 0,
                parentId: nil
            ),
            DiscordChannel(
                id: "333333333333333333",
                guildId: guildId,
                name: "maintainers",
                type: 0,
                parentId: nil
            ),
        ]
    }

    func messages(channelId: String, token: String, limit: Int) async throws -> [DiscordMessage] {
        Array((messagesByChannel[channelId] ?? []).prefix(limit))
    }

    func sendMessage(channelId: String, content: String, token: String) async throws -> DiscordMessage {
        sentMessages.append((channelId: channelId, content: content))
        return .fixture(
            id: "sent-\(sentMessages.count)",
            channelId: channelId,
            content: content,
            author: DiscordMessageAuthor(
                id: "444444444444444444",
                username: "osaurus-bot",
                globalName: "Osaurus",
                bot: true
            )
        )
    }
}

private final class DiscordHTTPStubProtocol: URLProtocol {
    nonisolated(unsafe) private static var statusCode: Int = 200
    nonisolated(unsafe) private static var body = Data()

    static func session(statusCode: Int, body: String) -> URLSession {
        self.statusCode = statusCode
        self.body = Data(body.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiscordHTTPStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension DiscordMessage {
    static func fixture(
        id: String,
        channelId: String,
        content: String,
        author: DiscordMessageAuthor = DiscordMessageAuthor(
            id: "555555555555555555",
            username: "mike",
            globalName: "Mike",
            bot: false
        )
    ) -> DiscordMessage {
        DiscordMessage(
            id: id,
            channelId: channelId,
            content: content,
            timestamp: "2026-06-19T20:00:00.000000+00:00",
            author: author,
            attachments: []
        )
    }
}
