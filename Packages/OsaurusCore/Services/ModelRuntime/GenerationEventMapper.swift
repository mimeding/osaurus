//
//  GenerationEventMapper.swift
//  osaurus
//
//  Bridge from vmlx-swift-lm `Generation` events to osaurus's typed
//  `ModelRuntimeEvent`. Replaces the old token-level `StreamAccumulator` —
//  reasoning stripping and tool-call extraction now live entirely inside
//  `BatchEngine.generate`, so this layer is purely a translation step plus
//  optional stop-sequence lookahead over emitted text chunks.
//
//  Forward-compat: `Generation` does not yet emit a `.reasoning(String)`
//  case (see vmlx-swift-lm OSAURUS-INTEGRATION.md §4). The `switch` below
//  uses `@unknown default` so when the upstream enum gains the case, mapping
//  it to `ModelRuntimeEvent.reasoning(_:)` is a one-line patch — every
//  consumer (HTTP `reasoning_content`, ChatView Think panel, plugin SDK)
//  is already wired through `StreamingReasoningHint`.
//

import Foundation
@preconcurrency import MLXLMCommon
import os.log

private let mapperSignposter = OSSignposter(subsystem: "ai.osaurus", category: "Generation")
private let mapperLog = Logger(subsystem: "ai.osaurus", category: "Generation")

enum GenerationEventMapper {

    /// Map a `Generation` stream into the typed `ModelRuntimeEvent` stream
    /// callers (HTTP handlers, ChatView, plugin runners) consume.
    ///
    /// - Parameters:
    ///   - events: Upstream stream from `BatchEngine.generate`.
    ///   - stopSequences: Hard-stop strings checked against emitted chunk
    ///     text. Hits cause an early `cancel()` on the producer task and a
    ///     truncated final `.tokens` event ending exactly at the stop match.
    ///   - generationTask: Backing producer task; cancelled on stop hit.
    static func map(
        events: AsyncStream<Generation>,
        stopSequences: [String],
        generationTask: Task<Void, Never>?
    ) -> AsyncThrowingStream<ModelRuntimeEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let spState = mapperSignposter.beginInterval(
                    "generation",
                    id: mapperSignposter.makeSignpostID()
                )
                let t0 = CFAbsoluteTimeGetCurrent()
                var tokenCount = 0
                var firstChunk = true

                // Stop-sequence state: keep a small tail buffer so a stop
                // match split across two `.chunk` boundaries is still
                // caught. The buffer never exceeds 2 × max stop length.
                let maxStopLen = stopSequences.map(\.count).max() ?? 0
                let shouldCheckStop = !stopSequences.isEmpty
                var stopBuffer = ""

                for await event in events {
                    if Task.isCancelled { break }
                    switch event {
                    case .chunk(let text):
                        if firstChunk {
                            firstChunk = false
                            InferenceProgressManager.shared.prefillDidFinishAsync()
                        }
                        guard !text.isEmpty else { continue }

                        if shouldCheckStop {
                            stopBuffer += text
                            // Look for a stop sequence in the combined
                            // buffer. On hit, emit everything up to the
                            // match and cancel upstream generation.
                            if let hit = stopSequences.compactMap({ s -> Range<String.Index>? in
                                stopBuffer.range(of: s)
                            }).min(by: { $0.lowerBound < $1.lowerBound }) {
                                let prefix = String(stopBuffer[..<hit.lowerBound])
                                if !prefix.isEmpty {
                                    continuation.yield(.tokens(prefix))
                                }
                                generationTask?.cancel()
                                stopBuffer = ""
                                // Fall through — the `for` loop will exit
                                // when the upstream stream finishes after
                                // cancellation.
                                continue
                            }

                            // No hit. Emit everything except the trailing
                            // `maxStopLen - 1` characters — that's the
                            // largest possible split-stop tail. Trim the
                            // buffer accordingly.
                            let safeTailKeep = max(0, maxStopLen - 1)
                            if stopBuffer.count > safeTailKeep {
                                let safeEnd = stopBuffer.count - safeTailKeep
                                let cut = stopBuffer.index(stopBuffer.startIndex, offsetBy: safeEnd)
                                let toEmit = String(stopBuffer[..<cut])
                                stopBuffer = String(stopBuffer[cut...])
                                if !toEmit.isEmpty {
                                    continuation.yield(.tokens(toEmit))
                                }
                            }
                        } else {
                            continuation.yield(.tokens(text))
                        }

                    case .toolCall(let call):
                        let argsJSON = serializeArguments(
                            call.function.arguments,
                            toolName: call.function.name
                        )
                        continuation.yield(
                            .toolInvocation(name: call.function.name, argsJSON: argsJSON)
                        )

                    case .info(let info):
                        // Final event: log perf line, signpost stats, and
                        // emit completionInfo so callers can populate the
                        // OpenAI-style `usage` block.
                        tokenCount = info.generationTokenCount
                        mapperLog.info(
                            "[perf] mlxStats promptTokens=\(info.promptTokenCount, privacy: .public) promptTps=\(info.promptTokensPerSecond, privacy: .public) promptMs=\(Int(info.promptTime * 1000), privacy: .public) genTokens=\(info.generationTokenCount, privacy: .public) genTps=\(info.tokensPerSecond, privacy: .public) genMs=\(Int(info.generateTime * 1000), privacy: .public)"
                        )
                        mapperSignposter.emitEvent(
                            "mlxStats",
                            id: .exclusive,
                            "prompt: \(info.promptTokenCount, privacy: .public) tok \(info.promptTokensPerSecond, privacy: .public) tok/s | gen: \(info.generationTokenCount, privacy: .public) tok \(info.tokensPerSecond, privacy: .public) tok/s"
                        )
                        continuation.yield(
                            .completionInfo(
                                tokenCount: info.generationTokenCount,
                                tokensPerSecond: info.tokensPerSecond
                            )
                        )

                    @unknown default:
                        // Forward-compat: when vmlx adds new `Generation`
                        // cases (e.g. `.reasoning(String)`), translate them
                        // here. Unknown cases are skipped so a library
                        // bump cannot leak raw markers to the UI.
                        continue
                    }
                }

                // Flush any remaining stop-buffer tail on natural EOS.
                if shouldCheckStop && !stopBuffer.isEmpty {
                    continuation.yield(.tokens(stopBuffer))
                }

                let durationMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                mapperSignposter.endInterval(
                    "generation",
                    spState,
                    "\(tokenCount, privacy: .public) tokens"
                )
                mapperLog.info(
                    "[perf] generation durationMs=\(durationMs, privacy: .public) tokenCount=\(tokenCount, privacy: .public)"
                )
                InferenceProgressManager.shared.prefillDidFinishAsync()
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - Argument serialisation

    /// Convert vmlx's `[String: JSONValue]` argument map to a compact JSON
    /// string suitable for `ModelRuntimeEvent.toolInvocation(argsJSON:)`.
    /// On serialization failure, returns a structured error envelope so the
    /// model and the executor both see something they can react to instead
    /// of silently swallowing the argument set.
    private static func serializeArguments(
        _ arguments: [String: MLXLMCommon.JSONValue],
        toolName: String
    ) -> String {
        let anyDict = arguments.mapValues { $0.anyValue }
        do {
            let data = try JSONSerialization.data(withJSONObject: anyDict)
            if let json = String(data: data, encoding: .utf8) {
                return json
            }
            mapperLog.error(
                "[tools] arguments for \(toolName, privacy: .public) serialised to non-UTF8 data"
            )
        } catch {
            mapperLog.error(
                "[tools] failed to serialise arguments for \(toolName, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
        return "{\"_error\":\"argument_serialization_failed\",\"_tool\":\"\(toolName)\"}"
    }
}
