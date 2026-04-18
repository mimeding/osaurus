//
//  InferenceEventAdapterTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct InferenceEventAdapterTests {

    @Test func event_mapping_preserves_text_and_decodes_control_metadata() {
        #expect(InferenceEventAdapter.event(for: "plain text") == .textDelta("plain text"))
        #expect(
            InferenceEventAdapter.event(for: StreamingToolHint.encode("read_file"))
                == .toolCallStarted(name: "read_file")
        )
        #expect(
            InferenceEventAdapter.event(for: StreamingToolHint.encodeArgs("{\"path\":\"README.md\"}"))
                == .toolCallArgumentsDelta("{\"path\":\"README.md\"}")
        )
        #expect(
            InferenceEventAdapter.event(for: StreamingStatsHint.encode(tokenCount: 12, tokensPerSecond: 34.5))
                == .stats(InferenceStatsRecord(tokenCount: 12, tokensPerSecond: 34.5))
        )
    }

    @Test func adapt_emits_authoritative_tool_request_from_thrown_invocation() async throws {
        let plainArtifactMarker = #"---SHARED_ARTIFACT_START---{"filename":"report.md"}---SHARED_ARTIFACT_END---"#
        let stream = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield(StreamingToolHint.encode("share_artifact"))
            continuation.yield(StreamingToolHint.encodeArgs(#"{"filename":"report.md"}"#))
            continuation.yield(plainArtifactMarker)
            continuation.finish(
                throwing: ServiceToolInvocation(
                    toolName: "share_artifact",
                    jsonArguments: #"{"filename":"report.md"}"#,
                    toolCallId: "call_share_123"
                )
            )
        }

        let events = InferenceEventAdapter.adapt(stream)
        var received: [InferenceEvent] = []
        for try await event in events {
            received.append(event)
        }

        #expect(
            received == [
                .toolCallStarted(name: "share_artifact"),
                .toolCallArgumentsDelta(#"{"filename":"report.md"}"#),
                .textDelta(plainArtifactMarker),
                .toolCallRequested(
                    InferenceToolCallRecord(
                        name: "share_artifact",
                        argumentsJSON: #"{"filename":"report.md"}"#,
                        toolCallId: "call_share_123"
                    )
                ),
            ]
        )
    }

    @Test func adapt_treats_plain_text_tool_and_artifact_markers_as_text_only() async throws {
        let rawChunks = [
            #"{"tool_calls":[{"name":"read_file","arguments":"{}"}]}"#,
            "---SHARED_ARTIFACT_START---demo---SHARED_ARTIFACT_END---",
            "tool:read_file args:{}",
        ]
        let stream = AsyncThrowingStream<String, Error> { continuation in
            for chunk in rawChunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }

        let events = InferenceEventAdapter.adapt(stream)
        var received: [InferenceEvent] = []
        for try await event in events {
            received.append(event)
        }

        #expect(received == rawChunks.map(InferenceEvent.textDelta))
        #expect(!received.contains {
            if case .toolCallRequested = $0 { return true }
            return false
        })
    }

    @Test func streamInferenceEvents_adapts_immediate_tool_throw() async throws {
        struct ImmediateToolThrowEngine: ChatEngineProtocol {
            func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
                throw ServiceToolInvocation(
                    toolName: "noop_test",
                    jsonArguments: "{}",
                    toolCallId: "call_immediate_1"
                )
            }

            func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
                fatalError("not used")
            }
        }

        let request = ChatCompletionRequest(
            model: "mock",
            messages: [ChatMessage(role: "user", content: "hi")],
            temperature: nil,
            max_tokens: nil,
            stream: true,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: nil,
            tool_choice: nil,
            session_id: nil
        )

        let stream = try await ImmediateToolThrowEngine().streamInferenceEvents(request: request)
        var received: [InferenceEvent] = []
        for try await event in stream {
            received.append(event)
        }

        #expect(
            received == [
                .toolCallRequested(
                    InferenceToolCallRecord(
                        name: "noop_test",
                        argumentsJSON: "{}",
                        toolCallId: "call_immediate_1"
                    )
                )
            ]
        )
    }
}
