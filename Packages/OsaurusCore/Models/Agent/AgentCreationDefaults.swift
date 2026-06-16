//
//  AgentCreationDefaults.swift
//  osaurus
//
//  Persisted defaults used when creating custom agents from API/UI flows.
//

import Foundation

public struct AgentCreationDefaults: Codable, Equatable, Sendable {
    public var defaultModel: String?
    public var temperature: Float?
    public var maxTokens: Int?
    public var toolSelectionMode: ToolSelectionMode?
    public var manualToolNames: [String]?
    public var manualSkillNames: [String]?
    // swiftlint:disable:next discouraged_optional_boolean
    public var autoSpeak: Bool?
    public var ttsVoice: String?

    public init(
        defaultModel: String? = nil,
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        toolSelectionMode: ToolSelectionMode? = nil,
        manualToolNames: [String]? = nil,
        manualSkillNames: [String]? = nil,
        // swiftlint:disable:next discouraged_optional_boolean
        autoSpeak: Bool? = nil,
        ttsVoice: String? = nil
    ) {
        self.defaultModel = defaultModel
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.toolSelectionMode = toolSelectionMode
        self.manualToolNames = manualToolNames
        self.manualSkillNames = manualSkillNames
        self.autoSpeak = autoSpeak
        self.ttsVoice = ttsVoice
    }

    public static var `default`: AgentCreationDefaults {
        AgentCreationDefaults()
    }

    public func merging(_ overrides: AgentCreationDefaults) -> AgentCreationDefaults {
        AgentCreationDefaults(
            defaultModel: overrides.defaultModel ?? defaultModel,
            temperature: overrides.temperature ?? temperature,
            maxTokens: overrides.maxTokens ?? maxTokens,
            toolSelectionMode: overrides.toolSelectionMode ?? toolSelectionMode,
            manualToolNames: overrides.manualToolNames ?? manualToolNames,
            manualSkillNames: overrides.manualSkillNames ?? manualSkillNames,
            autoSpeak: overrides.autoSpeak ?? autoSpeak,
            ttsVoice: overrides.ttsVoice ?? ttsVoice
        )
    }
}
