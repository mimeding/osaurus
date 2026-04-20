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
                let interval = mapperSignposter.beginInterval(
                    "generation",
                    id: mapperSignposter.makeSignpostID()
                )
                let startedAt = CFAbsoluteTimeGetCurrent()
                var stopBuffer = StopSequenceBuffer(stopSequences: stopSequences)
                var firstChunk = true
                var finalTokenCount = 0

                for await event in events {
                    if Task.isCancelled { break }
                    switch event {
                    case .chunk(let text):
                        if firstChunk {
                            firstChunk = false
                            InferenceProgressManager.shared.prefillDidFinishAsync()
                        }
                        guard !text.isEmpty else { continue }
                        let outcome = stopBuffer.feed(text)
                        if let prefix = outcome.emit, !prefix.isEmpty {
                            continuation.yield(.tokens(prefix))
                        }
                        if outcome.stopHit {
                            generationTask?.cancel()
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
                        finalTokenCount = info.generationTokenCount
                        logCompletionInfo(info)
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
                if let tail = stopBuffer.flush(), !tail.isEmpty {
                    continuation.yield(.tokens(tail))
                }

                let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
                mapperSignposter.endInterval(
                    "generation",
                    interval,
                    "\(finalTokenCount, privacy: .public) tokens"
                )
                mapperLog.info(
                    "[perf] generation durationMs=\(durationMs, privacy: .public) tokenCount=\(finalTokenCount, privacy: .public)"
                )
                InferenceProgressManager.shared.prefillDidFinishAsync()
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - Helpers

    /// One log line + one signpost event per completion. Pulled out of
    /// `map` so the per-event switch reads as the wire-format translation
    /// it actually is.
    private static func logCompletionInfo(_ info: GenerateCompletionInfo) {
        mapperLog.info(
            "[perf] mlxStats promptTokens=\(info.promptTokenCount, privacy: .public) promptTps=\(info.promptTokensPerSecond, privacy: .public) promptMs=\(Int(info.promptTime * 1000), privacy: .public) genTokens=\(info.generationTokenCount, privacy: .public) genTps=\(info.tokensPerSecond, privacy: .public) genMs=\(Int(info.generateTime * 1000), privacy: .public)"
        )
        mapperSignposter.emitEvent(
            "mlxStats",
            id: .exclusive,
            "prompt: \(info.promptTokenCount, privacy: .public) tok \(info.promptTokensPerSecond, privacy: .public) tok/s | gen: \(info.generationTokenCount, privacy: .public) tok \(info.tokensPerSecond, privacy: .public) tok/s"
        )
    }

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
        // Pre-validate the dictionary: `JSONSerialization.data(...)` raises
        // an Objective-C `NSException` (not a Swift `Error`) when given
        // non-finite Doubles, NaN, or other invalid values — Swift `catch`
        // cannot intercept it and the process aborts. Checking
        // `isValidJSONObject` first ensures we always exit through the
        // structured envelope path instead of crashing the runtime.
        guard JSONSerialization.isValidJSONObject(anyDict) else {
            mapperLog.error(
                "[tools] arguments for \(toolName, privacy: .public) failed JSON validation (non-finite number, unsupported type, or non-string key)"
            )
            return errorEnvelope(toolName: toolName)
        }
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
        return errorEnvelope(toolName: toolName)
    }

    /// Structured error envelope returned by `serializeArguments` on every
    /// failure path. Wire shape is intentionally a valid JSON object so MCP
    /// (and any other downstream tool runner) can detect the failure by
    /// looking for the `_error` field — `MCPProviderTool` already does so.
    private static func errorEnvelope(toolName: String) -> String {
        "{\"_error\":\"argument_serialization_failed\",\"_tool\":\"\(toolName)\"}"
    }
}

// MARK: - StopSequenceBuffer

/// Sliding text buffer that catches stop sequences split across chunk
/// boundaries from `BatchEngine.generate`'s `.chunk(String)` events.
///
/// Owns three pieces of state:
///   - `stopSequences` — strings that terminate generation
///   - `maxKeep` — `max(stop length) - 1`, the largest possible split tail
///   - `buffer` — the held-back tail, never longer than `maxKeep` between
///                emissions, never longer than `maxKeep + last chunk` during
///                a single `feed(_:)` call
///
/// All methods are `O(buffer + chunk)` — the search runs over the combined
/// buffer plus the new chunk, and emissions splice off the safe prefix.
private struct StopSequenceBuffer {
    let stopSequences: [String]
    private let maxKeep: Int
    private let isActive: Bool
    private var buffer: String = ""

    init(stopSequences: [String]) {
        self.stopSequences = stopSequences
        self.maxKeep = max(0, (stopSequences.map(\.count).max() ?? 0) - 1)
        self.isActive = !stopSequences.isEmpty
    }

    struct Outcome {
        /// Text safe to forward downstream as a `.tokens(...)` event. May
        /// be `nil` when the chunk is entirely held back as a possible
        /// stop-sequence prefix.
        let emit: String?
        /// True when a stop sequence matched in the combined buffer. The
        /// caller should cancel the upstream producer task; the buffer
        /// has already been cleared.
        let stopHit: Bool
    }

    /// Feed one upstream `.chunk(_:)` text payload. Returns the prefix to
    /// emit (if any) and whether a stop sequence matched.
    mutating func feed(_ text: String) -> Outcome {
        guard isActive else { return Outcome(emit: text, stopHit: false) }

        buffer += text

        if let hit = firstStopMatch() {
            let prefix = String(buffer[..<hit.lowerBound])
            buffer = ""
            return Outcome(emit: prefix.isEmpty ? nil : prefix, stopHit: true)
        }

        // No hit. Emit everything except the trailing `maxKeep` characters
        // (the largest possible split-stop tail), and trim the buffer.
        guard buffer.count > maxKeep else { return Outcome(emit: nil, stopHit: false) }
        let safeEnd = buffer.count - maxKeep
        let cut = buffer.index(buffer.startIndex, offsetBy: safeEnd)
        let toEmit = String(buffer[..<cut])
        buffer = String(buffer[cut...])
        return Outcome(emit: toEmit.isEmpty ? nil : toEmit, stopHit: false)
    }

    /// Drain whatever is still in the buffer at natural end-of-stream.
    mutating func flush() -> String? {
        guard isActive, !buffer.isEmpty else { return nil }
        defer { buffer = "" }
        return buffer
    }

    private func firstStopMatch() -> Range<String.Index>? {
        stopSequences
            .compactMap { buffer.range(of: $0) }
            .min(by: { $0.lowerBound < $1.lowerBound })
    }
}
