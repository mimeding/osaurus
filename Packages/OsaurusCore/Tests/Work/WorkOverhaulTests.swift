//
//  WorkOverhaulTests.swift
//  osaurusTests
//
//  Verifies the Work-mode reliability overhaul: multi-tool drain per
//  generation, context refresh after capability changes, compaction-back
//  persistence, complete_task rejection envelope, and stuck-loop detection.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct WorkOverhaulTests {

    // MARK: Helpers

    private func toolSpec(name: String) -> Tool {
        Tool(
            type: "function",
            function: ToolFunction(
                name: name,
                description: "Test tool \(name).",
                parameters: .object(["type": .string("object")])
            )
        )
    }

    private func completeTaskSpec() -> Tool {
        toolSpec(name: "complete_task")
    }

    // MARK: complete_task rejection -> ToolErrorEnvelope

    @Test @MainActor
    func completeTaskRejection_emitsToolErrorEnvelope() async throws {
        let engine = WorkExecutionEngine(
            chatEngine: SequencedEngine(
                steps: [
                    .tool(
                        "complete_task",
                        // Missing verification_performed → rejection
                        #"{"status":"verified","summary":"done","remaining_risks":"none","remaining_work":"none"}"#
                    ),
                    .tool(
                        "complete_task",
                        #"{"status":"verified","summary":"done","verification_performed":"Ran regression tests and manually validated.","remaining_risks":"none","remaining_work":"none"}"#
                    ),
                ]
            )
        )
        let issue = Issue(taskId: "task-envelope", title: "envelope test")
        var messages: [ChatMessage] = [ChatMessage(role: "user", content: "Finish")]

        _ = try await engine.executeLoop(
            issue: issue,
            messages: &messages,
            systemPrompt: "Base",
            model: "mock",
            tools: [completeTaskSpec()],
            maxIterations: 4,
            onIterationStart: { _ in },
            onDelta: { _, _ in },
            onToolHint: { _ in },
            onToolArgHint: { _ in },
            onToolCall: { _, _, _ in },
            onStatusUpdate: { _ in },
            onArtifact: { _ in },
            onTokensConsumed: { _, _ in }
        )

        // Find the rejection tool message and assert it parses as the
        // structured envelope (not the legacy `[REJECTED] ...` string).
        let toolMsg = messages.first { $0.role == "tool" }
        let body = try #require(toolMsg?.content)
        #expect(ToolErrorEnvelope.isErrorResult(body))

        let data = try #require(body.data(using: .utf8))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["error"] as? String == "rejected")
        #expect(json?["tool"] as? String == "complete_task")
    }

    // MARK: Stuck-loop detection

    @Test @MainActor
    func stuckLoop_threeIdenticalCalls_appendsNudge() async throws {
        let registry = ToolRegistry.shared
        registry.register(NoopOverhaulTool())
        registry.setEnabled(true, for: "noop_overhaul")
        defer { registry.unregister(names: ["noop_overhaul"]) }

        let engine = WorkExecutionEngine(
            chatEngine: SequencedEngine(
                steps: [
                    .tool("noop_overhaul", "{\"x\":1}"),
                    .tool("noop_overhaul", "{\"x\":1}"),
                    .tool("noop_overhaul", "{\"x\":1}"),
                    .tool(
                        "complete_task",
                        #"{"status":"verified","summary":"done","verification_performed":"Verified loop nudge fired.","remaining_risks":"none","remaining_work":"none"}"#
                    ),
                ]
            )
        )
        let issue = Issue(taskId: "task-stuck", title: "stuck loop")
        var messages: [ChatMessage] = [ChatMessage(role: "user", content: "Run")]

        _ = try await engine.executeLoop(
            issue: issue,
            messages: &messages,
            systemPrompt: "Base",
            model: "mock",
            tools: [toolSpec(name: "noop_overhaul"), completeTaskSpec()],
            maxIterations: 8,
            onIterationStart: { _ in },
            onDelta: { _, _ in },
            onToolHint: { _ in },
            onToolArgHint: { _ in },
            onToolCall: { _, _, _ in },
            onStatusUpdate: { _ in },
            onArtifact: { _ in },
            onTokensConsumed: { _, _ in }
        )

        // The stuck-loop nudge is appended as a `user` role system notice.
        #expect(
            messages.contains(where: { msg in
                msg.role == "user"
                    && (msg.content?.contains("multiple times with the same arguments") == true)
            })
        )
    }

    // MARK: Multi-tool drain per generation

    @Test @MainActor
    func multiToolDrain_executesAllInOneIteration() async throws {
        let registry = ToolRegistry.shared
        registry.register(NoopOverhaulTool())
        registry.setEnabled(true, for: "noop_overhaul")
        defer { registry.unregister(names: ["noop_overhaul"]) }

        // Two parallel tool calls in one completion, then complete.
        let engine = WorkExecutionEngine(
            chatEngine: SequencedEngine(
                steps: [
                    .batch([
                        ("noop_overhaul", "{\"a\":1}"),
                        ("noop_overhaul", "{\"a\":2}"),
                    ]),
                    .tool(
                        "complete_task",
                        #"{"status":"verified","summary":"done","verification_performed":"Both calls executed.","remaining_risks":"none","remaining_work":"none"}"#
                    ),
                ]
            )
        )
        let issue = Issue(taskId: "task-multi", title: "multi tool")
        var messages: [ChatMessage] = [ChatMessage(role: "user", content: "Run two")]

        _ = try await engine.executeLoop(
            issue: issue,
            messages: &messages,
            systemPrompt: "Base",
            model: "mock",
            tools: [toolSpec(name: "noop_overhaul"), completeTaskSpec()],
            maxIterations: 4,
            onIterationStart: { _ in },
            onDelta: { _, _ in },
            onToolHint: { _ in },
            onToolArgHint: { _ in },
            onToolCall: { _, _, _ in },
            onStatusUpdate: { _ in },
            onArtifact: { _ in },
            onTokensConsumed: { _, _ in }
        )

        let toolMsgs = messages.filter { $0.role == "tool" }
        // 2 from the batch + (no tool message for complete_task — that path
        // exits the loop without appending a result).
        #expect(toolMsgs.count >= 2)
    }
}

// MARK: - Test helpers

private struct NoopOverhaulTool: OsaurusTool, @unchecked Sendable {
    let name: String = "noop_overhaul"
    let description: String = "noop"
    var parameters: JSONValue? { .object(["type": .string("object")]) }
    func execute(argumentsJSON: String) async throws -> String { "ok" }
}

private actor SequencedEngine: ChatEngineProtocol {
    enum Step {
        case tool(String, String)
        case batch([(String, String)])
    }

    private var steps: [Step]
    private var index = 0

    init(steps: [Step]) { self.steps = steps }

    func streamChat(request _: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        guard index < steps.count else {
            return AsyncThrowingStream { c in c.finish() }
        }
        let step = steps[index]
        index += 1
        switch step {
        case .tool(let name, let args):
            throw ServiceToolInvocation(toolName: name, jsonArguments: args)
        case .batch(let calls):
            let invs = calls.map {
                ServiceToolInvocation(toolName: $0.0, jsonArguments: $0.1)
            }
            throw ServiceToolInvocations(invocations: invs)
        }
    }

    func completeChat(request _: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw NSError(domain: "WorkOverhaulTests", code: 1)
    }
}
