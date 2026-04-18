//
//  WorkExecutionEngine.swift
//  osaurus
//
//  Execution engine for Osaurus Agents - reasoning loop based.
//  Handles iterative task execution where model decides actions.
//

import Foundation

/// Execution engine for running work tasks via reasoning loop
public actor WorkExecutionEngine {
    /// The chat engine for LLM calls (lazily resolved to snapshot remote services)
    private var _chatEngine: ChatEngineProtocol?

    init(chatEngine: ChatEngineProtocol? = nil) {
        self._chatEngine = chatEngine
    }

    private func resolvedChatEngine() async -> ChatEngineProtocol {
        if let engine = _chatEngine { return engine }
        let engine = ChatEngine(source: .chatUI)
        _chatEngine = engine
        return engine
    }

    // MARK: - Constants

    static let truncationOmissionMarker = "characters omitted"

    // MARK: - Tool Execution

    /// Hard safety-net timeout for a single tool execution. The real timeout
    /// for sandbox commands is inactivity-based (at the container exec layer),
    /// so this only fires if something is genuinely stuck.
    private static let toolExecutionTimeout: UInt64 = 300

    private func makeToolCall(from invocation: ServiceToolInvocation) -> ToolCall {
        let callId =
            invocation.toolCallId
            ?? "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))"

        return ToolCall(
            id: callId,
            type: "function",
            function: ToolCallFunction(
                name: invocation.toolName,
                arguments: invocation.jsonArguments
            ),
            geminiThoughtSignature: invocation.geminiThoughtSignature
        )
    }

    /// Executes a tool call with a timeout to prevent indefinite hangs.
    private func executeToolCall(
        _ invocation: ServiceToolInvocation,
        issueId: String,
        agentId: UUID? = nil
    ) async throws -> ToolCallResult {
        let timeout = Self.toolExecutionTimeout
        let toolName = invocation.toolName

        let result: String = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                await self.executeToolInBackground(
                    name: invocation.toolName,
                    argumentsJSON: invocation.jsonArguments,
                    issueId: issueId,
                    agentId: agentId
                )
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
                return nil
            }

            guard let first = await group.next() else {
                return ToolErrorEnvelope(
                    kind: .timeout,
                    reason: "Tool did not complete within \(timeout) seconds.",
                    toolName: toolName
                ).toJSONString()
            }
            group.cancelAll()

            if let result = first {
                return result
            }

            print("[WorkExecutionEngine] Tool '\(toolName)' timed out after \(timeout)s")
            return ToolErrorEnvelope(
                kind: .timeout,
                reason: "Tool did not complete within \(timeout) seconds.",
                toolName: toolName
            ).toJSONString()
        }

        let toolCall = makeToolCall(from: invocation)

        return ToolCallResult(toolCall: toolCall, result: result)
    }

    /// Helper to execute tool in background with issue and agent context
    private func executeToolInBackground(
        name: String,
        argumentsJSON: String,
        issueId: String,
        agentId: UUID? = nil
    ) async -> String {
        do {
            return try await WorkExecutionContext.$currentIssueId.withValue(issueId) {
                try await WorkExecutionContext.$currentAgentId.withValue(agentId) {
                    try await ToolRegistry.shared.execute(
                        name: name,
                        argumentsJSON: argumentsJSON
                    )
                }
            }
        } catch {
            print("[WorkExecutionEngine] Tool execution failed: \(error)")
            return ToolErrorEnvelope(
                kind: classifyToolError(error),
                reason: error.localizedDescription,
                toolName: name
            ).toJSONString()
        }
    }

    /// Map common error shapes to a `ToolErrorEnvelope.Kind` so the model
    /// gets the right `retryable` signal. Permission rejections are sticky
    /// (retryable=false); transient infrastructure errors are not.
    private func classifyToolError(_ error: Error) -> ToolErrorEnvelope.Kind {
        let message = error.localizedDescription.lowercased()
        if message.contains("denied") || message.contains("rejected") || message.contains("permission") {
            return .rejected
        }
        if message.contains("not found") || message.contains("unknown tool") {
            return .toolNotFound
        }
        if message.contains("timeout") || message.contains("timed out") {
            return .timeout
        }
        if message.contains("invalid") && message.contains("argument") {
            return .invalidArguments
        }
        return .executionError
    }

    // MARK: - Tool Result Truncation

    /// Maximum characters for a single tool result in the conversation.
    static let maxToolResultLength = 8000

    /// Truncates a tool result, keeping head and tail with an omission marker.
    /// Internal visibility for testability via `@testable import`.
    func truncateToolResult(_ result: String) -> String {
        guard result.count > Self.maxToolResultLength else { return result }
        if let structured = truncateStructuredToolResult(result) {
            return structured
        }
        return truncatePlainTextToolResult(result)
    }

    private func truncateStructuredToolResult(_ result: String) -> String? {
        guard let data = result.data(using: .utf8),
            var payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let preferredKeys = ["stdout", "stderr", "output", "content", "entries", "matches", "processes"]
        let presentKeys = preferredKeys.filter { (payload[$0] as? String)?.isEmpty == false }
        guard !presentKeys.isEmpty else { return nil }

        let perFieldLimit = max(600, (Self.maxToolResultLength - 1200) / max(presentKeys.count, 1))
        var truncatedAny = false
        for key in presentKeys {
            guard let value = payload[key] as? String, value.count > perFieldLimit else { continue }
            payload[key] = truncatePlainTextToolResult(value, limit: perFieldLimit)
            payload["\(key)_truncated"] = true
            payload["\(key)_original_length"] = value.count
            truncatedAny = true
        }

        guard truncatedAny,
            let encoded = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            let text = String(data: encoded, encoding: .utf8),
            text.count <= Self.maxToolResultLength
        else { return nil }

        return text
    }

    private func truncatePlainTextToolResult(_ result: String, limit: Int = maxToolResultLength) -> String {
        guard result.count > limit else { return result }
        let headSize = limit * 3 / 4
        let tailSize = limit / 4
        let head = String(result.prefix(headSize))
        let tail = String(result.suffix(tailSize))
        let omitted = result.count - headSize - tailSize
        return
            "\(head)\n\n[... \(omitted) \(Self.truncationOmissionMarker) — use `sandbox_read_file` (with start_line, line_count, or tail_lines) or `file_read` to inspect the full output ...]\n\n\(tail)"
    }

    // MARK: - Folder Context

    /// Builds the folder context section for prompts when a folder is selected.
    static func buildFolderContextSection(from folderContext: WorkFolderContext?) -> String {
        SystemPromptTemplates.folderContext(from: folderContext)
    }

    // MARK: - Context Compaction

    /// Clears old tool results in-place to free context budget.
    /// Returns the number of results cleared this pass.
    private func clearStaleToolResults(
        messages: inout [ChatMessage],
        currentIteration: Int,
        staleness: Int = 8
    ) -> Int {
        guard currentIteration > staleness else { return 0 }

        var iterationBoundary = 0
        var cleared = 0

        // Walk backwards counting iteration boundaries (each assistant message = ~1 iteration)
        for i in stride(from: messages.count - 1, through: 0, by: -1) {
            let msg = messages[i]
            if msg.role == "assistant" {
                iterationBoundary += 1
            }
            if msg.role == "tool", iterationBoundary >= staleness,
                let content = msg.content,
                !content.hasPrefix("[Result cleared")
            {
                let toolName = resolveToolName(
                    forToolCallId: msg.tool_call_id,
                    in: messages,
                    before: i
                )
                let label = toolName ?? "unknown tool"
                let byteCount = content.utf8.count
                messages[i] = ChatMessage(
                    role: "tool",
                    content:
                        "[Result cleared — \(label) returned \(byteCount) bytes. Re-run the tool or use `sandbox_read_file` to inspect.]",
                    tool_calls: nil,
                    tool_call_id: msg.tool_call_id
                )
                cleared += 1
            }
        }
        return cleared
    }

    /// Finds the tool name for a given `tool_call_id` by scanning preceding assistant messages.
    private func resolveToolName(
        forToolCallId callId: String?,
        in messages: [ChatMessage],
        before index: Int
    ) -> String? {
        guard let callId else { return nil }
        for i in stride(from: index - 1, through: 0, by: -1) {
            if let toolCalls = messages[i].tool_calls {
                for tc in toolCalls where tc.id == callId {
                    return tc.function.name
                }
            }
        }
        return nil
    }

    private static let compactionSummarizationPrompt = SystemPromptTemplates.compactionSummarizationPrompt

    /// Compacts middle messages into a summary using an LLM call.
    /// Protects the head (initial context) and tail (recent work), summarizing everything between.
    private func compactMiddleMessages(
        messages: [ChatMessage],
        model: String?,
        protectHead: Int = 2,
        protectTail: Int = 6
    ) async throws -> [ChatMessage] {
        let head = min(protectHead, messages.count)
        let tail = min(protectTail, messages.count - head)

        guard messages.count > head + tail else { return messages }

        let headSlice = Array(messages[..<head])
        let tailSlice = Array(messages[(messages.count - tail)...])
        let middle = Array(messages[head ..< (messages.count - tail)])

        // Serialize the middle chunk for summarization. Per-message budget
        // is generous enough to retain the operative detail of tool results
        // (~2000 chars vs the previous 500), and assistant `tool_calls` are
        // expanded into the transcript so the summarizer can describe what
        // each call did with what arguments — not just "called X".
        var transcript = ""
        let perMessageLimit = 2000
        for msg in middle {
            let role = msg.role.uppercased()
            if let calls = msg.tool_calls, !calls.isEmpty {
                let parts = calls.map { call -> String in
                    let args = call.function.arguments
                    let argsTrimmed =
                        args.count > 200 ? String(args.prefix(200)) + "..." : args
                    return "\(call.function.name)(\(argsTrimmed))"
                }
                transcript += "[ASSISTANT tool_calls] \(parts.joined(separator: "; "))\n"
            }
            if let content = msg.content, !content.isEmpty {
                let truncated =
                    content.count > perMessageLimit
                    ? String(content.prefix(perMessageLimit)) + "..."
                    : content
                transcript += "[\(role)] \(truncated)\n"
            }
        }

        guard !transcript.isEmpty else { return messages }

        let request = ChatCompletionRequest(
            model: model ?? "default",
            messages: [
                ChatMessage(role: "system", content: Self.compactionSummarizationPrompt),
                ChatMessage(role: "user", content: transcript),
            ],
            temperature: 0.1,
            max_tokens: 1024,
            stream: nil,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: nil,
            tool_choice: nil
        )

        let response = try await resolvedChatEngine().completeChat(request: request)
        guard let summary = response.choices.first?.message.content, !summary.isEmpty else {
            throw WorkExecutionError.unknown("Empty compaction summary")
        }

        let summaryMessage = ChatMessage(
            role: "user",
            content: """
                [System — Context Summary]
                The following summarizes work completed in earlier iterations that has been compacted:

                \(summary)

                If you saved any notes earlier, call `read_notes` now to recover detail that the summary may have dropped. Then continue from where this summary leaves off.
                """
        )

        return stripOrphanedToolResults(headSlice + [summaryMessage] + tailSlice)
    }

    /// Removes tool-result messages that have no matching tool_call in a preceding assistant message.
    private func stripOrphanedToolResults(_ messages: [ChatMessage]) -> [ChatMessage] {
        var knownCallIds = Set<String>()
        var cleaned: [ChatMessage] = []
        for msg in messages {
            if let toolCalls = msg.tool_calls {
                for tc in toolCalls { knownCallIds.insert(tc.id) }
            }
            if msg.role == "tool" {
                guard let callId = msg.tool_call_id, knownCallIds.contains(callId) else { continue }
            }
            cleaned.append(msg)
        }
        return cleaned
    }

    // MARK: - Reasoning Loop

    /// Callback type for iteration-based streaming updates
    public typealias IterationStreamingCallback = @MainActor @Sendable (String, Int) async -> Void

    /// Callback type for tool call completion
    public typealias ToolCallCallback = @MainActor @Sendable (String, String, String) async -> Void

    /// Callback type for status updates
    public typealias StatusCallback = @MainActor @Sendable (String) async -> Void

    /// Callback type for artifact generation
    public typealias ArtifactCallback = @MainActor @Sendable (SharedArtifact) async -> Void

    /// Callback type for iteration start (iteration number)
    public typealias IterationStartCallback = @MainActor @Sendable (Int) async -> Void

    /// Callback type for tool hint (pending tool name detected during streaming)
    public typealias ToolHintCallback = @MainActor @Sendable (String) async -> Void

    /// Callback type for tool argument fragment (partial args detected during streaming)
    public typealias ToolArgHintCallback = @MainActor @Sendable (String) async -> Void

    /// Callback type for token consumption (inputTokens, outputTokens)
    public typealias TokenConsumptionCallback = @MainActor @Sendable (Int, Int) async -> Void
    public typealias InterruptCheckCallback = @Sendable () async -> Bool

    /// Callback for secret prompt — shows a secure input overlay and returns the value (nil if cancelled)
    public typealias SecretPromptCallback = @MainActor @Sendable (SecretPromptParser.Prompt) async -> String?

    /// Refreshed system context produced by an out-of-band recompose (e.g.
    /// after `capabilities_load` or compaction). The engine swaps in the
    /// new system prompt, tool list, cache hints, and memory snippet for
    /// subsequent iterations without restarting the loop.
    struct RefreshedWorkContext: Sendable {
        let systemPrompt: String
        let tools: [Tool]
        let cacheHint: String?
        let staticPrefix: String?
        let memorySection: String?
        init(
            systemPrompt: String,
            tools: [Tool],
            cacheHint: String? = nil,
            staticPrefix: String? = nil,
            memorySection: String? = nil
        ) {
            self.systemPrompt = systemPrompt
            self.tools = tools
            self.cacheHint = cacheHint
            self.staticPrefix = staticPrefix
            self.memorySection = memorySection
        }
    }

    /// Callback that recomposes the work context for the current agent.
    /// Called after triggers that genuinely change what the model needs to
    /// see (capabilities_load / sandbox_plugin_register / compaction). The
    /// `query` is the most recent user message so memory + preflight stay
    /// relevant.
    typealias ContextRefreshCallback =
        @MainActor @Sendable (
            _ query: String,
            _ executionMode: WorkExecutionMode
        ) async -> RefreshedWorkContext?

    /// Callback fired right after `capabilities_load` /
    /// `sandbox_plugin_register` adds new tools to the active set. The
    /// caller (WorkSession) records the names into the per-issue
    /// `SessionToolState.loadedToolNames` so the subsequent context refresh
    /// — and any later resume — reuses the same kit instead of re-running
    /// preflight or losing the tools.
    typealias ToolsLoadedCallback =
        @MainActor @Sendable (_ toolNames: [String]) async -> Void

    /// Default maximum iterations for the reasoning loop
    public static let defaultMaxIterations = 50

    /// Maximum consecutive text-only responses (no tool call) before aborting.
    /// Models that don't support tool calling will describe actions in plain text
    /// instead of invoking tools, causing an infinite loop of "Continue" prompts.
    private static let maxConsecutiveTextOnlyResponses = 3

    /// The main reasoning loop. Model decides what to do on each iteration.
    /// - Parameters:
    ///   - issue: The issue being executed
    ///   - messages: Conversation messages (mutated with new messages)
    ///   - systemPrompt: The full system prompt including work instructions
    ///   - model: Model to use
    ///   - tools: All available tools (model picks which to use)
    ///   - contextLength: Model context window size in tokens (used for budget management)
    ///   - toolTokenEstimate: Estimated tokens consumed by tool definitions
    ///   - maxIterations: Maximum loop iterations (not tool calls - iterations)
    ///   - onIterationStart: Callback at the start of each iteration
    ///   - onDelta: Callback for streaming text deltas
    ///   - onToolCall: Callback when a tool is called (toolName, args, result)
    ///   - onStatusUpdate: Callback for status messages
    ///   - onArtifact: Callback when an artifact is shared (via share_artifact tool)
    ///   - onTokensConsumed: Callback with estimated token consumption per iteration
    /// - Returns: The result of the loop execution
    func executeLoop(
        issue: Issue,
        messages: inout [ChatMessage],
        systemPrompt: String,
        model: String?,
        tools: [Tool],
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        topPOverride: Float? = nil,
        contextLength: Int? = nil,
        toolTokenEstimate: Int = 0,
        maxIterations: Int = defaultMaxIterations,
        executionMode: WorkExecutionMode = .none,
        sandboxAgentName: String? = nil,
        agentId: UUID? = nil,
        cacheHint: String? = nil,
        staticPrefix: String? = nil,
        memorySection: String? = nil,
        modelOptions: [String: ModelOptionValue] = [:],
        shouldInterrupt: @escaping InterruptCheckCallback = { false },
        onIterationStart: @escaping IterationStartCallback,
        onDelta: @escaping IterationStreamingCallback,
        onToolHint: @escaping ToolHintCallback,
        onToolArgHint: @escaping ToolArgHintCallback,
        onToolCall: @escaping ToolCallCallback,
        onStatusUpdate: @escaping StatusCallback,
        onArtifact: @escaping ArtifactCallback,
        onTokensConsumed: @escaping TokenConsumptionCallback,
        onSecretPrompt: SecretPromptCallback? = nil,
        onContextRefresh: ContextRefreshCallback? = nil,
        onToolsLoaded: ToolsLoadedCallback? = nil
    ) async throws -> LoopResult {
        var activeTools = tools
        // Mutable so context-refresh triggers (capabilities_load,
        // compaction, sandbox_plugin_register) can swap in a fresher
        // system prompt + cache prefix mid-loop.
        var systemPrompt = systemPrompt
        var cacheHint = cacheHint
        var staticPrefix = staticPrefix
        var memorySection = memorySection
        var contextDirty = false
        var iteration = 0
        var totalToolCalls = 0
        var toolsUsed: [String] = []
        var consecutiveTextOnly = 0
        var lastResponseContent = ""
        var preSaveAttempted = false
        // Iteration of the most recent compaction; prevents the compactor from
        // running on every iteration if `messages` somehow stays over budget.
        var lastCompactionIteration = -100
        // Recent tool invocations (name + args hash) for stuck-loop detection.
        var recentToolCalls: [String] = []

        // Set up context budget manager if context length is known
        var budgetManager: ContextBudgetManager? = nil
        if let ctxLen = contextLength {
            var manager = ContextBudgetManager(contextLength: ctxLen)
            manager.reserveByCharCount(.systemPrompt, characters: systemPrompt.count)
            manager.reserve(.tools, tokens: toolTokenEstimate)
            manager.reserve(.memory, tokens: 0)
            manager.reserve(.response, tokens: maxTokens ?? 4096)
            budgetManager = manager
        }

        while iteration < maxIterations {
            iteration += 1
            if Task.isCancelled {
                return .interrupted(
                    messages: messages,
                    iteration: iteration - 1,
                    totalToolCalls: totalToolCalls
                )
            }
            if await shouldInterrupt() {
                return .interrupted(
                    messages: messages,
                    iteration: iteration - 1,
                    totalToolCalls: totalToolCalls
                )
            }

            await onIterationStart(iteration)
            await onStatusUpdate("Iteration \(iteration)")

            if iteration > 1 && iteration % 10 == 0 {
                let remaining = maxIterations - iteration
                await onStatusUpdate(
                    SystemPromptTemplates.budgetRemainingStatus(remaining: remaining, total: maxIterations)
                )
                messages.append(
                    ChatMessage(
                        role: "user",
                        content:
                            "[System Notice] Budget: \(remaining)/\(maxIterations) iterations remaining. Prioritize completing the core task. Use `create_issue` for non-essential follow-up work."
                    )
                )
            }

            let warningThreshold = SystemPromptTemplates.budgetWarningThreshold
            if iteration == maxIterations - warningThreshold {
                await onStatusUpdate(SystemPromptTemplates.budgetWarningStatus(remaining: warningThreshold))
                messages.append(
                    ChatMessage(
                        role: "user",
                        content:
                            "[System Notice] \(warningThreshold) iterations remaining. Finish current work and call `complete_task` with status, verification, remaining risks, and remaining work. Create issues for anything unfinished."
                    )
                )
            }

            // Tier 1: Clear stale tool results in-place (cheap, no LLM call)
            let cleared = clearStaleToolResults(messages: &messages, currentIteration: iteration)
            if cleared > 0 {
                await onStatusUpdate("Optimizing memory...")
            }

            // Context compaction: tier 2 LLM summarization when over budget.
            //
            // Two-step strategy on first overrun:
            //   1) Append a "save_notes" nudge BUT do NOT skip the iteration —
            //      the model still gets a chance to call save_notes inline.
            //   2) On the next overrun, run the compactor.
            //
            // After a successful compaction we WRITE THE COMPACTED HISTORY
            // BACK to `messages` so subsequent budget checks see the smaller
            // transcript. Otherwise the compactor would fire every iteration
            // and the budget would never recover.
            //
            // Minimum interval between compactions guards against pathological
            // cases where compaction itself doesn't shrink the transcript.
            let minCompactionInterval = 2
            if let manager = budgetManager, !manager.fitsInBudget(messages) {
                if !preSaveAttempted {
                    await onStatusUpdate("Saving progress notes...")
                    messages.append(
                        ChatMessage(
                            role: "user",
                            content: "[System] Context is getting large and will be compacted soon. "
                                + "Use `save_notes` now to record any important findings, decisions, "
                                + "or state you want to preserve. Then continue with your task."
                        )
                    )
                    preSaveAttempted = true
                } else if iteration - lastCompactionIteration >= minCompactionInterval {
                    await onStatusUpdate("Summarizing earlier work...")
                    do {
                        let compacted = try await compactMiddleMessages(
                            messages: messages,
                            model: model
                        )
                        messages = compacted
                        await onStatusUpdate("Resuming with summary")
                    } catch {
                        messages = manager.trimMessages(messages)
                        await onStatusUpdate("Resuming...")
                    }
                    lastCompactionIteration = iteration
                    // Allow another pre-save nudge before the next compaction.
                    preSaveAttempted = false
                    // Memory has shifted significantly — request a context
                    // refresh so preflight + memory snippets reflect the
                    // post-compaction state.
                    contextDirty = true
                }
            }

            // Refresh system prompt + tools when capabilities have changed
            // (capabilities_load / sandbox_plugin_register) or after
            // compaction. We do this BEFORE building the request so the new
            // values flow into the next streamChat call. Skipped when no
            // refresh callback is wired (e.g. tests, plain WorkEngine path).
            if contextDirty, let refresh = onContextRefresh {
                let lastUserText = messages.reversed().first { $0.role == "user" }?.content ?? ""
                if let refreshed = await refresh(lastUserText, executionMode) {
                    systemPrompt = refreshed.systemPrompt
                    activeTools = refreshed.tools
                    cacheHint = refreshed.cacheHint
                    staticPrefix = refreshed.staticPrefix
                    memorySection = refreshed.memorySection
                    await onStatusUpdate("Refreshed context")
                }
                contextDirty = false
            }
            // Memory rides on the latest user message instead of the system
            // prompt — keeps the system prefix byte-stable across iterations
            // so the MLX paged KV cache reuses the entire conversation prefix.
            // We work on a copy so the underlying transcript stays clean.
            var effectiveMessages = messages
            SystemPromptComposer.injectMemoryPrefix(memorySection, into: &effectiveMessages)

            await onStatusUpdate("Thinking...")

            // Build full messages with system prompt
            let fullMessages = [ChatMessage(role: "system", content: systemPrompt)] + effectiveMessages

            var request = ChatCompletionRequest(
                model: model ?? "default",
                messages: fullMessages,
                temperature: temperature ?? 0.3,
                max_tokens: maxTokens ?? 4096,
                stream: nil,
                top_p: topPOverride,
                frequency_penalty: nil,
                presence_penalty: nil,
                stop: nil,
                n: nil,
                tools: activeTools.isEmpty ? nil : activeTools,
                tool_choice: activeTools.isEmpty ? nil : .auto,
                session_id: issue.id
            )
            request.cache_hint = cacheHint
            request.staticPrefix = staticPrefix
            // Forward per-model options (e.g. `disableThinking: true` for
            // Qwen3-family) so the Jinja renderer sees `enable_thinking: false`.
            // Without this, Work mode silently ignored the reasoning toggle
            // even after the user had flipped it — the request leaving
            // ChatEngine had no `modelOptions` dict at all.
            request.modelOptions = modelOptions.isEmpty ? nil : modelOptions

            // Stream response
            var responseContent = ""
            // Collect every tool call surfaced from this completion. Local
            // models can emit multiple `<tool_call>` blocks per response;
            // ServiceToolInvocations carries the full batch so we execute
            // each in order within this single iteration instead of one
            // round-trip per call.
            var pendingInvocations: [ServiceToolInvocation] = []

            do {
                let stream = try await resolvedChatEngine().streamChat(request: request)
                for try await delta in stream {
                    if await shouldInterrupt() {
                        return .interrupted(
                            messages: messages,
                            iteration: iteration,
                            totalToolCalls: totalToolCalls
                        )
                    }
                    if let toolName = StreamingToolHint.decode(delta) {
                        await onToolHint(toolName)
                        continue
                    }
                    if let argFragment = StreamingToolHint.decodeArgs(delta) {
                        await onToolArgHint(argFragment)
                        continue
                    }
                    // Strip benchmarking sentinel (￾stats:N;TPS). Like
                    // StreamingToolHint, the stats delta is its own stream
                    // fragment — not part of the visible text — so we must
                    // drop it rather than accumulate into responseContent.
                    // Otherwise the sentinel ends up persisted in the
                    // assistant message and re-rendered as raw text
                    // ("…￾stats:24;85.46…", issue #856). ChatView already
                    // handles this for the chat path; Work needs the same
                    // strip on its own consumer.
                    if StreamingStatsHint.decode(delta) != nil {
                        continue
                    }
                    responseContent += delta
                    await onDelta(delta, iteration)
                }
            } catch let invs as ServiceToolInvocations {
                pendingInvocations = invs.invocations
            } catch let invocation as ServiceToolInvocation {
                pendingInvocations = [invocation]
            } catch is CancellationError {
                return .interrupted(
                    messages: messages,
                    iteration: iteration,
                    totalToolCalls: totalToolCalls
                )
            }

            lastResponseContent = responseContent

            // Estimate token consumption for this iteration. Includes the
            // full assistant message body (content + serialized tool_calls)
            // and incoming tool messages so tool-heavy iterations don't
            // under-report. Mirrors ChatEngine.estimateInputTokens.
            let inputChars = estimateMessagesChars(fullMessages) + systemPrompt.count
            let outputChars =
                responseContent.count
                + pendingInvocations.reduce(0) {
                    $0 + $1.toolName.count + $1.jsonArguments.count + 20
                }
            let estimatedInputTokens = max(1, inputChars / 4)
            let estimatedOutputTokens = max(1, outputChars / 4)
            await onTokensConsumed(estimatedInputTokens, estimatedOutputTokens)

            // If pure text response (no tool call), keep nudging tool-capable progress.
            if pendingInvocations.isEmpty {
                messages.append(ChatMessage(role: "assistant", content: responseContent))

                // Track consecutive text-only responses to detect models that can't use tools
                consecutiveTextOnly += 1
                if consecutiveTextOnly >= Self.maxConsecutiveTextOnlyResponses {
                    print(
                        "[WorkExecutionEngine] \(consecutiveTextOnly) consecutive text-only responses"
                            + " — aborting to prevent infinite loop"
                    )
                    let summary = extractCompletionSummary(from: responseContent)
                    let fallback =
                        summary.isEmpty
                        ? String(responseContent.prefix(500))
                        : summary
                    return .completed(summary: fallback, artifact: nil, status: .partial)
                }

                // Model is reasoning but hasn't called a tool yet - prompt to continue
                // This helps models that reason out loud before acting
                messages.append(
                    ChatMessage(
                        role: "user",
                        content:
                            "Continue with the next action. Use the available tools to do the work, verify the result, and call `complete_task` only after verification."
                    )
                )
                continue
            }

            // Model successfully called at least one tool - reset counter.
            consecutiveTextOnly = 0

            // Sequentially process every tool the model emitted in this
            // completion. Meta-tools (complete_task, request_clarification)
            // short-circuit the rest of the batch — models almost never
            // mix them with other tools, but if they do, prior calls have
            // already been executed and appended above by the time we get
            // here.
            for invocation in pendingInvocations {
                totalToolCalls += 1
                if !toolsUsed.contains(invocation.toolName) {
                    toolsUsed.append(invocation.toolName)
                }

                if let nudge = stuckLoopNudge(
                    for: invocation,
                    recentToolCalls: &recentToolCalls
                ) {
                    messages.append(ChatMessage(role: "user", content: nudge))
                }

                // Check for meta-tool signals before execution
                switch invocation.toolName {
                case "complete_task":
                    switch parseCompleteTaskArgs(invocation.jsonArguments, taskId: issue.taskId) {
                    case .success(let completion):
                        return .completed(
                            summary: completion.contract.formattedMessage,
                            artifact: completion.artifact,
                            status: completion.contract.status
                        )

                    case .failure(let rejection):
                        let toolCall = makeToolCall(from: invocation)
                        let rejectionMessage = ToolErrorEnvelope(
                            kind: .rejected,
                            reason: rejection.message,
                            toolName: invocation.toolName,
                            retryable: true
                        ).toJSONString()
                        appendAssistantToolCall(
                            responseContent: responseContent,
                            toolCall: toolCall,
                            toolName: invocation.toolName,
                            into: &messages
                        )
                        messages.append(
                            ChatMessage(
                                role: "tool",
                                content: rejectionMessage,
                                tool_calls: nil,
                                tool_call_id: toolCall.id
                            )
                        )
                        messages.append(
                            ChatMessage(
                                role: "user",
                                content:
                                    "[System Notice] `complete_task` was rejected. Continue working, gather evidence, and try again with the required structured completion contract."
                            )
                        )

                        await onToolCall(invocation.toolName, invocation.jsonArguments, rejectionMessage)
                        await onStatusUpdate("Completion rejected")

                        _ = try? IssueStore.createEvent(
                            IssueEvent.withPayload(
                                issueId: issue.id,
                                eventType: .toolCallCompleted,
                                payload: EventPayload.ToolCallCompleted(
                                    toolName: invocation.toolName,
                                    iteration: iteration,
                                    arguments: invocation.jsonArguments,
                                    result: rejectionMessage,
                                    success: false
                                )
                            )
                        )
                        continue
                    }

                case "request_clarification":
                    // Parse clarification request
                    let clarification = parseClarificationArgs(invocation.jsonArguments)
                    return .needsClarification(
                        clarification,
                        messages: messages,
                        iteration: iteration,
                        totalToolCalls: totalToolCalls
                    )

                default:
                    break
                }

                // Execute the tool
                let result = try await executeToolCall(invocation, issueId: issue.id, agentId: agentId)

                // Hot-load tools injected by capabilities_load or sandbox_plugin_register.
                // Skipped in manual mode — the user's explicit tool set is fixed.
                let isManualMode: Bool = await {
                    guard let id = agentId else { return false }
                    return await MainActor.run { AgentManager.shared.effectiveToolSelectionMode(for: id) == .manual }
                }()
                if !isManualMode,
                    invocation.toolName == "capabilities_load"
                        || invocation.toolName == "sandbox_plugin_register"
                {
                    let newTools = await CapabilityLoadBuffer.shared.drain()
                    var addedNames: [String] = []
                    for tool in newTools where !activeTools.contains(where: { $0.function.name == tool.function.name })
                    {
                        activeTools.append(tool)
                        addedNames.append(tool.function.name)
                    }
                    if !addedNames.isEmpty {
                        // Persist names to the session cache BEFORE flagging
                        // the refresh so the subsequent recompose sees them
                        // and the agent doesn't lose the freshly loaded tools.
                        await onToolsLoaded?(addedNames)
                        // Tool surface changed — request a full context
                        // recompose before the next iteration so the system
                        // prompt + cache hint reflect the new capabilities.
                        contextDirty = true
                    }
                }

                // Process share_artifact before storing the result so the enriched
                // metadata (host_path, file_size, etc.) flows into the transcript.
                var toolResultForDisplay = result.result
                var sharedArtifact: SharedArtifact?
                if invocation.toolName == "share_artifact" {
                    if let processed = SharedArtifact.processToolResult(
                        result.result,
                        contextId: issue.taskId,
                        contextType: .work,
                        executionMode: executionMode,
                        sandboxAgentName: sandboxAgentName
                    ) {
                        toolResultForDisplay = processed.enrichedToolResult
                        sharedArtifact = processed.artifact
                    }
                }

                let truncatedResult = truncateToolResult(toolResultForDisplay)
                await onToolCall(invocation.toolName, invocation.jsonArguments, toolResultForDisplay)

                appendAssistantToolCall(
                    responseContent: responseContent,
                    toolCall: result.toolCall,
                    toolName: invocation.toolName,
                    into: &messages
                )
                messages.append(
                    ChatMessage(
                        role: "tool",
                        content: truncatedResult,
                        tool_calls: nil,
                        tool_call_id: result.toolCall.id
                    )
                )

                // Log the tool call event
                _ = try? IssueStore.createEvent(
                    IssueEvent.withPayload(
                        issueId: issue.id,
                        eventType: .toolCallCompleted,
                        payload: EventPayload.ToolCallCompleted(
                            toolName: invocation.toolName,
                            iteration: iteration,
                            arguments: invocation.jsonArguments,
                            result: result.result,
                            success: !ToolErrorEnvelope.isErrorResult(result.result)
                        )
                    )
                )

                // Handle semi-meta-tools (execute but also process results)
                switch invocation.toolName {
                case "create_issue":
                    await onStatusUpdate("Created follow-up issue")

                case "share_artifact":
                    if let artifact = sharedArtifact {
                        await onArtifact(artifact)
                        await onStatusUpdate("Shared artifact: \(artifact.filename)")
                        await PluginManager.shared.notifyArtifactHandlers(artifact: artifact)
                    }

                case "sandbox_secret_set":
                    if let prompt = SecretPromptParser.parse(result.result),
                        let handler = onSecretPrompt
                    {
                        let secretValue = await handler(prompt)
                        let replacement =
                            secretValue != nil
                            ? SecretToolResult.stored(key: prompt.key)
                            : SecretToolResult.cancelled(key: prompt.key)
                        if let lastIdx = messages.indices.last, messages[lastIdx].role == "tool" {
                            messages[lastIdx] = ChatMessage(
                                role: "tool",
                                content: replacement,
                                tool_calls: nil,
                                tool_call_id: messages[lastIdx].tool_call_id
                            )
                        }
                    }

                default:
                    break
                }
            }  // end for invocation in pendingInvocations
        }

        // Hit iteration limit
        return .iterationLimitReached(
            messages: messages,
            totalIterations: iteration,
            totalToolCalls: totalToolCalls,
            lastResponseContent: lastResponseContent
        )
    }

    /// Append an assistant tool-call message to `messages`, stripping any
    /// leaked function-call JSON from `responseContent` and using `nil`
    /// content when nothing useful remains. Centralises the
    /// previously-duplicated `if cleanedContent.isEmpty { … } else { … }`
    /// blocks at every Work-loop tool-call site.
    private func appendAssistantToolCall(
        responseContent: String,
        toolCall: ToolCall,
        toolName: String,
        into messages: inout [ChatMessage]
    ) {
        let cleaned = StringCleaning.stripFunctionCallLeakage(responseContent, toolName: toolName)
        messages.append(
            ChatMessage(
                role: "assistant",
                content: cleaned.isEmpty ? nil : cleaned,
                tool_calls: [toolCall],
                tool_call_id: nil
            )
        )
    }

    /// Stuck-loop detection. Records this invocation in the rolling window
    /// of the last 4 tool calls and returns a system-nudge string when the
    /// same `(name, args-prefix)` fingerprint has appeared 3 times in a row.
    /// Mutates `recentToolCalls` in place; clears it after firing so the
    /// nudge only goes out once per stuck cluster.
    private func stuckLoopNudge(
        for invocation: ServiceToolInvocation,
        recentToolCalls: inout [String]
    ) -> String? {
        let fingerprint = "\(invocation.toolName)|\(invocation.jsonArguments.prefix(256))"
        recentToolCalls.append(fingerprint)
        if recentToolCalls.count > 4 { recentToolCalls.removeFirst() }
        guard recentToolCalls.count >= 3,
            Set(recentToolCalls.suffix(3)).count == 1
        else { return nil }
        recentToolCalls.removeAll(keepingCapacity: true)
        return
            "[System Notice] You've called `\(invocation.toolName)` repeatedly without progress. Pivot now: try a different tool, change the arguments meaningfully, or split the work with `create_issue` and call `complete_task` with `status: \"blocked\"` describing what you tried and why it didn't work."
    }

    /// Sum char-count of `content` plus serialized `tool_calls` plus tool
    /// result bodies across `messages`. Used to estimate input token count
    /// without ignoring tool-heavy iterations (mirrors
    /// `ChatEngine.estimateInputTokens`).
    private func estimateMessagesChars(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { sum, msg in
            var chars = msg.content?.count ?? 0
            if let calls = msg.tool_calls {
                for call in calls {
                    chars += call.function.name.count
                    chars += call.function.arguments.count
                    chars += 20  // ~JSON envelope overhead per call
                }
            }
            return sum + chars
        }
    }

    /// Extracts a completion summary from a text response
    private func extractCompletionSummary(from content: String) -> String {
        // Try to find a summary section
        let lines = content.components(separatedBy: .newlines)
        var summaryLines: [String] = []
        var inSummary = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased().contains("SUMMARY") || trimmed.uppercased().contains("COMPLETED") {
                inSummary = true
            }
            if inSummary && !trimmed.isEmpty {
                summaryLines.append(trimmed)
            }
        }

        if summaryLines.isEmpty {
            // Just use the whole content, truncated
            return String(content.prefix(500))
        }
        return summaryLines.joined(separator: "\n")
    }

    private struct ParsedCompleteTask {
        let contract: WorkCompletionContract
        let artifact: SharedArtifact?
    }

    private struct CompleteTaskRejection: Error {
        let message: String
    }

    /// Parses complete_task tool arguments
    private func parseCompleteTaskArgs(_ jsonArgs: String, taskId: String) -> Result<
        ParsedCompleteTask,
        CompleteTaskRejection
    > {
        guard let data = jsonArgs.data(using: .utf8),
            let contract = try? JSONDecoder().decode(WorkCompletionContract.self, from: data)
        else {
            return .failure(
                CompleteTaskRejection(
                    message: "`complete_task` requires \(WorkCompletionContract.formatHint)"
                )
            )
        }

        if let validationError = contract.validationError {
            return .failure(
                CompleteTaskRejection(
                    message:
                        "\(validationError) `complete_task` requires \(WorkCompletionContract.formatHint)"
                )
            )
        }

        var artifact: SharedArtifact? = nil
        if let rawContent = contract.artifact, !rawContent.isEmpty {
            let content =
                rawContent
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\t", with: "\t")

            let contextDir = OsaurusPaths.contextArtifactsDir(contextId: taskId)
            OsaurusPaths.ensureExistsSilent(contextDir)
            let destPath = contextDir.appendingPathComponent("result.md")
            try? content.write(to: destPath, atomically: true, encoding: .utf8)

            artifact = SharedArtifact(
                contextId: taskId,
                contextType: .work,
                filename: "result.md",
                mimeType: "text/markdown",
                fileSize: content.utf8.count,
                hostPath: destPath.path,
                content: content,
                isFinalResult: true
            )
            if let artifact { _ = try? IssueStore.createSharedArtifact(artifact) }
        }

        return .success(ParsedCompleteTask(contract: contract, artifact: artifact))
    }

    /// Parses request_clarification tool arguments
    private func parseClarificationArgs(_ jsonArgs: String) -> ClarificationRequest {
        struct ClarificationArgs: Decodable {
            let question: String
            let options: [String]?
            let context: String?
        }

        guard let data = jsonArgs.data(using: .utf8),
            let args = try? JSONDecoder().decode(ClarificationArgs.self, from: data)
        else {
            return ClarificationRequest(question: "Could you please clarify your request?")
        }

        return ClarificationRequest(
            question: args.question,
            options: args.options,
            context: args.context
        )
    }

}

// MARK: - Secret Prompt Parsing

public enum SecretPromptParser {
    public struct Prompt: Sendable {
        public let key: String
        public let description: String
        public let instructions: String
        public let agentId: String
    }

    public static func parse(_ toolResult: String) -> Prompt? {
        guard let data = toolResult.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let action = dict["action"] as? String,
            action == SecretPromptAction.actionKey,
            let key = dict["key"] as? String,
            let desc = dict["description"] as? String,
            let instructions = dict["instructions"] as? String,
            let agentId = dict["agent_id"] as? String
        else { return nil }
        return Prompt(key: key, description: desc, instructions: instructions, agentId: agentId)
    }

}

// MARK: - Supporting Types

/// Result of a tool call
public struct ToolCallResult: Sendable {
    public let toolCall: ToolCall
    public let result: String
}

// MARK: - Errors

/// Errors that can occur during work execution
public enum WorkExecutionError: Error, LocalizedError {
    case executionCancelled
    case iterationLimitReached(Int)
    case networkError(String)
    case rateLimited(retryAfter: TimeInterval?)
    case toolExecutionFailed(String)
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .executionCancelled:
            return "Execution was cancelled"
        case .iterationLimitReached(let count):
            return "Iteration limit reached after \(count) iterations"
        case .networkError(let reason):
            return "Network error: \(reason)"
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "Rate limited. Retry after \(Int(seconds)) seconds"
            }
            return "Rate limited. Please try again later"
        case .toolExecutionFailed(let reason):
            return "Tool execution failed: \(reason)"
        case .unknown(let reason):
            return "Unknown error: \(reason)"
        }
    }

    /// Whether this error is retriable
    public var isRetriable: Bool {
        switch self {
        case .networkError, .rateLimited:
            return true
        case .toolExecutionFailed:
            return true
        case .executionCancelled, .iterationLimitReached:
            return false
        case .unknown:
            return true
        }
    }
}
