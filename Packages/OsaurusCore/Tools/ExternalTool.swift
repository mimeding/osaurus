//
//  ExternalTool.swift
//  osaurus
//
//  Wrapper around a specific tool capability from an ExternalPlugin.
//

import Foundation
import OsaurusRepository

final class ExternalTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    let name: String
    let description: String
    let parameters: JSONValue?
    let requirements: [String]
    let defaultPermissionPolicy: ToolPermissionPolicy
    /// The plugin this tool belongs to (matches `PluginManifest.plugin_id`)
    let pluginId: String

    private let plugin: ExternalPlugin
    private let toolId: String

    init(plugin: ExternalPlugin, spec: PluginManifest.ToolSpec) {
        self.plugin = plugin
        self.toolId = spec.id

        self.name = spec.id
        self.pluginId = plugin.id
        self.description = spec.description
        self.parameters = spec.parameters
        self.requirements = spec.requirements ?? []

        if let polStr = spec.permission_policy?.lowercased() {
            switch polStr {
            case "auto": self.defaultPermissionPolicy = .auto
            case "deny": self.defaultPermissionPolicy = .deny
            default: self.defaultPermissionPolicy = .ask
            }
        } else {
            self.defaultPermissionPolicy = .ask
        }
    }

    func execute(argumentsJSON: String) async throws -> String {
        let agentId = ChatExecutionContext.currentAgentId
        let payloadWithSecrets = injectSecrets(into: argumentsJSON, agentId: agentId)
        let payloadWithContext = injectExecutionContext(into: payloadWithSecrets)
        return try await plugin.invoke(type: "tool", id: toolId, payload: payloadWithContext, agentId: agentId)
    }

    /// Injects plugin secrets into the tool payload under the `_secrets` key
    /// - Parameter payload: Original JSON payload
    /// - Returns: Payload with secrets injected, or original payload if no secrets or parsing fails
    private func injectSecrets(into payload: String, agentId: UUID? = nil) -> String {
        let agentId = agentId ?? Agent.defaultId
        let secrets = plugin.resolvedSecrets(agentId: agentId)
        guard !secrets.isEmpty else { return payload }

        // Parse the original payload
        guard let payloadData = payload.data(using: .utf8),
            var payloadDict = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else {
            // If payload isn't a valid JSON object, return as-is
            return payload
        }

        // Add secrets under the `_secrets` key
        payloadDict["_secrets"] = secrets

        // Re-serialize to JSON
        guard let modifiedData = try? JSONSerialization.data(withJSONObject: payloadDict),
            let modifiedPayload = String(data: modifiedData, encoding: .utf8)
        else {
            return payload
        }

        return modifiedPayload
    }

    /// Injects runtime context into the tool payload under the `_context` key
    /// - Parameter payload: Original JSON payload
    /// - Returns: Payload with runtime context injected, or original payload if no context is active
    private func injectExecutionContext(into payload: String) -> String {
        // Read from the thread-safe cache to avoid hopping to MainActor,
        // which can deadlock when the main thread is busy with SwiftUI layout.
        Self.injectRuntimeContext(
            into: payload,
            rootPath: FolderContextService.cachedRootPath,
            inputFiles: ChatExecutionContext.currentInputFiles
        )
    }

    static func injectRuntimeContext(into payload: String, rootPath: URL?, inputFiles: [ChatInputFile]) -> String {
        guard rootPath != nil || !inputFiles.isEmpty else { return payload }

        // Parse the original payload
        guard let payloadData = payload.data(using: .utf8),
            var payloadDict = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else {
            // If payload isn't a valid JSON object, return as-is
            return payload
        }

        var context = payloadDict["_context"] as? [String: Any] ?? [:]
        if let rootPath {
            context["working_directory"] = rootPath.path
        }
        if !inputFiles.isEmpty {
            context["attachments"] = inputFiles.map(\.toolPayload)
        }
        payloadDict["_context"] = context

        // Re-serialize to JSON
        guard let modifiedData = try? JSONSerialization.data(withJSONObject: payloadDict),
            let modifiedPayload = String(data: modifiedData, encoding: .utf8)
        else {
            return payload
        }

        return modifiedPayload
    }
}
