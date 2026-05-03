//
//  LLMCapabilitySnapshot.swift
//  osaurus
//
//  Central model/provider capability contract used to keep UI options,
//  prompt guidance, request construction, and tests aligned.
//

import Foundation

enum LLMProviderKind: String, Sendable, Equatable {
    case foundation
    case localMLX
    case remoteOpenAILegacy
    case remoteAnthropic
    case remoteOpenResponses
    case remoteOpenAICodex
    case remoteGemini
    case remoteOsaurus
    case unknown
}

enum LLMRuntimeKind: String, Sendable, Equatable {
    case foundation
    case localMLX
    case remote
    case osaurusAgent
    case unknown
}

enum LLMToolCallMode: String, Sendable, Equatable {
    case nativeStructured
    case adapterStructured
    case serverSideAgent
    case textFallback
    case none
}

enum LLMReasoningMode: Sendable, Equatable {
    case none
    case effort(optionId: String, levels: [String])
    case toggle(optionId: String, inverted: Bool)
    case providerSpecific(optionId: String)

    var optionId: String? {
        switch self {
        case .none:
            return nil
        case .effort(let optionId, _), .toggle(let optionId, _), .providerSpecific(let optionId):
            return optionId
        }
    }
}

enum LLMReasoningStreamMode: String, Sendable, Equatable {
    case none
    case native
    case sentinel
}

struct LLMModalities: OptionSet, Sendable, Equatable {
    let rawValue: Int

    static let textInput = LLMModalities(rawValue: 1 << 0)
    static let imageInput = LLMModalities(rawValue: 1 << 1)
    static let textOutput = LLMModalities(rawValue: 1 << 2)
    static let imageOutput = LLMModalities(rawValue: 1 << 3)
}

enum LLMRequestParameter: String, Sendable, Hashable {
    case temperature
    case topP = "top_p"
    case reasoningEffort = "reasoning_effort"
    case reasoning
    case tools
    case toolChoice = "tool_choice"
    case imageOptions = "image_options"
}

struct LLMCapabilitySnapshot: Sendable {
    let modelId: String
    let providerKind: LLMProviderKind
    let runtimeKind: LLMRuntimeKind
    let family: ModelFamily
    let contextWindowTokens: Int
    let defaultMaxOutputTokens: Int
    let supportsStreaming: Bool
    let toolCallMode: LLMToolCallMode
    let reasoningMode: LLMReasoningMode
    let reasoningStreamMode: LLMReasoningStreamMode
    let inputModalities: LLMModalities
    let outputModalities: LLMModalities
    let unsupportedParameters: Set<LLMRequestParameter>
    let optionDefinitions: [ModelOptionDefinition]

    var diagnosticID: String {
        [
            providerKind.rawValue,
            runtimeKind.rawValue,
            family.rawValue,
            toolCallMode.rawValue,
            reasoningStreamMode.rawValue,
            String(contextWindowTokens),
        ].joined(separator: "/")
    }
}

enum LLMCapabilityResolver {
    static let defaultContextWindowTokens = 128_000
    static let defaultMaxOutputTokens = 16_384

    static func resolve(
        modelId rawModelId: String?,
        providerType: RemoteProviderType? = nil,
        runtimeKind runtimeHint: LLMRuntimeKind? = nil,
        contextWindowTokens contextOverride: Int? = nil
    ) -> LLMCapabilitySnapshot {
        let modelId = normalizedModelId(rawModelId)
        let providerKind = resolveProviderKind(
            modelId: modelId,
            providerType: providerType,
            runtimeHint: runtimeHint
        )
        let runtimeKind = resolveRuntimeKind(providerKind: providerKind, runtimeHint: runtimeHint)
        let family = ModelFamilyGuidance.family(for: modelId)
        let modelInfo = ModelInfo.load(modelId: modelId)
        let contextWindowTokens =
            contextOverride
            ?? modelInfo?.model.contextLength
            ?? defaultContextWindowTokens
        let optionDefinitions = ModelProfileRegistry.options(for: modelId)
        let reasoningMode = resolveReasoningMode(modelId: modelId)
        let toolCallMode = resolveToolCallMode(providerKind: providerKind, runtimeKind: runtimeKind)
        let inputModalities = resolveInputModalities(
            modelId: modelId,
            providerKind: providerKind,
            modelInfo: modelInfo
        )
        let outputModalities = resolveOutputModalities(modelId: modelId, providerKind: providerKind)
        let unsupportedParameters = resolveUnsupportedParameters(
            modelId: modelId,
            toolCallMode: toolCallMode,
            reasoningMode: reasoningMode,
            outputModalities: outputModalities
        )

        return LLMCapabilitySnapshot(
            modelId: modelId,
            providerKind: providerKind,
            runtimeKind: runtimeKind,
            family: family,
            contextWindowTokens: contextWindowTokens,
            defaultMaxOutputTokens: defaultMaxOutputTokens,
            supportsStreaming: true,
            toolCallMode: toolCallMode,
            reasoningMode: reasoningMode,
            reasoningStreamMode: resolveReasoningStreamMode(runtimeKind: runtimeKind, reasoningMode: reasoningMode),
            inputModalities: inputModalities,
            outputModalities: outputModalities,
            unsupportedParameters: unsupportedParameters,
            optionDefinitions: optionDefinitions
        )
    }

    private static func normalizedModelId(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "foundation" : trimmed
    }

    private static func resolveProviderKind(
        modelId: String,
        providerType: RemoteProviderType?,
        runtimeHint: LLMRuntimeKind?
    ) -> LLMProviderKind {
        if let providerType {
            switch providerType {
            case .openaiLegacy, .azureOpenAI: return .remoteOpenAILegacy
            case .anthropic: return .remoteAnthropic
            case .openResponses: return .remoteOpenResponses
            case .openAICodex: return .remoteOpenAICodex
            case .gemini: return .remoteGemini
            case .osaurus: return .remoteOsaurus
            }
        }
        // swiftlint:disable opening_brace
        if runtimeHint == .foundation
            || modelId.caseInsensitiveCompare("foundation") == .orderedSame
            || modelId.caseInsensitiveCompare("default") == .orderedSame
        {
            return .foundation
        }
        // swiftlint:enable opening_brace
        if runtimeHint == .remote { return .unknown }
        if runtimeHint == .localMLX { return .localMLX }
        if runtimeHint == .unknown { return .unknown }
        return .localMLX
    }

    private static func resolveRuntimeKind(
        providerKind: LLMProviderKind,
        runtimeHint: LLMRuntimeKind?
    ) -> LLMRuntimeKind {
        if let runtimeHint { return runtimeHint }
        switch providerKind {
        case .foundation:
            return .foundation
        case .localMLX:
            return .localMLX
        case .remoteOsaurus:
            return .osaurusAgent
        case .remoteOpenAILegacy, .remoteAnthropic, .remoteOpenResponses, .remoteOpenAICodex,
            .remoteGemini:
            return .remote
        case .unknown:
            return .unknown
        }
    }

    private static func resolveToolCallMode(
        providerKind: LLMProviderKind,
        runtimeKind: LLMRuntimeKind
    ) -> LLMToolCallMode {
        switch providerKind {
        case .remoteOsaurus:
            return .serverSideAgent
        case .remoteOpenAILegacy, .remoteAnthropic, .remoteOpenResponses, .remoteOpenAICodex,
            .remoteGemini:
            return .adapterStructured
        case .foundation, .localMLX:
            return .nativeStructured
        case .unknown:
            return runtimeKind == .remote ? .adapterStructured : .none
        }
    }

    private static func resolveReasoningMode(modelId: String) -> LLMReasoningMode {
        if OpenAIReasoningProfile.matches(modelId: modelId) {
            return .effort(
                optionId: "reasoningEffort",
                levels: ["minimal", "low", "medium", "high"]
            )
        }
        if let thinkingOption = ModelProfileRegistry.profile(for: modelId)?.thinkingOption {
            return .toggle(optionId: thinkingOption.id, inverted: thinkingOption.inverted)
        }
        return .none
    }

    private static func resolveReasoningStreamMode(
        runtimeKind: LLMRuntimeKind,
        reasoningMode: LLMReasoningMode
    ) -> LLMReasoningStreamMode {
        guard reasoningMode != .none else { return .none }
        switch runtimeKind {
        case .localMLX, .remote:
            return .sentinel
        case .foundation, .osaurusAgent, .unknown:
            return .none
        }
    }

    private static func resolveInputModalities(
        modelId: String,
        providerKind: LLMProviderKind,
        modelInfo: ModelInfo?
    ) -> LLMModalities {
        var modalities: LLMModalities = [.textInput]
        let lower = modelId.lowercased()
        // swiftlint:disable opening_brace
        if providerKind == .remoteGemini
            || modelInfo?.capabilities.contains("vision") == true
            || lower.contains("vision") || lower.contains("pixtral") || lower.contains("gpt-4o")
            || lower.contains("gemini")
        {
            modalities.insert(.imageInput)
        }
        // swiftlint:enable opening_brace
        return modalities
    }

    private static func resolveOutputModalities(
        modelId: String,
        providerKind: LLMProviderKind
    ) -> LLMModalities {
        var modalities: LLMModalities = [.textOutput]
        if providerKind == .remoteGemini && isGeminiImageOutputModel(modelId) {
            modalities.insert(.imageOutput)
        }
        return modalities
    }

    private static func isGeminiImageOutputModel(_ modelId: String) -> Bool {
        Gemini31FlashImageProfile.matches(modelId: modelId)
            || GeminiProImageProfile.matches(modelId: modelId)
            || GeminiFlashImageProfile.matches(modelId: modelId)
    }

    private static func resolveUnsupportedParameters(
        modelId: String,
        toolCallMode: LLMToolCallMode,
        reasoningMode: LLMReasoningMode,
        outputModalities: LLMModalities
    ) -> Set<LLMRequestParameter> {
        var unsupported = Set<LLMRequestParameter>()

        if OpenAIReasoningProfile.matches(modelId: modelId) {
            unsupported.insert(.temperature)
            unsupported.insert(.topP)
        }
        if case .effort = reasoningMode {
            // OpenAI-style effort is the only standard request-level
            // reasoning shape Osaurus can currently serialize.
        } else {
            unsupported.insert(.reasoning)
            unsupported.insert(.reasoningEffort)
        }
        if toolCallMode == .none || toolCallMode == .textFallback {
            unsupported.insert(.tools)
            unsupported.insert(.toolChoice)
        }
        if !outputModalities.contains(.imageOutput) {
            unsupported.insert(.imageOptions)
        }

        return unsupported
    }
}
