//
//  AgentChannelCustomHTTPRunner.swift
//  osaurus
//
//  Guarded HTTP execution for JSON-backed agent channel definitions.
//

import Foundation

protocol AgentChannelCustomHTTPSecretResolving: Sendable {
    func secret(named name: String, for connection: AgentChannelConnection) -> String?
}

struct KeychainAgentChannelCustomHTTPSecretResolver: AgentChannelCustomHTTPSecretResolving {
    private static let pluginIdPrefix = "osaurus.agent_channel."

    func secret(named name: String, for connection: AgentChannelConnection) -> String? {
        guard let reference = connection.secrets.first(where: { $0.name == name }) else {
            return nil
        }
        return ToolSecretsKeychain.getSecret(
            id: reference.keychainId,
            for: Self.pluginIdPrefix + connection.id,
            agentId: Agent.defaultId
        )
    }
}

enum AgentChannelCustomHTTPRunnerError: LocalizedError, Equatable, Sendable {
    case missingConfiguration(String)
    case missingAction(action: AgentChannelAction, connectionId: String)
    case unsupportedMethod(String)
    case unsafeURL(String)
    case unsafeHeader(String)
    case unsupportedPlaceholder(String)
    case malformedTemplate(String)
    case missingSecret(String)
    case bodyTooLarge(Int)
    case responseTooLarge(Int)
    case writeDisabled(String)
    case writeConfirmationRequired
    case roomNotReadable(String)
    case roomNotWritable(String)
    case requestFailed(String)
    case invalidResponse
    case httpError(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration(let connectionId):
            return "Custom JSON channel `\(connectionId)` is missing custom HTTP configuration."
        case .missingAction(let action, let connectionId):
            return "Custom JSON channel `\(connectionId)` has no HTTP action for `\(action.rawValue)`."
        case .unsupportedMethod(let method):
            return "Custom JSON channel HTTP method `\(method)` is not allowed."
        case .unsafeURL(let url):
            return "Custom JSON channel URL `\(url)` is not allowed."
        case .unsafeHeader(let header):
            return "Custom JSON channel header `\(header)` is not allowed."
        case .unsupportedPlaceholder(let placeholder):
            return "Custom JSON channel template placeholder `\(placeholder)` is not supported."
        case .malformedTemplate(let template):
            return "Custom JSON channel template is malformed near `\(template)`."
        case .missingSecret(let name):
            return "Custom JSON channel secret reference `\(name)` is not available."
        case .bodyTooLarge(let bytes):
            return "Custom JSON channel request body is too large (\(bytes) bytes)."
        case .responseTooLarge(let bytes):
            return "Custom JSON channel response is too large (\(bytes) bytes)."
        case .writeDisabled(let connectionId):
            return "Custom JSON channel `\(connectionId)` has writes disabled."
        case .writeConfirmationRequired:
            return "Custom JSON channel writes require `confirm_send: true`."
        case .roomNotReadable(let roomId):
            return "Custom JSON channel room `\(roomId)` is not read-allowlisted."
        case .roomNotWritable(let roomId):
            return "Custom JSON channel room `\(roomId)` is not write-allowlisted."
        case .requestFailed(let message):
            return "Custom JSON channel request failed: \(message)"
        case .invalidResponse:
            return "Custom JSON channel response was not an HTTP response."
        case .httpError(let status, let body):
            return "Custom JSON channel HTTP \(status): \(body)"
        }
    }
}

final class AgentChannelCustomHTTPRunner: @unchecked Sendable {
    static let shared = AgentChannelCustomHTTPRunner()

    private static let allowedMethods = Set(["GET", "POST", "PUT", "PATCH", "DELETE"])
    private static let bodyLimitBytes = 64 * 1024
    private static let responseLimitBytes = 512 * 1024
    private static let maxDiagnosticBodyCharacters = 1_000
    private static let writeActions: Set<AgentChannelAction> = [.sendMessage, .replyThread]
    private static let previewActions: Set<AgentChannelAction> = [.draftMessage]

    private let session: URLSession
    private let secretResolver: AgentChannelCustomHTTPSecretResolving

    init(
        session: URLSession? = nil,
        secretResolver: AgentChannelCustomHTTPSecretResolving = KeychainAgentChannelCustomHTTPSecretResolver()
    ) {
        self.session = session ?? Self.makeSession()
        self.secretResolver = secretResolver
    }

    func listSpaces(connection: AgentChannelConnection) async throws -> [[String: Any]] {
        let payload = try await execute(connection: connection, actionName: .listSpaces, values: [:])
        return payload["spaces"] as? [[String: Any]] ?? []
    }

    func listRooms(connection: AgentChannelConnection, spaceId: String) async throws -> [[String: Any]] {
        if !connection.spaceAllowlist.isEmpty,
           !connection.spaceAllowlist.contains(normalizedId(spaceId)) {
            throw AgentChannelCustomHTTPRunnerError.roomNotReadable(spaceId)
        }
        let payload = try await execute(
            connection: connection,
            actionName: .listRooms,
            values: ["space_id": spaceId]
        )
        return payload["rooms"] as? [[String: Any]] ?? []
    }

    func readMessages(
        connection: AgentChannelConnection,
        roomId: String,
        limit: Int?
    ) async throws -> [String: Any] {
        let room = try requireReadable(roomId, connection: connection)
        return try await execute(
            connection: connection,
            actionName: .readMessages,
            values: [
                "room_id": room,
                "limit": String(AgentChannelConnection.clampReadLimit(limit ?? connection.defaultReadLimit)),
            ]
        )
    }

    func readThread(
        connection: AgentChannelConnection,
        threadId: String,
        limit: Int?
    ) async throws -> [String: Any] {
        let thread = try requireReadable(threadId, connection: connection)
        return try await execute(
            connection: connection,
            actionName: .readMessages,
            values: [
                "thread_id": thread,
                "limit": String(AgentChannelConnection.clampReadLimit(limit ?? connection.defaultReadLimit)),
            ],
            standardKindOverride: "thread_messages"
        )
    }

    func searchMessages(
        connection: AgentChannelConnection,
        query: String,
        roomIds: [String]?,
        limitPerRoom: Int?,
        maxMatches: Int?
    ) async throws -> [String: Any] {
        let rooms = try (roomIds ?? connection.readRoomAllowlist).map { try requireReadable($0, connection: connection) }
        return try await execute(
            connection: connection,
            actionName: .searchMessages,
            values: [
                "query": query,
                "room_ids": rooms.joined(separator: ","),
                "limit_per_room": String(AgentChannelConnection.clampReadLimit(limitPerRoom ?? connection.defaultReadLimit)),
                "max_matches": String(min(max(maxMatches ?? 50, 1), 50)),
            ]
        )
    }

    func draftMessage(
        connection: AgentChannelConnection,
        roomId: String,
        content: String
    ) throws -> [String: Any] {
        let room = try requireWritable(roomId, connection: connection, requireWriteEnabled: false)
        let action = try configuredAction(connection: connection, actionName: .sendMessage)
        let preview = try buildRequestPreview(
            connection: connection,
            actionName: .sendMessage,
            action: action,
            values: ["room_id": room, "content": try validatedContent(content)]
        )
        return [
            "kind": "custom_http_message_draft",
            "connection_id": connection.id,
            "room_id": room,
            "content": try validatedContent(content),
            "requires_send_confirmation": true,
            "preview": preview,
        ]
    }

    func sendMessage(
        connection: AgentChannelConnection,
        roomId: String,
        content: String,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        let room = try requireWritable(roomId, connection: connection, requireWriteEnabled: true)
        guard confirmSend else {
            throw AgentChannelCustomHTTPRunnerError.writeConfirmationRequired
        }
        return try await execute(
            connection: connection,
            actionName: .sendMessage,
            values: ["room_id": room, "content": try validatedContent(content)]
        )
    }

    func replyThread(
        connection: AgentChannelConnection,
        threadId: String,
        content: String,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        let thread = try requireWritable(threadId, connection: connection, requireWriteEnabled: true)
        guard confirmSend else {
            throw AgentChannelCustomHTTPRunnerError.writeConfirmationRequired
        }
        return try await execute(
            connection: connection,
            actionName: .replyThread,
            values: ["thread_id": thread, "content": try validatedContent(content)]
        )
    }

    private func execute(
        connection: AgentChannelConnection,
        actionName: AgentChannelAction,
        values: [String: String],
        standardKindOverride: String? = nil
    ) async throws -> [String: Any] {
        let action = try configuredAction(connection: connection, actionName: actionName)
        if Self.writeActions.contains(actionName), !connection.writeEnabled {
            throw AgentChannelCustomHTTPRunnerError.writeDisabled(connection.id)
        }
        if Self.previewActions.contains(actionName) {
            throw AgentChannelCustomHTTPRunnerError.missingAction(action: actionName, connectionId: connection.id)
        }

        var request = try buildRequest(connection: connection, actionName: actionName, action: action, values: values)
        request.timeoutInterval = 15
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AgentChannelCustomHTTPRunnerError.invalidResponse
            }
            guard data.count <= Self.responseLimitBytes else {
                throw AgentChannelCustomHTTPRunnerError.responseTooLarge(data.count)
            }
            let secrets = resolvedSecrets(connection: connection, action: action, values: values)
            let redacted = redactedPayload(from: data, secrets: secrets)
            guard (200 ... 299).contains(httpResponse.statusCode) else {
                throw AgentChannelCustomHTTPRunnerError.httpError(
                    status: httpResponse.statusCode,
                    body: diagnosticString(from: redacted)
                )
            }
            return standardPayload(
                connection: connection,
                actionName: actionName,
                action: action,
                values: values,
                statusCode: httpResponse.statusCode,
                redactedResponse: redacted,
                standardKindOverride: standardKindOverride
            )
        } catch let error as AgentChannelCustomHTTPRunnerError {
            throw error
        } catch {
            throw AgentChannelCustomHTTPRunnerError.requestFailed(error.localizedDescription)
        }
    }

    private func configuredAction(
        connection: AgentChannelConnection,
        actionName: AgentChannelAction
    ) throws -> AgentChannelCustomHTTPAction {
        guard let customHTTP = connection.customHTTP else {
            throw AgentChannelCustomHTTPRunnerError.missingConfiguration(connection.id)
        }
        guard let action = customHTTP.actions[actionName.rawValue] else {
            throw AgentChannelCustomHTTPRunnerError.missingAction(
                action: actionName,
                connectionId: connection.id
            )
        }
        return action
    }

    private func buildRequest(
        connection: AgentChannelConnection,
        actionName: AgentChannelAction,
        action: AgentChannelCustomHTTPAction,
        values: [String: String]
    ) throws -> URLRequest {
        let url = try renderedURL(connection: connection, actionName: actionName, action: action, values: values)
        var request = URLRequest(url: url)
        let method = action.method.uppercased()
        guard Self.allowedMethods.contains(method) else {
            throw AgentChannelCustomHTTPRunnerError.unsupportedMethod(method)
        }
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        for (name, template) in action.headers.sorted(by: { $0.key < $1.key }) {
            try validateHeaderName(name)
            let value = try render(template: template, connection: connection, action: action, values: values, mode: .text)
            guard !value.containsLineBreak else {
                throw AgentChannelCustomHTTPRunnerError.unsafeHeader(name)
            }
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let bodyTemplate = action.bodyTemplate {
            let body = try render(template: bodyTemplate, connection: connection, action: action, values: values, mode: .jsonString)
            guard let data = body.data(using: .utf8) else {
                throw AgentChannelCustomHTTPRunnerError.malformedTemplate("bodyTemplate")
            }
            guard data.count <= Self.bodyLimitBytes else {
                throw AgentChannelCustomHTTPRunnerError.bodyTooLarge(data.count)
            }
            request.httpBody = data
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        return request
    }

    private func buildRequestPreview(
        connection: AgentChannelConnection,
        actionName: AgentChannelAction,
        action: AgentChannelCustomHTTPAction,
        values: [String: String]
    ) throws -> [String: Any] {
        let request = try buildRequest(connection: connection, actionName: actionName, action: action, values: values)
        let secrets = resolvedSecrets(connection: connection, action: action, values: values)
        return [
            "method": request.httpMethod ?? "GET",
            "url": request.url?.absoluteString ?? "",
            "headers": redactedDictionary(request.allHTTPHeaderFields ?? [:], secrets: secrets),
            "body": redactedString(
                String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "",
                secrets: secrets
            ),
            "dry_run": true,
        ]
    }

    private func renderedURL(
        connection: AgentChannelConnection,
        actionName: AgentChannelAction,
        action: AgentChannelCustomHTTPAction,
        values: [String: String]
    ) throws -> URL {
        guard let customHTTP = connection.customHTTP,
              let baseComponents = URLComponents(string: customHTTP.baseURL),
              let scheme = baseComponents.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = baseComponents.host,
              !host.isEmpty,
              baseComponents.user == nil,
              baseComponents.password == nil,
              baseComponents.query == nil,
              baseComponents.fragment == nil
        else {
            throw AgentChannelCustomHTTPRunnerError.unsafeURL(connection.customHTTP?.baseURL ?? "")
        }
        try validateSafeHost(host, original: customHTTP.baseURL)
        try validateActionPath(action.path)

        var components = baseComponents
        let rawPath = composePath(baseComponents.path, action.path)
        components.percentEncodedPath = try renderPath(
            rawPath,
            connection: connection,
            action: action,
            values: values
        )
        var queryItems = baseComponents.queryItems ?? []
        for (name, template) in action.query.sorted(by: { $0.key < $1.key }) {
            guard !name.containsLineBreak else {
                throw AgentChannelCustomHTTPRunnerError.unsafeHeader(name)
            }
            let value = try render(template: template, connection: connection, action: action, values: values, mode: .text)
            guard !value.containsLineBreak else {
                throw AgentChannelCustomHTTPRunnerError.unsafeHeader(name)
            }
            queryItems.append(URLQueryItem(name: name, value: value))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw AgentChannelCustomHTTPRunnerError.unsafeURL(customHTTP.baseURL + action.path)
        }
        try validateSafeHost(url.host ?? "", original: url.absoluteString)
        return url
    }

    private func renderPath(
        _ path: String,
        connection: AgentChannelConnection,
        action: AgentChannelCustomHTTPAction,
        values: [String: String]
    ) throws -> String {
        try replaceBracedPlaceholders(in: path) { placeholder in
            if placeholder.hasPrefix("secret:") {
                throw AgentChannelCustomHTTPRunnerError.unsupportedPlaceholder(placeholder)
            }
            guard let value = values[placeholder] else {
                throw AgentChannelCustomHTTPRunnerError.unsupportedPlaceholder(placeholder)
            }
            return percentEncodePathSegment(value)
        }
    }

    private func render(
        template: String,
        connection: AgentChannelConnection,
        action: AgentChannelCustomHTTPAction,
        values: [String: String],
        mode: TemplateRenderMode
    ) throws -> String {
        try replaceDollarPlaceholders(in: template) { placeholder in
            if let name = placeholder.secretName {
                guard let secret = secretResolver.secret(named: name, for: connection) else {
                    throw AgentChannelCustomHTTPRunnerError.missingSecret(name)
                }
                return mode.render(secret)
            }
            guard let value = values[placeholder] else {
                throw AgentChannelCustomHTTPRunnerError.unsupportedPlaceholder(placeholder)
            }
            return mode.render(value)
        }
    }

    private func replaceDollarPlaceholders(
        in template: String,
        replacement: (String) throws -> String
    ) throws -> String {
        var output = ""
        var index = template.startIndex
        while index < template.endIndex {
            guard template[index] == "$",
                  template.index(after: index) < template.endIndex,
                  template[template.index(after: index)] == "{"
            else {
                output.append(template[index])
                index = template.index(after: index)
                continue
            }
            let nameStart = template.index(index, offsetBy: 2)
            guard let close = template[nameStart...].firstIndex(of: "}") else {
                throw AgentChannelCustomHTTPRunnerError.malformedTemplate(String(template[index...].prefix(32)))
            }
            let placeholder = String(template[nameStart..<close])
            guard !placeholder.isEmpty else {
                throw AgentChannelCustomHTTPRunnerError.malformedTemplate("${}")
            }
            output += try replacement(placeholder)
            index = template.index(after: close)
        }
        return output
    }

    private func replaceBracedPlaceholders(
        in template: String,
        replacement: (String) throws -> String
    ) throws -> String {
        var output = ""
        var index = template.startIndex
        while index < template.endIndex {
            guard template[index] == "{" else {
                output.append(template[index])
                index = template.index(after: index)
                continue
            }
            let nameStart = template.index(after: index)
            guard let close = template[nameStart...].firstIndex(of: "}") else {
                throw AgentChannelCustomHTTPRunnerError.malformedTemplate(String(template[index...].prefix(32)))
            }
            let placeholder = String(template[nameStart..<close])
            guard !placeholder.isEmpty else {
                throw AgentChannelCustomHTTPRunnerError.malformedTemplate("{}")
            }
            output += try replacement(placeholder)
            index = template.index(after: close)
        }
        return output
    }

    private func standardPayload(
        connection: AgentChannelConnection,
        actionName: AgentChannelAction,
        action: AgentChannelCustomHTTPAction,
        values: [String: String],
        statusCode: Int,
        redactedResponse: Any,
        standardKindOverride: String?
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "connection_id": connection.id,
            "kind": "custom_http_\(actionName.rawValue)",
            "standard_kind": standardKindOverride ?? standardKind(for: actionName),
            "http_status": statusCode,
            "raw": redactedResponse,
        ]
        if let roomId = values["room_id"] { payload["room_id"] = roomId }
        if let threadId = values["thread_id"] { payload["thread_id"] = threadId }
        if let query = values["query"] { payload["query"] = query }

        switch actionName {
        case .listSpaces:
            payload["spaces"] = collectionRows(
                from: redactedResponse,
                action: action,
                defaultKeys: ["spaces", "data", "items"],
                kind: "space"
            )
        case .listRooms:
            payload["space_id"] = values["space_id"] ?? ""
            payload["rooms"] = collectionRows(
                from: redactedResponse,
                action: action,
                defaultKeys: ["rooms", "channels", "data", "items"],
                kind: "room"
            )
        case .readMessages, .searchMessages:
            payload["messages"] = collectionRows(
                from: redactedResponse,
                action: action,
                defaultKeys: ["messages", "data", "items", "results"],
                kind: "message"
            )
        case .sendMessage, .replyThread:
            payload["message"] = messageRow(from: redactedResponse, action: action, fallbackContent: values["content"])
        case .diagnostics, .draftMessage:
            break
        }
        return payload
    }

    private func standardKind(for action: AgentChannelAction) -> String {
        switch action {
        case .diagnostics:
            return "diagnostics"
        case .listSpaces:
            return "spaces"
        case .listRooms:
            return "rooms"
        case .readMessages:
            return "channel_messages"
        case .searchMessages:
            return "message_search"
        case .draftMessage:
            return "message_draft"
        case .sendMessage:
            return "message_sent"
        case .replyThread:
            return "thread_reply_sent"
        }
    }

    private func collectionRows(
        from response: Any,
        action: AgentChannelCustomHTTPAction,
        defaultKeys: [String],
        kind: String
    ) -> [[String: Any]] {
        let collection: [Any]
        if let path = action.responseMapping?.collectionPath,
           let value = value(at: path, in: response) {
            collection = value as? [Any] ?? [value]
        } else if let array = response as? [Any] {
            collection = array
        } else if let dictionary = response as? [String: Any],
                  let found = defaultKeys.compactMap({ dictionary[$0] as? [Any] }).first {
            collection = found
        } else {
            collection = []
        }

        return collection.map { item in
            var row: [String: Any] = ["kind": kind, "raw": item]
            row["id"] = stringValue(mapped: action.responseMapping?.idPath, key: "id", item: item) ?? ""
            row["name"] = stringValue(mapped: action.responseMapping?.namePath, key: "name", item: item) ?? ""
            if let content = stringValue(mapped: action.responseMapping?.contentPath, key: "content", item: item) {
                row["content"] = content
            }
            if let url = stringValue(mapped: action.responseMapping?.urlPath, key: "url", item: item) {
                row["url"] = url
            }
            return row
        }
    }

    private func messageRow(
        from response: Any,
        action: AgentChannelCustomHTTPAction,
        fallbackContent: String?
    ) -> [String: Any] {
        var row: [String: Any] = ["raw": response]
        row["id"] = stringValue(mapped: action.responseMapping?.idPath, key: "id", item: response) ?? ""
        row["content"] = stringValue(
            mapped: action.responseMapping?.contentPath,
            key: "content",
            item: response
        ) ?? fallbackContent ?? ""
        if let url = stringValue(mapped: action.responseMapping?.urlPath, key: "url", item: response) {
            row["url"] = url
        }
        return row
    }

    private func stringValue(mapped path: String?, key: String, item: Any) -> String? {
        let value: Any?
        if let path {
            value = self.value(at: path, in: item)
        } else if let dictionary = item as? [String: Any] {
            value = dictionary[key]
        } else {
            value = nil
        }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func value(at path: String, in item: Any) -> Any? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutRoot = trimmed.hasPrefix("$.") ? String(trimmed.dropFirst(2)) : trimmed
        guard !withoutRoot.isEmpty else { return item }
        return withoutRoot.split(separator: ".").reduce(Optional(item)) { current, part in
            guard let current else { return nil }
            if let dictionary = current as? [String: Any] {
                return dictionary[String(part)]
            }
            if let array = current as? [Any],
               let index = Int(part),
               array.indices.contains(index) {
                return array[index]
            }
            return nil
        }
    }

    private func redactedPayload(from data: Data, secrets: [String]) -> Any {
        if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return redactJSON(json, secrets: secrets)
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return redactedString(text, secrets: secrets)
    }

    private func redactJSON(_ value: Any, secrets: [String]) -> Any {
        if let string = value as? String {
            return redactedString(string, secrets: secrets)
        }
        if let array = value as? [Any] {
            return array.map { redactJSON($0, secrets: secrets) }
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues { redactJSON($0, secrets: secrets) }
        }
        return value
    }

    private func diagnosticString(from payload: Any) -> String {
        let string: String
        if JSONSerialization.isValidJSONObject(payload),
           let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            string = text
        } else {
            string = String(describing: payload)
        }
        guard string.count > Self.maxDiagnosticBodyCharacters else { return string }
        return String(string.prefix(Self.maxDiagnosticBodyCharacters)) + "...[truncated]"
    }

    private func resolvedSecrets(
        connection: AgentChannelConnection,
        action: AgentChannelCustomHTTPAction,
        values: [String: String]
    ) -> [String] {
        let templates = Array(action.headers.values) + Array(action.query.values) + [action.bodyTemplate].compactMap { $0 }
        let names = templates.flatMap { template in
            (try? referencedSecrets(in: template)) ?? []
        }
        return names.compactMap { secretResolver.secret(named: $0, for: connection) }
            .filter { $0.count >= SecretScrubber.minimumValueLength }
    }

    private func referencedSecrets(in template: String) throws -> [String] {
        var names = [String]()
        _ = try replaceDollarPlaceholders(in: template) { placeholder in
            if let name = placeholder.secretName {
                names.append(name)
            }
            return ""
        }
        return names
    }

    private func redactedDictionary(_ dictionary: [String: String], secrets: [String]) -> [String: String] {
        dictionary.mapValues { redactedString($0, secrets: secrets) }
    }

    private func redactedString(_ string: String, secrets: [String]) -> String {
        secrets.reduce(string) { partial, secret in
            partial.replacingOccurrences(of: secret, with: "[REDACTED:AGENT_CHANNEL_SECRET]")
        }
    }

    private func requireReadable(_ id: String, connection: AgentChannelConnection) throws -> String {
        let normalized = normalizedId(id)
        guard !normalized.isEmpty else {
            throw AgentChannelCustomHTTPRunnerError.roomNotReadable(id)
        }
        if connection.readRoomAllowlist.isEmpty || connection.readRoomAllowlist.contains(normalized) {
            return normalized
        }
        throw AgentChannelCustomHTTPRunnerError.roomNotReadable(normalized)
    }

    private func requireWritable(
        _ id: String,
        connection: AgentChannelConnection,
        requireWriteEnabled: Bool
    ) throws -> String {
        let normalized = normalizedId(id)
        guard !normalized.isEmpty else {
            throw AgentChannelCustomHTTPRunnerError.roomNotWritable(id)
        }
        if requireWriteEnabled, !connection.writeEnabled {
            throw AgentChannelCustomHTTPRunnerError.writeDisabled(connection.id)
        }
        guard connection.writeRoomAllowlist.contains(normalized) else {
            throw AgentChannelCustomHTTPRunnerError.roomNotWritable(normalized)
        }
        return normalized
    }

    private func validatedContent(_ content: String) throws -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentChannelCustomHTTPRunnerError.malformedTemplate("content")
        }
        guard trimmed.utf8.count <= Self.bodyLimitBytes else {
            throw AgentChannelCustomHTTPRunnerError.bodyTooLarge(trimmed.utf8.count)
        }
        return trimmed
    }

    private func normalizedId(_ id: String) -> String {
        AgentChannelConnection.normalizedId(id)
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration, delegate: AgentChannelCustomHTTPRedirectGuard(), delegateQueue: nil)
    }
}

private enum TemplateRenderMode {
    case text
    case jsonString

    func render(_ value: String) -> String {
        switch self {
        case .text:
            return value
        case .jsonString:
            return value.jsonEscapedForStringLiteral
        }
    }
}

private final class AgentChannelCustomHTTPRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let url = request.url,
              let host = url.host,
              (try? validateSafeHost(host, original: url.absoluteString)) != nil,
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme)
        else {
            return nil
        }
        return request
    }
}

private func validateActionPath(_ path: String) throws {
    guard path.hasPrefix("/"), !path.containsLineBreak, !path.contains("\\") else {
        throw AgentChannelCustomHTTPRunnerError.unsafeURL(path)
    }
}

private func composePath(_ basePath: String, _ actionPath: String) -> String {
    let normalizedBase = basePath == "/" ? "" : basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !normalizedBase.isEmpty else { return actionPath }
    return "/" + normalizedBase + actionPath
}

private func validateHeaderName(_ name: String) throws {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
    guard !name.isEmpty,
          name.unicodeScalars.allSatisfy({ allowed.contains($0) }),
          !name.containsLineBreak
    else {
        throw AgentChannelCustomHTTPRunnerError.unsafeHeader(name)
    }
}

private func validateSafeHost(_ host: String, original: String) throws {
    let lower = normalizedHostLiteral(host)
    guard !lower.isEmpty,
          !lower.containsLineBreak,
          lower != "localhost",
          lower != "local",
          !lower.hasSuffix(".localhost"),
          !lower.hasSuffix(".local")
    else {
        throw AgentChannelCustomHTTPRunnerError.unsafeURL(original)
    }
    if let ipv4 = IPv4Literal(lower), ipv4.isPrivateOrLocal {
        throw AgentChannelCustomHTTPRunnerError.unsafeURL(original)
    }
    if lower.contains(":"),
       lower == "::1"
        || lower.hasPrefix("fe80:")
        || lower.hasPrefix("fc")
        || lower.hasPrefix("fd")
        || lower == "0:0:0:0:0:0:0:1" {
        throw AgentChannelCustomHTTPRunnerError.unsafeURL(original)
    }
}

private func normalizedHostLiteral(_ host: String) -> String {
    let lower = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if lower.hasPrefix("["),
       lower.hasSuffix("]") {
        return String(lower.dropFirst().dropLast())
    }
    return lower
}

private struct IPv4Literal {
    let octets: [UInt8]

    init?(_ host: String) {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var parsed = [UInt8]()
        for part in parts {
            guard let value = UInt8(part), String(value) == String(part) else {
                return nil
            }
            parsed.append(value)
        }
        octets = parsed
    }

    var isPrivateOrLocal: Bool {
        let first = octets[0]
        let second = octets[1]
        if first == 0 || first == 10 || first == 127 || first >= 224 { return true }
        if first == 100 && (64 ... 127).contains(second) { return true }
        if first == 169 && second == 254 { return true }
        if first == 172 && (16 ... 31).contains(second) { return true }
        if first == 192 && second == 168 { return true }
        if first == 198 && (18 ... 19).contains(second) { return true }
        return false
    }
}

private func percentEncodePathSegment(_ value: String) -> String {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
}

private extension String {
    var containsLineBreak: Bool {
        rangeOfCharacter(from: .newlines) != nil
    }

    var secretName: String? {
        guard hasPrefix("secret:") else { return nil }
        let name = String(dropFirst("secret:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    var jsonEscapedForStringLiteral: String {
        var escaped = ""
        for scalar in unicodeScalars {
            switch scalar {
            case "\"":
                escaped += "\\\""
            case "\\":
                escaped += "\\\\"
            case "\n":
                escaped += "\\n"
            case "\r":
                escaped += "\\r"
            case "\t":
                escaped += "\\t"
            default:
                if scalar.value < 0x20 {
                    escaped += String(format: "\\u%04X", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return escaped
    }
}
