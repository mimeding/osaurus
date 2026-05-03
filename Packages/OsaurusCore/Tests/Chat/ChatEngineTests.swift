//
//  ChatEngineTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct ChatEngineTests {

    @Test func streamChat_yields_deltas_success() async throws {
        let svc = FakeModelService(deltas: ["a", "b", "c"])
        let engine = ChatEngine(services: [svc], installedModelsProvider: { [] })
        let req = ChatCompletionRequest(
            model: "fake",
            messages: [ChatMessage(role: "user", content: "hi")],
            temperature: 0.5,
            max_tokens: 16,
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
        let stream = try await engine.streamChat(request: req)
        var out = ""
        for try await d in stream { out += d }
        #expect(out == "abc")
    }

    @Test func streamChat_threads_capability_snapshot_to_service() async throws {
        final class CapturingService: ModelService, @unchecked Sendable {
            private let lock = NSLock()
            private var captured: LLMCapabilitySnapshot?

            var id: String { "capturing" }
            func isAvailable() -> Bool { true }
            func handles(requestedModel: String?) -> Bool { requestedModel == "gemma-capture" }

            func generateOneShot(
                messages: [ChatMessage],
                parameters: GenerationParameters,
                requestedModel: String?
            ) async throws -> String {
                capture(parameters.capabilitySnapshot)
                return "ok"
            }

            func streamDeltas(
                messages: [ChatMessage],
                parameters: GenerationParameters,
                requestedModel: String?,
                stopSequences: [String]
            ) async throws -> AsyncThrowingStream<String, Error> {
                capture(parameters.capabilitySnapshot)
                return AsyncThrowingStream { continuation in
                    continuation.yield("ok")
                    continuation.finish()
                }
            }

            func snapshot() -> LLMCapabilitySnapshot? {
                lock.lock()
                defer { lock.unlock() }
                return captured
            }

            private func capture(_ snapshot: LLMCapabilitySnapshot?) {
                lock.lock()
                captured = snapshot
                lock.unlock()
            }
        }

        let svc = CapturingService()
        let engine = ChatEngine(services: [svc], installedModelsProvider: { [] })
        let req = ChatCompletionRequest(
            model: "gemma-capture",
            messages: [ChatMessage(role: "user", content: "hi")],
            temperature: 0.5,
            max_tokens: 16,
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

        let stream = try await engine.streamChat(request: req)
        for try await _ in stream {}

        let snapshot = try #require(svc.snapshot())
        #expect(snapshot.modelId == "gemma-capture")
        #expect(snapshot.family == .googleGemma)
        #expect(snapshot.runtimeKind == .unknown)
        #expect(snapshot.toolCallMode == .none)
    }

    @Test func completeChat_returns_choice_success() async throws {
        let svc = FakeModelService()
        let engine = ChatEngine(services: [svc], installedModelsProvider: { [] })
        let req = ChatCompletionRequest(
            model: "fake",
            messages: [ChatMessage(role: "user", content: "hi")],
            temperature: 0.5,
            max_tokens: 32,
            stream: false,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: nil,
            tool_choice: nil,
            session_id: nil
        )
        let resp = try await engine.completeChat(request: req)
        #expect(resp.id.hasPrefix("chatcmpl-"))
        #expect(resp.model == "fake")
        #expect(resp.choices.count == 1)
        #expect(resp.choices.first?.finish_reason == "stop")
        #expect(resp.choices.first?.message.content == "hello")
    }

    @Test func completeChat_returns_tool_calls_when_tool_invoked() async throws {
        // Tool-capable fake that throws ServiceToolInvocation when tools are present
        struct FakeToolService: ToolCapableService {
            var id: String { "fake" }
            func isAvailable() -> Bool { true }
            func handles(requestedModel: String?) -> Bool { (requestedModel ?? "") == "fake" }
            func streamDeltas(
                messages: [ChatMessage],
                parameters: GenerationParameters,
                requestedModel: String?,
                stopSequences: [String]
            ) async throws -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
            func generateOneShot(
                messages: [ChatMessage],
                parameters: GenerationParameters,
                requestedModel: String?
            ) async throws -> String { "" }
            func respondWithTools(
                messages: [ChatMessage],
                parameters: GenerationParameters,
                stopSequences: [String],
                tools: [Tool],
                toolChoice: ToolChoiceOption?,
                requestedModel: String?
            ) async throws -> String {
                throw ServiceToolInvocation(toolName: "get_weather", jsonArguments: "{\"city\":\"SF\"}")
            }
            func streamWithTools(
                messages: [ChatMessage],
                parameters: GenerationParameters,
                stopSequences: [String],
                tools: [Tool],
                toolChoice: ToolChoiceOption?,
                requestedModel: String?
            ) async throws -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
        }

        let engine = ChatEngine(services: [FakeToolService()], installedModelsProvider: { [] })
        let req = ChatCompletionRequest(
            model: "fake",
            messages: [ChatMessage(role: "user", content: "hi")],
            temperature: 0.5,
            max_tokens: 16,
            stream: false,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: [
                Tool(
                    type: "function",
                    function: ToolFunction(name: "get_weather", description: nil, parameters: .object([:]))
                )
            ],
            tool_choice: .auto,
            session_id: nil
        )
        let resp = try await engine.completeChat(request: req)
        #expect(resp.choices.first?.finish_reason == "tool_calls")
        let toolCalls = resp.choices.first?.message.tool_calls
        #expect(toolCalls?.first?.function.name == "get_weather")
        let id = toolCalls?.first?.id ?? ""
        #expect(id.hasPrefix("call_"))
    }

    @Test func streamChat_throws_when_no_route() async throws {
        let engine = ChatEngine(services: [], installedModelsProvider: { [] })
        let req = ChatCompletionRequest(
            model: "unknown",
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
        var threw = false
        do { _ = try await engine.streamChat(request: req) } catch { threw = true }
        #expect(threw)
    }

    @Test func completeChat_throws_when_no_route() async throws {
        let engine = ChatEngine(services: [], installedModelsProvider: { [] })
        let req = ChatCompletionRequest(
            model: "unknown",
            messages: [ChatMessage(role: "user", content: "hi")],
            temperature: nil,
            max_tokens: nil,
            stream: false,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: nil,
            tool_choice: nil,
            session_id: nil
        )
        var threw = false
        do { _ = try await engine.completeChat(request: req) } catch { threw = true }
        #expect(threw)
    }

    @Test func streamChat_throws_when_service_not_throwing_streaming() async throws {
        let svc = FakeModelService()
        let engine = ChatEngine(services: [svc], installedModelsProvider: { [] })
        let req = ChatCompletionRequest(
            model: "plain",
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
        var threw = false
        do { _ = try await engine.streamChat(request: req) } catch { threw = true }
        #expect(threw)
    }
}
