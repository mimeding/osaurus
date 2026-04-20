//
//  InferenceEvent.swift
//  osaurus
//
//  Typed events that normalize streamed model output and authoritative
//  tool requests behind a single additive contract.
//

import Foundation

/// Shared event contract for incremental harness unification.
///
/// `toolCallStarted` and `toolCallArgumentsDelta` are progressive metadata for
/// UI/display purposes only. Actual tool execution must only occur when a
/// `.toolCallRequested` or `.toolCallsRequested` event is emitted from a thrown
/// `ServiceToolInvocation` or `ServiceToolInvocations`.
enum InferenceEvent: Sendable, Equatable {
    case textDelta(String)
    case toolCallStarted(name: String)
    case toolCallArgumentsDelta(String)
    case stats(InferenceStatsRecord)
    case toolCallRequested(InferenceToolCallRecord)
    case toolCallsRequested([InferenceToolCallRecord])
}

struct InferenceStatsRecord: Sendable, Equatable {
    let tokenCount: Int
    let tokensPerSecond: Double
}

struct InferenceToolCallRecord: Sendable, Equatable {
    let name: String
    let argumentsJSON: String
    let toolCallId: String?
    let geminiThoughtSignature: String?

    init(
        name: String,
        argumentsJSON: String,
        toolCallId: String? = nil,
        geminiThoughtSignature: String? = nil
    ) {
        self.name = name
        self.argumentsJSON = argumentsJSON
        self.toolCallId = toolCallId
        self.geminiThoughtSignature = geminiThoughtSignature
    }

    init(invocation: ServiceToolInvocation) {
        self.init(
            name: invocation.toolName,
            argumentsJSON: invocation.jsonArguments,
            toolCallId: invocation.toolCallId,
            geminiThoughtSignature: invocation.geminiThoughtSignature
        )
    }

    var serviceInvocation: ServiceToolInvocation {
        ServiceToolInvocation(
            toolName: name,
            jsonArguments: argumentsJSON,
            toolCallId: toolCallId,
            geminiThoughtSignature: geminiThoughtSignature
        )
    }
}

enum InferenceEventAdapter {
    static func event(for delta: String) -> InferenceEvent {
        if let toolName = StreamingToolHint.decode(delta) {
            return .toolCallStarted(name: toolName)
        }
        if let argumentsDelta = StreamingToolHint.decodeArgs(delta) {
            return .toolCallArgumentsDelta(argumentsDelta)
        }
        if let stats = StreamingStatsHint.decode(delta) {
            return .stats(
                InferenceStatsRecord(
                    tokenCount: stats.tokenCount,
                    tokensPerSecond: stats.tokensPerSecond
                )
            )
        }
        return .textDelta(delta)
    }

    static func adapt(_ stream: AsyncThrowingStream<String, Error>) -> AsyncThrowingStream<InferenceEvent, Error> {
        let (events, continuation) = AsyncThrowingStream<InferenceEvent, Error>.makeStream()

        let task = Task {
            do {
                for try await delta in stream {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    continuation.yield(event(for: delta))
                }
                continuation.finish()
            } catch let invocations as ServiceToolInvocations {
                continuation.yield(.toolCallsRequested(records(for: invocations)))
                continuation.finish()
            } catch let invocation as ServiceToolInvocation {
                continuation.yield(.toolCallRequested(InferenceToolCallRecord(invocation: invocation)))
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        continuation.onTermination = { @Sendable _ in
            task.cancel()
        }

        return events
    }

    static func records(for invocations: ServiceToolInvocations) -> [InferenceToolCallRecord] {
        invocations.invocations.map(InferenceToolCallRecord.init(invocation:))
    }
}

extension ChatEngineProtocol {
    func streamInferenceEvents(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<InferenceEvent, Error> {
        do {
            let stream = try await streamChat(request: request)
            return InferenceEventAdapter.adapt(stream)
        } catch let invocations as ServiceToolInvocations {
            let (events, continuation) = AsyncThrowingStream<InferenceEvent, Error>.makeStream()
            continuation.yield(.toolCallsRequested(InferenceEventAdapter.records(for: invocations)))
            continuation.finish()
            return events
        } catch let invocation as ServiceToolInvocation {
            let (events, continuation) = AsyncThrowingStream<InferenceEvent, Error>.makeStream()
            continuation.yield(.toolCallRequested(InferenceToolCallRecord(invocation: invocation)))
            continuation.finish()
            return events
        }
    }
}
