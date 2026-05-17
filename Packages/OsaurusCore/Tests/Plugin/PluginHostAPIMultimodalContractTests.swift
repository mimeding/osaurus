//
//  PluginHostAPIMultimodalContractTests.swift
//  OsaurusCoreTests
//
//  Contract tests for T-M1: plugin host `complete` and `complete_stream`
//  must preserve OpenAI-compatible multimodal/message fields until the chat
//  engine receives the request. The host may enrich system/tool context, but
//  it must not flatten user media or drop assistant reasoning/tool history.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Plugin host multimodal contract", .serialized)
struct PluginHostAPIMultimodalContractTests {
    fileprivate static let imageBase64 = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
    fileprivate static let audioBase64 = Data([0x52, 0x49, 0x46, 0x46]).base64EncodedString()
    fileprivate static let videoBase64 = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70])
        .base64EncodedString()
    fileprivate static let reasoning = "private reasoning stays on reasoning_content"
    fileprivate static let authSecret = "sk-tm1-secret"

    @Test("complete preserves multimodal parts, reasoning, and tool_calls")
    func completePreservesOpenAICompatibleMessageShape() throws {
        let engine = CapturingHostAPIChatEngine()
        let ctx = try PluginHostContext(
            pluginId: "com.test.tm1.complete.\(UUID().uuidString)",
            chatEngineFactory: { engine }
        )
        defer { ctx.teardown() }

        let result = Self.runOffMain {
            ctx.complete(requestJSON: Self.multimodalRequestJSON())
        }

        let captured = try #require(engine.completeRequests.first)
        Self.expectMultimodalContract(captured)
        Self.expectRedactedInferenceError(result)
    }

    @Test("complete_stream preserves multimodal parts, reasoning, and tool_calls")
    func completeStreamPreservesOpenAICompatibleMessageShape() throws {
        let engine = CapturingHostAPIChatEngine()
        let ctx = try PluginHostContext(
            pluginId: "com.test.tm1.stream.\(UUID().uuidString)",
            chatEngineFactory: { engine }
        )
        defer { ctx.teardown() }
        let chunks = ChunkCollector()

        let result = Self.runOffMain {
            ctx.completeStream(
                requestJSON: Self.multimodalRequestJSON(streamId: "tm1-stream"),
                onChunk: Self.collectChunk,
                userData: Unmanaged.passUnretained(chunks).toOpaque()
            )
        }

        let captured = try #require(engine.streamRequests.first)
        Self.expectMultimodalContract(captured)
        #expect(chunks.values.isEmpty)
        Self.expectRedactedInferenceError(result)
    }

    @Test("plugin log redaction removes media and auth payloads")
    func pluginLogRedactionRemovesMediaAndAuthPayloads() {
        let body = """
            {
              "headers": {
                "Authorization": "Bearer \(Self.authSecret)",
                "x-api-key": "plugin-api-key"
              },
              "messages": [
                {
                  "role": "user",
                  "content": [
                    {
                      "type": "image_url",
                      "image_url": {"url": "data:image/png;base64,\(Self.imageBase64)"}
                    },
                    {
                      "type": "input_audio",
                      "input_audio": {"data": "\(Self.audioBase64)", "format": "wav"}
                    },
                    {
                      "type": "video_url",
                      "video_url": {
                        "url": "https://media.example/clip.mp4?X-Amz-Signature=video-signature&ok=1"
                      }
                    }
                  ]
                }
              ]
            }
            """

        guard let redacted = PluginHostContext.redactPluginLogBody(body) else {
            Issue.record("plugin log body should remain valid JSON after redaction")
            return
        }
        #expect(!redacted.contains(Self.authSecret))
        #expect(!redacted.contains("plugin-api-key"))
        #expect(!redacted.contains(Self.imageBase64))
        #expect(!redacted.contains(Self.audioBase64))
        #expect(!redacted.contains("video-signature"))
        #expect(redacted.contains("[redacted]"))
        #expect(redacted.contains("[redacted-media]"))
    }

    private static func multimodalRequestJSON(streamId: String? = nil) -> String {
        let streamIdLine = streamId.map { #""stream_id": "\#($0)","# } ?? ""
        return """
            {
              "model": "tm1-probe",
              "session_id": "tm1-session",
              \(streamIdLine)
              "max_iterations": 1,
              "messages": [
                {
                  "role": "user",
                  "content": [
                    {"type": "text", "text": "Describe this media."},
                    {
                      "type": "image_url",
                      "image_url": {"url": "data:image/png;base64,\(imageBase64)", "detail": "high"}
                    },
                    {"type": "input_audio", "input_audio": {"data": "\(audioBase64)", "format": "wav"}},
                    {"type": "video_url", "video_url": {"url": "data:video/mp4;base64,\(videoBase64)"}}
                  ]
                },
                {
                  "role": "assistant",
                  "content": "I need a tool.",
                  "reasoning_content": "\(reasoning)",
                  "tool_calls": [
                    {
                      "id": "call_weather",
                      "type": "function",
                      "function": {"name": "weather_lookup", "arguments": "{\\"city\\":\\"SF\\"}"}
                    }
                  ]
                },
                {"role": "tool", "tool_call_id": "call_weather", "content": "{\\"temp\\":72}"}
              ]
            }
            """
    }

    private static func expectMultimodalContract(_ request: ChatCompletionRequest) {
        #expect(request.model == "tm1-probe")
        #expect(request.session_id == "tm1-session")

        guard let user = request.messages.first(where: { $0.role == "user" }) else {
            Issue.record("captured request should include the user message")
            return
        }
        guard let parts = user.contentParts else {
            Issue.record("user content should remain structured content parts")
            return
        }
        #expect(parts.count == 4)
        if parts.count == 4 {
            if case .text(let text) = parts[0] {
                #expect(text == "Describe this media.")
            } else {
                Issue.record("content part 0 should stay text")
            }
            if case .imageUrl(let url, let detail) = parts[1] {
                #expect(url == "data:image/png;base64,\(imageBase64)")
                #expect(detail == "high")
            } else {
                Issue.record("content part 1 should stay image_url")
            }
            if case .audioInput(let data, let format) = parts[2] {
                #expect(data == audioBase64)
                #expect(format == "wav")
            } else {
                Issue.record("content part 2 should stay input_audio")
            }
            if case .videoUrl(let url) = parts[3] {
                #expect(url == "data:video/mp4;base64,\(videoBase64)")
            } else {
                Issue.record("content part 3 should stay video_url")
            }
        }

        #expect(user.content == "Describe this media.")
        #expect(user.imageUrls == ["data:image/png;base64,\(imageBase64)"])
        #expect(user.audioInputs.count == 1)
        #expect(user.audioInputs.first?.data == audioBase64)
        #expect(user.audioInputs.first?.format == "wav")
        #expect(user.videoUrls == ["data:video/mp4;base64,\(videoBase64)"])

        guard let assistant = request.messages.first(where: { $0.role == "assistant" }) else {
            Issue.record("captured request should include assistant tool history")
            return
        }
        #expect(assistant.reasoning_content == reasoning)
        let call = assistant.tool_calls?.first
        #expect(call?.id == "call_weather")
        #expect(call?.type == "function")
        #expect(call?.function.name == "weather_lookup")
        #expect(call?.function.arguments == #"{"city":"SF"}"#)

        let tool = request.messages.first(where: { $0.role == "tool" })
        #expect(tool?.tool_call_id == "call_weather")
        #expect(tool?.content == #"{"temp":72}"#)
    }

    private static func expectRedactedInferenceError(_ result: String) {
        #expect(result.contains("inference_error"))
        #expect(!result.contains(authSecret))
        #expect(!result.contains(imageBase64))
        #expect(!result.contains(audioBase64))
        #expect(!result.contains(videoBase64))
        #expect(result.contains("[redacted]"))
    }

    private static let collectChunk: osr_on_chunk_t = { chunkPtr, userData in
        guard let chunkPtr, let userData else { return }
        let collector = Unmanaged<ChunkCollector>.fromOpaque(userData).takeUnretainedValue()
        collector.append(String(cString: chunkPtr))
    }

    private static func runOffMain(_ body: @escaping @Sendable () -> String) -> String {
        let box = LockedValue<String>()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.set(body())
            sem.signal()
        }
        sem.wait()
        return box.value ?? ""
    }
}

private final class CapturingHostAPIChatEngine: ChatEngineProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var completeStorage: [ChatCompletionRequest] = []
    private var streamStorage: [ChatCompletionRequest] = []

    var completeRequests: [ChatCompletionRequest] {
        lock.withLock { completeStorage }
    }

    var streamRequests: [ChatCompletionRequest] {
        lock.withLock { streamStorage }
    }

    func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        lock.withLock { completeStorage.append(request) }
        throw ProbeInferenceError()
    }

    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        lock.withLock { streamStorage.append(request) }
        throw ProbeInferenceError()
    }
}

private struct ProbeInferenceError: LocalizedError, Sendable {
    var errorDescription: String? {
        "probe failed Authorization: Bearer \(PluginHostAPIMultimodalContractTests.authSecret) "
            + "image=data:image/png;base64,\(PluginHostAPIMultimodalContractTests.imageBase64) "
            + "audio=data:audio/wav;base64,\(PluginHostAPIMultimodalContractTests.audioBase64) "
            + "video=data:video/mp4;base64,\(PluginHostAPIMultimodalContractTests.videoBase64)"
    }
}

private final class ChunkCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value?

    var value: Value? {
        lock.withLock { storage }
    }

    func set(_ value: Value) {
        lock.withLock { storage = value }
    }
}
