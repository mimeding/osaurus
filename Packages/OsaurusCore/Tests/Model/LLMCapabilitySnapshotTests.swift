import Foundation
import Testing

@testable import OsaurusCore

@Suite("LLMCapabilityResolver")
struct LLMCapabilitySnapshotTests {

    @Test("default model resolves to Foundation text-only capabilities")
    func defaultFoundationSnapshot() {
        let snapshot = LLMCapabilityResolver.resolve(modelId: nil)

        #expect(snapshot.modelId == "foundation")
        #expect(snapshot.providerKind == .foundation)
        #expect(snapshot.runtimeKind == .foundation)
        #expect(snapshot.toolCallMode == .nativeStructured)
        #expect(snapshot.reasoningMode == .none)
        #expect(snapshot.reasoningStreamMode == .none)
        #expect(snapshot.inputModalities == [.textInput])
        #expect(snapshot.outputModalities == [.textOutput])
        #expect(snapshot.unsupportedParameters.contains(.reasoning))
        #expect(snapshot.unsupportedParameters.contains(.reasoningEffort))
    }

    @Test("Qwen thinking model exposes local thinking toggle")
    func qwenThinkingSnapshot() {
        let snapshot = LLMCapabilityResolver.resolve(modelId: "qwen3.5-35b-a3b-4bit")

        #expect(snapshot.providerKind == .localMLX)
        #expect(snapshot.runtimeKind == .localMLX)
        #expect(snapshot.family == .glmQwen)
        #expect(snapshot.toolCallMode == .nativeStructured)
        #expect(snapshot.reasoningStreamMode == .sentinel)
        guard case .toggle(let optionId, let inverted) = snapshot.reasoningMode else {
            #expect(Bool(false), "Qwen thinking models should expose a toggle")
            return
        }
        #expect(optionId == "disableThinking")
        #expect(inverted)
        #expect(snapshot.optionDefinitions.map(\.id).contains("disableThinking"))
        #expect(snapshot.unsupportedParameters.contains(.reasoning))
        #expect(snapshot.unsupportedParameters.contains(.reasoningEffort))
    }

    @Test("Qwen coder does not expose reasoning controls")
    func qwenCoderSnapshot() {
        let snapshot = LLMCapabilityResolver.resolve(modelId: "qwen3-coder-plus")

        #expect(snapshot.family == .glmQwen)
        #expect(snapshot.reasoningMode == .none)
        #expect(!snapshot.optionDefinitions.map(\.id).contains("disableThinking"))
    }

    @Test("Gemma family is identified without adding reasoning controls")
    func gemmaSnapshot() {
        let snapshot = LLMCapabilityResolver.resolve(modelId: "gemma-2-non-reasoning-\(UUID().uuidString)")

        #expect(snapshot.family == .googleGemma)
        #expect(snapshot.providerKind == .localMLX)
        #expect(snapshot.reasoningMode == .none)
    }

    @Test("Open Responses reasoning model omits unsupported sampling parameters")
    func openResponsesReasoningSnapshot() {
        let snapshot = LLMCapabilityResolver.resolve(
            modelId: "gpt-5-mini",
            providerType: .openResponses
        )

        #expect(snapshot.providerKind == .remoteOpenResponses)
        #expect(snapshot.runtimeKind == .remote)
        #expect(snapshot.toolCallMode == .adapterStructured)
        #expect(snapshot.reasoningStreamMode == .sentinel)
        guard case .effort(let optionId, let levels) = snapshot.reasoningMode else {
            #expect(Bool(false), "OpenAI-style reasoning models should expose effort")
            return
        }
        #expect(optionId == "reasoningEffort")
        #expect(levels == ["minimal", "low", "medium", "high"])
        #expect(snapshot.unsupportedParameters.contains(.temperature))
        #expect(snapshot.unsupportedParameters.contains(.topP))
        #expect(!snapshot.unsupportedParameters.contains(.reasoningEffort))
    }

    @Test("OpenAI Codex provider resolves as a remote adapter")
    func openAICodexSnapshot() {
        let snapshot = LLMCapabilityResolver.resolve(
            modelId: "gpt-5-codex",
            providerType: .openAICodex
        )

        #expect(snapshot.providerKind == .remoteOpenAICodex)
        #expect(snapshot.runtimeKind == .remote)
        #expect(snapshot.toolCallMode == .adapterStructured)
        #expect(snapshot.family == .gptCodex)
    }

    @Test("Azure OpenAI provider resolves as an OpenAI-compatible remote adapter")
    func azureOpenAISnapshot() {
        let snapshot = LLMCapabilityResolver.resolve(
            modelId: "gpt-5-mini",
            providerType: .azureOpenAI
        )

        #expect(snapshot.providerKind == .remoteOpenAILegacy)
        #expect(snapshot.runtimeKind == .remote)
        #expect(snapshot.toolCallMode == .adapterStructured)
    }

    @Test("Gemini image model exposes image input and output options")
    func geminiImageSnapshot() {
        let snapshot = LLMCapabilityResolver.resolve(
            modelId: "gemini-3-pro-image-preview",
            providerType: .gemini
        )

        #expect(snapshot.providerKind == .remoteGemini)
        #expect(snapshot.runtimeKind == .remote)
        #expect(snapshot.inputModalities.contains(.imageInput))
        #expect(snapshot.outputModalities.contains(.imageOutput))
        #expect(snapshot.optionDefinitions.map(\.id).contains("aspectRatio"))
        #expect(snapshot.optionDefinitions.map(\.id).contains("imageSize"))
        #expect(snapshot.optionDefinitions.map(\.id).contains("outputType"))
        #expect(!snapshot.unsupportedParameters.contains(.imageOptions))
    }

    @Test("Venice model options are surfaced without standard reasoning request fields")
    func veniceSnapshot() {
        let snapshot = LLMCapabilityResolver.resolve(
            modelId: "venice-ai/llama-3.1-405b",
            providerType: .openaiLegacy
        )
        let optionIds = snapshot.optionDefinitions.map(\.id)

        #expect(snapshot.providerKind == .remoteOpenAILegacy)
        #expect(optionIds.contains("enableWebSearch"))
        #expect(optionIds.contains("disableThinking"))
        #expect(optionIds.contains("includeVeniceSystemPrompt"))
        #expect(snapshot.unsupportedParameters.contains(.reasoning))
        #expect(snapshot.unsupportedParameters.contains(.reasoningEffort))
    }

    @Test("unknown remote model remains deterministic")
    func unknownRemoteSnapshotDeterministic() {
        let first = LLMCapabilityResolver.resolve(
            modelId: "provider/model-x",
            providerType: .openaiLegacy,
            contextWindowTokens: 32_000
        )
        let second = LLMCapabilityResolver.resolve(
            modelId: "provider/model-x",
            providerType: .openaiLegacy,
            contextWindowTokens: 32_000
        )

        #expect(first.diagnosticID == second.diagnosticID)
        #expect(first.contextWindowTokens == 32_000)
        #expect(first.providerKind == .remoteOpenAILegacy)
        #expect(first.toolCallMode == .adapterStructured)
        #expect(first.reasoningMode == .none)
    }
}
