//
//  GenerationEventMapperTests.swift
//  osaurusTests
//
//  Tests for `GenerationEventMapper` — translates vmlx-swift-lm `Generation`
//  events into osaurus `ModelRuntimeEvent`. Tool-call parsing and reasoning
//  stripping are owned by vmlx; these tests only exercise the bridge.
//

import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

@Suite("GenerationEventMapper bridge behaviour")
struct GenerationEventMapperTests {

    private func makeStream(_ events: [Generation]) -> AsyncStream<Generation> {
        AsyncStream { continuation in
            for ev in events { continuation.yield(ev) }
            continuation.finish()
        }
    }

    private func collect(
        events: [Generation],
        stopSequences: [String] = []
    ) async throws -> [ModelRuntimeEvent] {
        let stream = makeStream(events)
        let mapped = GenerationEventMapper.map(
            events: stream,
            stopSequences: stopSequences,
            generationTask: nil
        )
        var out: [ModelRuntimeEvent] = []
        for try await ev in mapped { out.append(ev) }
        return out
    }

    @Test func chunk_passes_through_as_tokens() async throws {
        let events: [Generation] = [
            .chunk("Hello, "),
            .chunk("world!"),
        ]
        let out = try await collect(events: events)
        var assembled = ""
        for ev in out {
            if case .tokens(let s) = ev { assembled += s }
        }
        #expect(assembled == "Hello, world!")
    }

    @Test func toolCall_emits_serialized_arguments() async throws {
        let args: [String: MLXLMCommon.JSONValue] = [
            "q": .string("hi"),
            "n": .int(3),
        ]
        let call = MLXLMCommon.ToolCall(
            function: MLXLMCommon.ToolCall.Function(
                name: "lookup",
                arguments: args
            )
        )
        let events: [Generation] = [.toolCall(call)]
        let out = try await collect(events: events)
        guard case .toolInvocation(let name, let argsJSON) = out.first else {
            Issue.record("expected toolInvocation, got \(String(describing: out.first))")
            return
        }
        #expect(name == "lookup")
        // JSON is unordered; assert by parsing back.
        let parsed = try JSONSerialization.jsonObject(with: Data(argsJSON.utf8)) as? [String: Any]
        #expect(parsed?["q"] as? String == "hi")
        #expect((parsed?["n"] as? Int) == 3 || (parsed?["n"] as? Double) == 3.0)
    }

    @Test func info_emits_completionInfo() async throws {
        let info = GenerateCompletionInfo(
            promptTokenCount: 12,
            generationTokenCount: 8,
            promptTime: 0.1,
            generationTime: 0.2
        )
        let events: [Generation] = [.chunk("ok"), .info(info)]
        let out = try await collect(events: events)
        guard case .completionInfo(let count, let tps) = out.last else {
            Issue.record("expected completionInfo at end, got \(String(describing: out.last))")
            return
        }
        #expect(count == 8)
        #expect(tps > 0)
    }

    @Test func stop_sequence_truncates_chunk_emission() async throws {
        // The stop string straddles two chunks: " STOP" → "S" + "TOP" — the
        // mapper must hold back the trailing characters of the first chunk
        // so the cross-chunk match is still detected.
        let events: [Generation] = [
            .chunk("hello S"),
            .chunk("TOP rest"),
        ]
        let out = try await collect(events: events, stopSequences: ["STOP"])
        var assembled = ""
        for ev in out {
            if case .tokens(let s) = ev { assembled += s }
        }
        #expect(assembled == "hello ")
    }

    @Test func empty_chunks_are_ignored() async throws {
        let events: [Generation] = [.chunk(""), .chunk("text"), .chunk("")]
        let out = try await collect(events: events)
        let texts: [String] = out.compactMap {
            if case .tokens(let s) = $0 { return s } else { return nil }
        }
        #expect(texts == ["text"])
    }
}
