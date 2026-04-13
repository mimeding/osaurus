//
//  MLXGenerationEngine.swift
//  osaurus
//
//  Encapsulates MLX message preparation and generation stream construction.
//

import CoreImage
import Foundation
import MLX
import MLXLLM
@preconcurrency import MLXLMCommon
import MLXVLM
import os.log

private let engineLog = Logger(subsystem: "ai.osaurus", category: "Generation")
private let engineSignposter = OSSignposter(subsystem: "ai.osaurus", category: "Generation")

/// Returns the effective offset of the first KV cache layer that actually tracks position
/// (i.e., not a MambaCache / ArraysCache layer whose `offset` is always 0).
///
/// For RotatingKVCache layers that have wrapped past their sliding window, the raw `offset`
/// reflects total tokens processed — not the number of tokens actually stored. We cap at
/// `maxSize` so callers can safely use this value to index into token arrays.
func effectiveCacheOffset(_ cache: [any KVCache]) -> Int {
    for layer in cache {
        // MambaCache (and its parent ArraysCache) never updates offset — skip them.
        if layer is ArraysCache { continue }
        // Cap at maxSize for rotating caches that have wrapped past their window.
        if let maxSize = layer.maxSize {
            return min(layer.offset, maxSize)
        }
        return layer.offset
    }
    // All layers are Mamba-style; fall back to first layer (offset will be 0 but that's correct).
    return cache.first?.offset ?? 0
}

struct MLXGenerationEngine {

    private static let maxImageSize = CGSize(width: 1024, height: 1024)

    private static func downscaleIfNeeded(_ image: CIImage) -> CIImage {
        let scale = min(MediaProcessing.bestFitScale(image.extent.size, in: maxImageSize), 1.0)
        guard scale < 1.0 else { return image }
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    static func preprocessImages(in chat: [MLXLMCommon.Chat.Message]) -> [MLXLMCommon.Chat.Message] {
        chat.map { message in
            let processedImages = message.images.map { userInputImage -> UserInput.Image in
                switch userInputImage {
                case .ciImage(let ciImage):
                    return .ciImage(downscaleIfNeeded(ciImage))
                default:
                    return userInputImage
                }
            }
            return MLXLMCommon.Chat.Message(
                role: message.role,
                content: message.content,
                images: processedImages,
                videos: message.videos
            )
        }
    }

    /// Holds the generation stream plus the caller-owned KV cache that was
    /// passed into (or created for) `generate()`.  Because `[any KVCache]` is
    /// not `Sendable`, we wrap it in an `@unchecked Sendable` box so it can
    /// cross the `container.perform` boundary safely -- access is serialised
    /// through the `ModelRuntime` actor.
    final class CacheBox: @unchecked Sendable {
        let cache: [any KVCache]
        init(_ cache: [any KVCache]) { self.cache = cache }
    }

    static func prepareAndGenerate(
        container: ModelContainer,
        buildChat: @Sendable () -> [MLXLMCommon.Chat.Message],
        buildToolsSpec: @Sendable () -> [[String: any Sendable]]?,
        generation: GenerationParameters,
        runtime: RuntimeConfig,
        wiredMemoryTicket: WiredMemoryTicket?
    ) async throws -> (
        stream: AsyncStream<MLXLMCommon.TokenGeneration>,
        tokenizer: any Tokenizer,
        cache: [any KVCache],
        promptTokens: [Int],
        genTask: Task<Void, Never>,
        toolCallFormat: ToolCallFormat
    ) {
        let spState = engineSignposter.beginInterval("prepareAndGenerate", id: engineSignposter.makeSignpostID())
        let t0 = CFAbsoluteTimeGetCurrent()
        defer { engineSignposter.endInterval("prepareAndGenerate", spState) }

        final class ResultBox: @unchecked Sendable {
            let stream: AsyncStream<MLXLMCommon.TokenGeneration>
            let tokenizer: any Tokenizer
            let cache: CacheBox
            let promptTokens: [Int]
            let genTask: Task<Void, Never>
            let toolCallFormat: ToolCallFormat
            init(
                _ stream: AsyncStream<MLXLMCommon.TokenGeneration>,
                _ tokenizer: any Tokenizer,
                _ cache: CacheBox,
                _ promptTokens: [Int],
                _ genTask: Task<Void, Never>,
                _ toolCallFormat: ToolCallFormat
            ) {
                self.stream = stream; self.tokenizer = tokenizer; self.cache = cache
                self.promptTokens = promptTokens; self.genTask = genTask
                self.toolCallFormat = toolCallFormat
            }
        }

        let result: ResultBox = try await container.perform { (context: MLXLMCommon.ModelContext) in
            let chat = preprocessImages(in: buildChat())
            let toolsSpec = buildToolsSpec()
            let parameters = ModelRuntime.makeGenerateParameters(
                temperature: generation.temperature ?? 0.7,
                maxTokens: generation.maxTokens,
                topP: generation.topPOverride ?? runtime.topP,
                repetitionPenalty: generation.repetitionPenalty,
                kvBits: runtime.kvBits,
                kvGroup: runtime.kvGroup,
                quantStart: runtime.quantStart,
                maxKV: runtime.maxKV,
                prefillStep: runtime.prefillStep,
                turboQuant: runtime.turboQuant
            )
            let additionalContext: [String: any Sendable]? =
                generation.modelOptions["disableThinking"]?.boolValue == true
                ? ["enable_thinking": false] : nil
            let fullInput = MLXLMCommon.UserInput(
                chat: chat,
                processing: .init(),
                tools: toolsSpec,
                additionalContext: additionalContext
            )
            let fullLMInput: LMInput
            do {
                fullLMInput = try await context.processor.prepare(input: fullInput)
            } catch {
                let detail =
                    (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
                throw NSError(
                    domain: "MLXGenerationEngine",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Chat template error: \(detail)"]
                )
            }

            var contextWithEOS = context
            let existing = context.configuration.extraEOSTokens
            let extra: Set<String> = Set(["</end_of_turn>", "<end_of_turn>", "<|end|>", "<eot>"])
            contextWithEOS.configuration.extraEOSTokens = existing.union(extra)

            let newPromptTokens = fullLMInput.text.tokens.asArray(Int.self)
            engineLog.info(
                "prepareAndGenerate: promptTokens=\(newPromptTokens.count, privacy: .public) hasImage=\(fullLMInput.image != nil, privacy: .public)"
            )
            guard !newPromptTokens.isEmpty else {
                throw NSError(
                    domain: "MLXGenerationEngine",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Tokenizer produced no tokens for the given input"]
                )
            }
            let cache = makePromptCache(model: context.model, parameters: parameters)

            // ── Single-phase prefill + generation ─────────────────────────────────────
            engineLog.info(
                "prepareAndGenerate: constructing TokenIterator effectiveTokens=\(fullLMInput.text.tokens.dim(0), privacy: .public)"
            )
            let iterator = try withError {
                try TokenIterator(
                    input: fullLMInput,
                    model: contextWithEOS.model,
                    cache: cache,
                    parameters: parameters
                )
            }
            let postPrefillOffset = effectiveCacheOffset(cache)
            debugLog(
                "[MLXGenerationEngine] post-prefill effectiveCacheOffset=\(postPrefillOffset) cacheCount=\(cache.count) cacheTypes=\(cache.prefix(4).map { type(of: $0) })"
            )
            engineSignposter.emitEvent(
                "prefillComplete",
                id: engineSignposter.makeSignpostID(),
                "promptTokens: \(newPromptTokens.count, privacy: .public), effectiveTokens: \(fullLMInput.text.tokens.dim(0), privacy: .public), cacheOffset: \(postPrefillOffset, privacy: .public)"
            )
            let (stream, genTask) = MLXLMCommon.generateTokenTask(
                promptTokenCount: newPromptTokens.count,
                modelConfiguration: contextWithEOS.configuration,
                tokenizer: contextWithEOS.tokenizer,
                iterator: iterator,
                wiredMemoryTicket: wiredMemoryTicket
            )
            engineLog.info("prepareAndGenerate: generateTokenTask created, returning stream")

            let toolCallFormat = contextWithEOS.configuration.toolCallFormat ?? .json
            return ResultBox(
                stream,
                contextWithEOS.tokenizer,
                CacheBox(cache),
                newPromptTokens,
                genTask,
                toolCallFormat
            )
        }
        let durationMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        engineLog.info(
            "[perf] prepareAndGenerate durationMs=\(Int(durationMs), privacy: .public) promptTokens=\(result.promptTokens.count, privacy: .public)"
        )
        return (
            result.stream, result.tokenizer, result.cache.cache, result.promptTokens, result.genTask,
            result.toolCallFormat
        )
    }
}
