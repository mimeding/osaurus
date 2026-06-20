//
//  DiscordTools.swift
//  osaurus
//
//  First-party Discord read/write tools.
//

import Foundation

private enum DiscordToolPolicy {
    static let readRequirements = ["network", "discord.read"]
    static let writeRequirements = ["network", "discord.write"]
    static let defaultPolicy: ToolPermissionPolicy = .ask
}

private protocol DiscordServiceTool {
    var service: DiscordConnectionService { get }
}

private extension OsaurusTool {
    func discordFailure(_ error: Error, tool: String) -> String {
        if let error = error as? DiscordConnectionServiceError {
            switch error {
            case .invalidId, .sendConfirmationRequired, .messageTooLong, .emptyMessage:
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: error.localizedDescription,
                    tool: tool
                )
            case .guildNotConfigured, .channelNotReadable, .channelNotWritable, .writeDisabled:
                return ToolEnvelope.failure(
                    kind: .rejected,
                    message: error.localizedDescription,
                    tool: tool
                )
            case .notConfigured:
                return ToolEnvelope.failure(
                    kind: .unavailable,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: false
                )
            case .configurationSaveFailed, .api:
                return ToolEnvelope.failure(
                    kind: .executionError,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: false
                )
            }
        }

        if let error = error as? DiscordAPIError {
            switch error {
            case .invalidToken:
                return ToolEnvelope.failure(
                    kind: .unavailable,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: false
                )
            case .missingPermissions:
                return ToolEnvelope.failure(
                    kind: .rejected,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: false
                )
            case .notFound:
                return ToolEnvelope.failure(
                    kind: .notFound,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: false
                )
            case .rateLimited:
                return ToolEnvelope.failure(
                    kind: .unavailable,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: true
                )
            case .invalidResponse, .requestFailed:
                return ToolEnvelope.failure(
                    kind: .executionError,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: false
                )
            }
        }

        return ToolEnvelope.failure(
            kind: .executionError,
            message: error.localizedDescription,
            tool: tool,
            retryable: false
        )
    }
}

final class DiscordDiagnosticsTool: OsaurusTool, PermissionedTool, DiscordServiceTool, @unchecked Sendable {
    let name = "discord_diagnostics"
    let description =
        "Check the native Discord connection without exposing secrets. Returns token presence, bot identity, "
        + "configured server/channel allowlists, write state, and permission failures."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([:]),
    ])

    let service: DiscordConnectionService
    var requirements: [String] { DiscordToolPolicy.readRequirements }
    var defaultPermissionPolicy: ToolPermissionPolicy { DiscordToolPolicy.defaultPolicy }

    init(service: DiscordConnectionService = .shared) {
        self.service = service
    }

    func execute(argumentsJSON: String) async throws -> String {
        let diagnostics = await service.diagnostics()
        return ToolEnvelope.success(tool: name, result: diagnostics.dictionary)
    }
}

final class DiscordListServersTool: OsaurusTool, PermissionedTool, DiscordServiceTool, @unchecked Sendable {
    let name = "discord_list_servers"
    let description =
        "List Discord servers configured in Osaurus and validate whether the saved bot token can access them."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([:]),
    ])

    let service: DiscordConnectionService
    var requirements: [String] { DiscordToolPolicy.readRequirements }
    var defaultPermissionPolicy: ToolPermissionPolicy { DiscordToolPolicy.defaultPolicy }

    init(service: DiscordConnectionService = .shared) {
        self.service = service
    }

    func execute(argumentsJSON: String) async throws -> String {
        do {
            let servers = try await service.listServers()
            return ToolEnvelope.success(tool: name, result: ["servers": servers])
        } catch {
            return discordFailure(error, tool: name)
        }
    }
}

final class DiscordListChannelsTool: OsaurusTool, PermissionedTool, DiscordServiceTool, @unchecked Sendable {
    let name = "discord_list_channels"
    let description =
        "List channels in a configured Discord server. Shows which channels are allowlisted for read/write."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "guild_id": .object([
                "type": .string("string"),
                "description": .string("Numeric Discord server ID configured in Osaurus settings."),
            ])
        ]),
        "required": .array([.string("guild_id")]),
    ])

    let service: DiscordConnectionService
    var requirements: [String] { DiscordToolPolicy.readRequirements }
    var defaultPermissionPolicy: ToolPermissionPolicy { DiscordToolPolicy.defaultPolicy }

    init(service: DiscordConnectionService = .shared) {
        self.service = service
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let guildReq = requireString(args, "guild_id", expected: "numeric Discord server ID", tool: name)
        guard case .value(let guildId) = guildReq else { return guildReq.failureEnvelope ?? "" }

        do {
            let channels = try await service.listChannels(guildId: guildId)
            return ToolEnvelope.success(tool: name, result: ["guild_id": guildId, "channels": channels])
        } catch {
            return discordFailure(error, tool: name)
        }
    }
}

final class DiscordReadChannelTool: OsaurusTool, PermissionedTool, DiscordServiceTool, @unchecked Sendable {
    let name = "discord_read_channel"
    let description =
        "Read recent messages from a Discord channel that the user has allowlisted for read access. "
        + "This is a bounded recent-message fetch, not global Discord search."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "channel_id": .object([
                "type": .string("string"),
                "description": .string("Numeric Discord channel ID allowlisted for read access."),
            ]),
            "limit": .object([
                "type": .string("integer"),
                "description": .string("Number of recent messages to read, 1-100."),
            ]),
        ]),
        "required": .array([.string("channel_id")]),
    ])

    let service: DiscordConnectionService
    var requirements: [String] { DiscordToolPolicy.readRequirements }
    var defaultPermissionPolicy: ToolPermissionPolicy { DiscordToolPolicy.defaultPolicy }

    init(service: DiscordConnectionService = .shared) {
        self.service = service
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let channelReq = requireString(args, "channel_id", expected: "numeric Discord channel ID", tool: name)
        guard case .value(let channelId) = channelReq else { return channelReq.failureEnvelope ?? "" }
        let limit = coerceInt(args["limit"])

        do {
            return ToolEnvelope.success(
                tool: name,
                result: try await service.readChannel(channelId: channelId, limit: limit)
            )
        } catch {
            return discordFailure(error, tool: name)
        }
    }
}

final class DiscordReadThreadTool: OsaurusTool, PermissionedTool, DiscordServiceTool, @unchecked Sendable {
    let name = "discord_read_thread"
    let description =
        "Read recent messages from a Discord thread ID allowlisted for read access. "
        + "This is bounded to recent thread history."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "thread_id": .object([
                "type": .string("string"),
                "description": .string("Numeric Discord thread ID allowlisted for read access."),
            ]),
            "limit": .object([
                "type": .string("integer"),
                "description": .string("Number of recent messages to read, 1-100."),
            ]),
        ]),
        "required": .array([.string("thread_id")]),
    ])

    let service: DiscordConnectionService
    var requirements: [String] { DiscordToolPolicy.readRequirements }
    var defaultPermissionPolicy: ToolPermissionPolicy { DiscordToolPolicy.defaultPolicy }

    init(service: DiscordConnectionService = .shared) {
        self.service = service
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let threadReq = requireString(args, "thread_id", expected: "numeric Discord thread ID", tool: name)
        guard case .value(let threadId) = threadReq else { return threadReq.failureEnvelope ?? "" }
        let limit = coerceInt(args["limit"])

        do {
            return ToolEnvelope.success(
                tool: name,
                result: try await service.readThread(threadId: threadId, limit: limit)
            )
        } catch {
            return discordFailure(error, tool: name)
        }
    }
}

final class DiscordFindRecentMessagesTool: OsaurusTool, PermissionedTool, DiscordServiceTool, @unchecked Sendable {
    let name = "discord_find_recent_messages"
    let description =
        "Scan recent messages in configured Discord channels for a query. This is a bounded recent-message scan "
        + "over allowlisted channels, not Discord's full UI search."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "query": .object([
                "type": .string("string"),
                "description": .string("Text to match in recent messages."),
            ]),
            "channel_ids": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("Optional allowlisted Discord channel IDs. Defaults to all readable channels."),
            ]),
            "limit_per_channel": .object([
                "type": .string("integer"),
                "description": .string("Recent messages to scan per channel, 1-100."),
            ]),
            "max_matches": .object([
                "type": .string("integer"),
                "description": .string("Maximum matches to return, 1-50."),
            ]),
        ]),
        "required": .array([.string("query")]),
    ])

    let service: DiscordConnectionService
    var requirements: [String] { DiscordToolPolicy.readRequirements }
    var defaultPermissionPolicy: ToolPermissionPolicy { DiscordToolPolicy.defaultPolicy }

    init(service: DiscordConnectionService = .shared) {
        self.service = service
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let queryReq = requireString(args, "query", expected: "search text", tool: name)
        guard case .value(let query) = queryReq else { return queryReq.failureEnvelope ?? "" }
        let channelIds = coerceStringArray(args["channel_ids"])
        let limitPerChannel = coerceInt(args["limit_per_channel"])
        let maxMatches = coerceInt(args["max_matches"])

        do {
            return ToolEnvelope.success(
                tool: name,
                result: try await service.findRecentMessages(
                    query: query,
                    channelIds: channelIds,
                    limitPerChannel: limitPerChannel,
                    maxMatches: maxMatches
                )
            )
        } catch {
            return discordFailure(error, tool: name)
        }
    }
}

final class DiscordDraftMessageTool: OsaurusTool, PermissionedTool, DiscordServiceTool, @unchecked Sendable {
    let name = "discord_draft_message"
    let description =
        "Prepare a Discord message for a write-allowlisted channel without sending it. "
        + "Use before discord_send_message so the user can inspect the exact destination and body."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "channel_id": .object([
                "type": .string("string"),
                "description": .string("Numeric Discord channel ID allowlisted for write access."),
            ]),
            "content": .object([
                "type": .string("string"),
                "description": .string("Message body to draft, 1-2000 characters."),
            ]),
        ]),
        "required": .array([.string("channel_id"), .string("content")]),
    ])

    let service: DiscordConnectionService
    var requirements: [String] { DiscordToolPolicy.writeRequirements }
    var defaultPermissionPolicy: ToolPermissionPolicy { DiscordToolPolicy.defaultPolicy }

    init(service: DiscordConnectionService = .shared) {
        self.service = service
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let channelReq = requireString(args, "channel_id", expected: "numeric Discord channel ID", tool: name)
        guard case .value(let channelId) = channelReq else { return channelReq.failureEnvelope ?? "" }
        let contentReq = requireString(args, "content", expected: "Discord message body", tool: name)
        guard case .value(let content) = contentReq else { return contentReq.failureEnvelope ?? "" }

        do {
            return ToolEnvelope.success(tool: name, result: try service.draftMessage(channelId: channelId, content: content))
        } catch {
            return discordFailure(error, tool: name)
        }
    }
}

final class DiscordSendMessageTool: OsaurusTool, PermissionedTool, DiscordServiceTool, @unchecked Sendable {
    let name = "discord_send_message"
    let description =
        "Send a message to a write-allowlisted Discord channel. Requires `confirm_send: true`; "
        + "the user must approve the tool call before any message is posted."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "channel_id": .object([
                "type": .string("string"),
                "description": .string("Numeric Discord channel ID allowlisted for write access."),
            ]),
            "content": .object([
                "type": .string("string"),
                "description": .string("Message body to send, 1-2000 characters."),
            ]),
            "confirm_send": .object([
                "type": .string("boolean"),
                "description": .string("Must be true to send. False or omitted only drafts/refuses."),
            ]),
        ]),
        "required": .array([.string("channel_id"), .string("content"), .string("confirm_send")]),
    ])

    let service: DiscordConnectionService
    var requirements: [String] { DiscordToolPolicy.writeRequirements }
    var defaultPermissionPolicy: ToolPermissionPolicy { DiscordToolPolicy.defaultPolicy }

    init(service: DiscordConnectionService = .shared) {
        self.service = service
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let channelReq = requireString(args, "channel_id", expected: "numeric Discord channel ID", tool: name)
        guard case .value(let channelId) = channelReq else { return channelReq.failureEnvelope ?? "" }
        let contentReq = requireString(args, "content", expected: "Discord message body", tool: name)
        guard case .value(let content) = contentReq else { return contentReq.failureEnvelope ?? "" }
        let confirmSend = coerceBool(args["confirm_send"]) ?? false

        do {
            return ToolEnvelope.success(
                tool: name,
                result: try await service.sendMessage(
                    channelId: channelId,
                    content: content,
                    confirmSend: confirmSend
                )
            )
        } catch {
            return discordFailure(error, tool: name)
        }
    }
}

final class DiscordReplyToThreadTool: OsaurusTool, PermissionedTool, DiscordServiceTool, @unchecked Sendable {
    let name = "discord_reply_to_thread"
    let description =
        "Reply in a write-allowlisted Discord thread. Requires `confirm_send: true`; "
        + "the user must approve the tool call before any reply is posted."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "thread_id": .object([
                "type": .string("string"),
                "description": .string("Numeric Discord thread ID allowlisted for write access."),
            ]),
            "content": .object([
                "type": .string("string"),
                "description": .string("Reply body to send, 1-2000 characters."),
            ]),
            "confirm_send": .object([
                "type": .string("boolean"),
                "description": .string("Must be true to send. False or omitted refuses."),
            ]),
        ]),
        "required": .array([.string("thread_id"), .string("content"), .string("confirm_send")]),
    ])

    let service: DiscordConnectionService
    var requirements: [String] { DiscordToolPolicy.writeRequirements }
    var defaultPermissionPolicy: ToolPermissionPolicy { DiscordToolPolicy.defaultPolicy }

    init(service: DiscordConnectionService = .shared) {
        self.service = service
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let threadReq = requireString(args, "thread_id", expected: "numeric Discord thread ID", tool: name)
        guard case .value(let threadId) = threadReq else { return threadReq.failureEnvelope ?? "" }
        let contentReq = requireString(args, "content", expected: "Discord reply body", tool: name)
        guard case .value(let content) = contentReq else { return contentReq.failureEnvelope ?? "" }
        let confirmSend = coerceBool(args["confirm_send"]) ?? false

        do {
            return ToolEnvelope.success(
                tool: name,
                result: try await service.replyToThread(
                    threadId: threadId,
                    content: content,
                    confirmSend: confirmSend
                )
            )
        } catch {
            return discordFailure(error, tool: name)
        }
    }
}
