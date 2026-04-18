//
//  SystemPromptComposer.swift
//  osaurus
//
//  Builder for structured system prompt assembly. Provides both low-level
//  section-by-section composition and high-level single-call methods
//  (composeChatContext, composeWorkPrompt) that handle the full pipeline.
//
//  Compact prompt selection is automatic: pass the model ID and the composer
//  resolves whether to use compact or full prompt variants via isLocalModel.
//

import Foundation

// MARK: - SystemPromptComposer

/// Assembles system prompt sections in order, producing both the rendered
/// prompt string and a `PromptManifest` for budget tracking and caching.
public struct SystemPromptComposer: Sendable {

    private var sections: [PromptSection] = []

    public init() {}

    // MARK: - Low-Level API

    public mutating func append(_ section: PromptSection) {
        guard !section.isEmpty else { return }
        sections.append(section)
    }

    public func render() -> String {
        sections
            .map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    public func manifest() -> PromptManifest {
        PromptManifest(sections: sections.filter { !$0.isEmpty })
    }

    @MainActor
    public mutating func appendBasePrompt(agentId: UUID) {
        let raw = AgentManager.shared.effectiveSystemPrompt(for: agentId)
        let effective = SystemPromptTemplates.effectiveBasePrompt(raw)
        append(.static(id: "base", label: "Base Prompt", content: effective))
    }

    // MARK: - Memory Assembly

    /// Assemble the memory snippet for an agent. Returns `nil` when memory
    /// is disabled, blank, or empty after trimming. Centralised so chat,
    /// work, and HTTP paths all produce the same output and the rest of
    /// the composer never needs to know about the two `assembleContext`
    /// overloads.
    static func assembleMemorySection(
        agentId: String,
        query: String? = nil,
        toolsAvailable: Bool = true
    ) async -> String? {
        let config = MemoryConfigurationStore.load()
        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let assembled: String
        if let trimmedQuery, !trimmedQuery.isEmpty {
            assembled = await MemoryContextAssembler.assembleContext(
                agentId: agentId,
                config: config,
                query: trimmedQuery,
                toolsAvailable: toolsAvailable
            )
        } else {
            assembled = await MemoryContextAssembler.assembleContext(
                agentId: agentId,
                config: config,
                toolsAvailable: toolsAvailable
            )
        }
        let trimmed = assembled.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : assembled
    }

    // MARK: - High-Level API

    /// Compose the full chat context: prompt + tools + manifest in one call.
    ///
    /// `query` is used to seed pre-flight capability search. If `query` is
    /// empty, the most recent `"user"` message in `messages` is used as a
    /// fallback so retries / regenerations still drive preflight.
    ///
    /// Pass `cachedPreflight` from a per-session `SessionToolState` to skip
    /// the LLM-based selection (it only ever needs to run on the first send
    /// of a session). Pass `additionalToolNames` to merge tools the agent has
    /// loaded mid-session via `capabilities_load`, so they survive across
    /// subsequent composes.
    @MainActor
    static func composeChatContext(
        agentId: UUID,
        executionMode: WorkExecutionMode,
        model: String? = nil,
        query: String = "",
        messages: [ChatMessage] = [],
        toolsDisabled: Bool = false,
        cachedPreflight: PreflightResult? = nil,
        additionalToolNames: Set<String> = [],
        trace: TTFTTrace? = nil
    ) async -> ComposedContext {
        trace?.mark("compose_context_start")
        let composer = forChat(agentId: agentId, executionMode: executionMode, model: model)
        let result = await finalizeContext(
            composer: composer,
            agentId: agentId,
            executionMode: executionMode,
            query: resolvePreflightQuery(query: query, messages: messages),
            toolsDisabled: toolsDisabled,
            cachedPreflight: cachedPreflight,
            additionalToolNames: additionalToolNames,
            model: model,
            trace: trace
        )
        trace?.mark("compose_context_done")
        return result
    }

    /// Derive the effective preflight query: prefer the explicit `query`, else
    /// the most recent user message text. Returns "" if neither is available.
    static func resolvePreflightQuery(query: String, messages: [ChatMessage]) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        for msg in messages.reversed() where msg.role == "user" {
            if let content = msg.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                !content.isEmpty
            {
                return content
            }
        }
        return ""
    }

    /// Shared pipeline: assemble memory (returned separately) + preflight +
    /// skills + resolve tools + build ComposedContext.
    ///
    /// Memory is intentionally NOT appended into the system prompt. It is
    /// surfaced on `ComposedContext.memorySection` so callers prepend it to
    /// the latest user message — that keeps the system prompt byte-stable
    /// across turns once preflight is cached, which lets the MLX paged KV
    /// cache reuse the entire conversation prefix.
    @MainActor
    private static func finalizeContext(
        composer: SystemPromptComposer,
        agentId: UUID,
        executionMode: WorkExecutionMode,
        query: String,
        toolsDisabled: Bool,
        cachedPreflight: PreflightResult? = nil,
        additionalToolNames: Set<String> = [],
        model: String? = nil,
        trace: TTFTTrace? = nil
    ) async -> ComposedContext {
        var comp = composer

        let effectiveToolsOff = toolsDisabled || AgentManager.shared.effectiveToolsDisabled(for: agentId)
        let memoryOff = AgentManager.shared.effectiveMemoryDisabled(for: agentId)
        let autonomousEnabled = AgentManager.shared.effectiveAutonomousExec(for: agentId)?.enabled == true
        let toolMode = AgentManager.shared.effectiveToolSelectionMode(for: agentId)

        // Memory is assembled here but returned separately (see ComposedContext.memorySection).
        // We deliberately do NOT pass `query` so the cached memory snapshot
        // can be reused even when the user's wording shifts — preserves the
        // pre-split behaviour and avoids a per-turn embedding lookup.
        trace?.mark("memory_start")
        let memorySection: String? =
            memoryOff
            ? nil
            : await assembleMemorySection(
                agentId: agentId.uuidString,
                toolsAvailable: !effectiveToolsOff
            )
        trace?.mark("memory_done")

        // Surface a "sandbox unavailable" notice when the agent wants
        // sandbox tools but registration couldn't provide them — otherwise
        // the model hallucinates sandbox calls that never get a result.
        if !executionMode.usesSandboxTools,
            autonomousEnabled,
            let reason = SandboxToolRegistrar.shared.unavailabilityReason(for: agentId)
        {
            comp.append(
                .dynamic(
                    id: "sandboxUnavailable",
                    label: "Sandbox Unavailable",
                    content: Self.sandboxUnavailableNotice(reason: reason)
                )
            )
            trace?.set("sandboxUnavailable", reason.kind.rawValue)
        }

        let preflight: PreflightResult
        if let cachedPreflight {
            preflight = cachedPreflight
            trace?.set("preflightSource", "cached")
        } else if !effectiveToolsOff && toolMode == .auto && !query.isEmpty {
            let mode = ChatConfigurationStore.load().preflightSearchMode ?? .balanced
            trace?.mark("preflight_search_start")
            preflight = await PreflightCapabilitySearch.search(query: query, mode: mode, agentId: agentId)
            trace?.mark("preflight_search_done")
            trace?.set("preflightSource", "fresh")
        } else {
            preflight = .empty
            trace?.set("preflightSource", "skipped")
        }

        if toolMode == .manual,
            let section = await SkillManager.shared.manualSkillPromptSection(for: agentId)
        {
            comp.append(.dynamic(id: "skills", label: "Skills", content: section))
        }

        trace?.mark("resolve_tools_start")
        let tools = resolveTools(
            agentId: agentId,
            executionMode: executionMode,
            toolsDisabled: effectiveToolsOff,
            preflight: preflight,
            additionalToolNames: additionalToolNames
        )
        trace?.mark("resolve_tools_done")

        // Capability-discovery nudge: explain how to recover when the
        // current tool kit is incomplete. Gated to auto mode + presence of
        // `capabilities_search` so manual-mode agents and tools-disabled
        // sessions don't see irrelevant guidance. Static section so it
        // contributes to the cached prefix.
        if toolMode == .auto,
            !effectiveToolsOff,
            tools.contains(where: { $0.function.name == "capabilities_search" })
        {
            comp.append(
                .static(
                    id: "capabilityNudge",
                    label: "Capability Discovery",
                    content: SystemPromptTemplates.capabilityDiscoveryNudge
                )
            )
        }

        // Plugin-creator backstop: only inject when the agent literally
        // has NO dynamic tools available (no MCP / plugin / sandbox-plugin
        // installed) AND nothing was resolved this turn. The narrower gate
        // prevents the skill from being injected on every "this turn just
        // doesn't need a plugin" case for users who already have plugin
        // tools installed — which would bias the model toward writing new
        // plugins instead of using the ones it has.
        if !effectiveToolsOff,
            executionMode.usesSandboxTools,
            ToolRegistry.shared.dynamicCatalogIsEmpty(),
            !hasDynamicTools(toolMode: toolMode, preflight: preflight, agentId: agentId),
            let pluginCreator = await PreflightCapabilitySearch.pluginCreatorSkillSection(for: agentId)
        {
            comp.append(.dynamic(id: "pluginCreator", label: "Plugin Creator", content: pluginCreator))
            trace?.set("pluginCreatorInjected", "1")
        }

        let manifest = comp.manifest()
        let toolNames = tools.map { $0.function.name }
        debugLog("[Context] \(manifest.debugDescription)")
        emitToolDiagnostics(
            tools: tools,
            toolMode: toolMode,
            preflight: preflight,
            executionMode: executionMode,
            autonomousEnabled: autonomousEnabled,
            effectiveToolsOff: effectiveToolsOff,
            trace: trace
        )

        let rendered = comp.render()
        trace?.set("systemPromptChars", rendered.count)
        trace?.set("toolCount", tools.count)
        trace?.set("preflightItems", preflight.items.count)

        return ComposedContext(
            prompt: rendered,
            manifest: manifest,
            tools: tools,
            toolTokens: ToolRegistry.shared.totalEstimatedTokens(for: tools),
            preflightItems: preflight.items,
            preflight: preflight,
            memorySection: memorySection,
            cacheHint: manifest.staticPrefixHash(toolNames: toolNames),
            staticPrefix: manifest.staticPrefixContent
        )
    }

    private static func sandboxUnavailableNotice(
        reason: SandboxToolRegistrar.UnavailabilityReason
    ) -> String {
        """
        ## Sandbox unavailable

        The user has enabled autonomous execution for this chat, but the \
        sandbox container is not currently available, so sandbox tools \
        (file IO, shell, etc.) are NOT in your tool list this turn. \
        Reason: \(reason.message)

        Do not attempt to call any sandbox tool by name; you will not \
        receive a result. Tell the user briefly that the sandbox is \
        unavailable and what they could try (e.g. check the sandbox \
        container status), then proceed with text-only assistance.
        """
    }

    /// Emit structured tool diagnostics so silent "model can't see the
    /// tools" failures are visible in logs and traces.
    @MainActor
    private static func emitToolDiagnostics(
        tools: [Tool],
        toolMode: ToolSelectionMode,
        preflight: PreflightResult,
        executionMode: WorkExecutionMode,
        autonomousEnabled: Bool,
        effectiveToolsOff: Bool,
        trace: TTFTTrace?
    ) {
        let toolSource: String
        if effectiveToolsOff {
            toolSource = "disabled"
        } else if !preflight.toolSpecs.isEmpty {
            toolSource = "preflight"
        } else if toolMode == .manual {
            toolSource = "manual"
        } else {
            toolSource = "alwaysLoaded"
        }
        let sandboxStatus = String(describing: SandboxManager.State.shared.status)
        let sortedNames = tools.map { $0.function.name }.sorted()
        debugLog(
            "[Context:tools] mode=\(toolMode) source=\(toolSource) autonomous=\(autonomousEnabled) sandboxStatus=\(sandboxStatus) executionMode=\(executionMode) count=\(tools.count) names=[\(sortedNames.joined(separator: ", "))]"
        )
        if autonomousEnabled && tools.isEmpty {
            debugLog(
                "[Context:tools] WARNING: autonomous execution is enabled but the resolved tool list is empty. The model will not be able to act on the user's request. Check sandbox container status (\(sandboxStatus))."
            )
        }
        trace?.set("toolMode", String(describing: toolMode))
        trace?.set("toolSource", toolSource)
        trace?.set("autonomous", autonomousEnabled ? "1" : "0")
        trace?.set("sandboxStatus", sandboxStatus)
    }

    /// Did the current request resolve any dynamic (non-always-loaded,
    /// non-sandbox-builtin) tool via preflight or manual selection? Used by
    /// `finalizeContext` to decide whether to inject the plugin-creator
    /// fallback skill.
    @MainActor
    private static func hasDynamicTools(
        toolMode: ToolSelectionMode,
        preflight: PreflightResult,
        agentId: UUID
    ) -> Bool {
        switch toolMode {
        case .auto:
            return !preflight.toolSpecs.isEmpty
        case .manual:
            let names = AgentManager.shared.effectiveManualToolNames(for: agentId) ?? []
            return !names.isEmpty
        }
    }

    /// Resolve the full tool set for a request: built-in + preflight/manual,
    /// plus any tools the agent has loaded mid-session via `capabilities_load`,
    /// deduped, then sorted into a stable canonical order.
    ///
    /// Manual mode is strict: only the user's explicitly selected tools are
    /// included, with one exception — when `executionMode` requires sandbox
    /// tools (autonomous execution), the sandbox built-ins are always added so
    /// the agent can act. Group 1 (selection) and Group 2 (sandbox) are
    /// orthogonal: enabling sandbox does not weaken the manual selection in
    /// any other way.
    ///
    /// `additionalToolNames` is honoured in both modes so tools the agent has
    /// already loaded mid-session survive across composes (the chat / work
    /// session caches feed this from their `SessionToolState`).
    ///
    /// Output is sorted via `canonicalToolOrder` so the chat-template-rendered
    /// `<tools>` block is byte-stable across sends — required for the MLX
    /// paged KV cache to reuse the prefix.
    @MainActor
    static func resolveTools(
        agentId: UUID,
        executionMode: WorkExecutionMode,
        toolsDisabled: Bool = false,
        preflight: PreflightResult = .empty,
        additionalToolNames: Set<String> = []
    ) -> [Tool] {
        guard !toolsDisabled else { return [] }

        let toolMode = AgentManager.shared.effectiveToolSelectionMode(for: agentId)
        let isManual = toolMode == .manual

        var byName: [String: Tool] = [:]

        func add(_ specs: [Tool]) {
            for spec in specs where byName[spec.function.name] == nil {
                byName[spec.function.name] = spec
            }
        }

        if isManual {
            if executionMode.usesSandboxTools {
                add(ToolRegistry.shared.sandboxBuiltInSpecs(mode: executionMode))
            }
            if let manualNames = AgentManager.shared.effectiveManualToolNames(for: agentId) {
                add(ToolRegistry.shared.specs(forTools: manualNames))
            }
        } else {
            add(ToolRegistry.shared.alwaysLoadedSpecs(mode: executionMode))
            add(preflight.toolSpecs)
        }

        if !additionalToolNames.isEmpty {
            add(ToolRegistry.shared.specs(forTools: Array(additionalToolNames)))
        }

        return canonicalToolOrder(Array(byName.values))
    }

    /// Stable order: built-in sandbox tools (alphabetical) first, then the
    /// fixed-order capability tools, then everything else alphabetically.
    /// The fixed capability order keeps `capabilities_search` at the head
    /// of its group so the model sees the discovery tool before the loader.
    @MainActor
    static func canonicalToolOrder(_ tools: [Tool]) -> [Tool] {
        let sandboxNames = ToolRegistry.shared.builtInSandboxToolNamesSnapshot
        let capabilityIndex = Dictionary(
            uniqueKeysWithValues: ["capabilities_search", "capabilities_load", "methods_save", "methods_report"]
                .enumerated().map { ($1, $0) }
        )

        // Sort key: (bucket, capability-order index, name). `Int.max` for
        // non-capability tools collapses the index dimension to a no-op,
        // leaving the alphabetical name as the tiebreaker.
        func sortKey(_ tool: Tool) -> (Int, Int, String) {
            let name = tool.function.name
            if sandboxNames.contains(name) { return (0, .max, name) }
            if let order = capabilityIndex[name] { return (1, order, name) }
            return (2, .max, name)
        }

        return tools.sorted { sortKey($0) < sortKey($1) }
    }

    /// Compose the full work system prompt: base + workMode + sandbox.
    @MainActor
    public static func composeWorkPrompt(
        agentId: UUID,
        executionMode: WorkExecutionMode,
        model: String? = nil,
        secretNames: [String] = []
    ) -> (prompt: String, manifest: PromptManifest) {
        let compact = resolveCompact(model: model, agentId: agentId)
        let composer = forWork(
            agentId: agentId,
            executionMode: executionMode,
            compact: compact,
            secretNames: secretNames
        )
        return (composer.render(), composer.manifest())
    }

    /// Compose a work prompt from a pre-resolved base string (e.g. base+memory from WorkEngine).
    public static func composeWorkPrompt(
        base: String,
        executionMode: WorkExecutionMode,
        model: String? = nil,
        secretNames: [String] = []
    ) -> (prompt: String, manifest: PromptManifest) {
        let compact = model.map { SystemPromptTemplates.isLocalModel($0) } ?? false
        let composer = forWork(base: base, executionMode: executionMode, compact: compact, secretNames: secretNames)
        return (composer.render(), composer.manifest())
    }

    /// Full work context: base + workMode + sandbox + tools, with memory and
    /// preflight returned on the result so callers can cache preflight per
    /// issue and prepend memory to the latest user message.
    @MainActor
    static func composeWorkContext(
        agentId: UUID,
        executionMode: WorkExecutionMode,
        model: String? = nil,
        secretNames: [String] = [],
        query: String = "",
        toolsDisabled: Bool = false,
        cachedPreflight: PreflightResult? = nil,
        additionalToolNames: Set<String> = []
    ) async -> ComposedContext {
        let compact = resolveCompact(model: model, agentId: agentId)
        let composer = forWork(
            agentId: agentId,
            executionMode: executionMode,
            compact: compact,
            secretNames: secretNames
        )
        return await finalizeContext(
            composer: composer,
            agentId: agentId,
            executionMode: executionMode,
            query: query,
            toolsDisabled: toolsDisabled,
            cachedPreflight: cachedPreflight,
            additionalToolNames: additionalToolNames
        )
    }

    /// Compose from a pre-resolved base with an optional dynamic skills section.
    public static func composePrompt(
        base: String,
        skillSection: String? = nil
    ) -> (prompt: String, manifest: PromptManifest) {
        var composer = SystemPromptComposer()
        composer.append(.static(id: "base", label: "System Prompt", content: base))
        if let section = skillSection {
            composer.append(.dynamic(id: "skills", label: "Skills", content: section))
        }
        return (composer.render(), composer.manifest())
    }

    /// Compose agent base prompt and inject into an existing message array.
    /// Memory is now prepended to the latest user message instead of the
    /// system prompt so the system message stays byte-stable across turns.
    /// Returns `(cacheHint, staticPrefix)` for the caller to set on the request.
    @discardableResult
    static func injectAgentContext(
        agentId: UUID,
        query: String = "",
        into messages: inout [ChatMessage]
    ) async -> (cacheHint: String, staticPrefix: String) {
        // only forChat needs @MainActor. so hop there briefly and return the value type composer.
        // Memory assembly itself runs on the cooperative thread pool so the
        // app stays responsive during HTTP requests.
        let composer = await MainActor.run { forChat(agentId: agentId, executionMode: .none) }
        let toolsOff = await AgentManager.shared.effectiveToolsDisabled(for: agentId)
        let memoryOff = await AgentManager.shared.effectiveMemoryDisabled(for: agentId)

        let memorySection: String? =
            memoryOff
            ? nil
            : await assembleMemorySection(
                agentId: agentId.uuidString,
                query: query,
                toolsAvailable: !toolsOff
            )

        let manifest = composer.manifest()
        let rendered = composer.render()
        debugLog("[Context:inject] \(manifest.debugDescription)")
        if !rendered.isEmpty {
            injectSystemContent(rendered, into: &messages)
        }
        injectMemoryPrefix(memorySection, into: &messages)
        return (manifest.staticPrefixHash(toolNames: []), manifest.staticPrefixContent)
    }

    // MARK: - Compact Resolution

    /// Resolve whether to use compact prompts from an explicit model ID,
    /// falling back to the agent's configured default model.
    @MainActor
    static func resolveCompact(model: String? = nil, agentId: UUID? = nil) -> Bool {
        if let model { return SystemPromptTemplates.isLocalModel(model) }
        if let agentId, let agentModel = AgentManager.shared.effectiveModel(for: agentId) {
            return SystemPromptTemplates.isLocalModel(agentModel)
        }
        return false
    }

    // MARK: - Factory Methods

    /// Pre-loaded composer for chat mode. Compact is auto-resolved from model/agent.
    @MainActor
    public static func forChat(
        agentId: UUID,
        executionMode: WorkExecutionMode,
        model: String? = nil
    ) -> SystemPromptComposer {
        let compact = resolveCompact(model: model, agentId: agentId)
        return forChat(agentId: agentId, executionMode: executionMode, compact: compact)
    }

    @MainActor
    static func forChat(
        agentId: UUID,
        executionMode: WorkExecutionMode,
        compact: Bool
    ) -> SystemPromptComposer {
        var composer = SystemPromptComposer()
        composer.appendBasePrompt(agentId: agentId)
        if executionMode.usesSandboxTools {
            let secretNames = Array(AgentSecretsKeychain.getAllSecrets(agentId: agentId).keys)
            composer.append(
                .static(
                    id: "sandbox",
                    label: "Chat Sandbox",
                    content: SystemPromptTemplates.sandbox(mode: .chat, compact: compact, secretNames: secretNames)
                )
            )
        }
        return composer
    }

    @MainActor
    static func forWork(
        agentId: UUID,
        executionMode: WorkExecutionMode,
        compact: Bool,
        secretNames: [String] = []
    ) -> SystemPromptComposer {
        var composer = SystemPromptComposer()
        composer.appendBasePrompt(agentId: agentId)
        return composer.withWorkSections(executionMode: executionMode, compact: compact, secretNames: secretNames)
    }

    static func forWork(
        base: String,
        executionMode: WorkExecutionMode,
        compact: Bool,
        secretNames: [String] = []
    ) -> SystemPromptComposer {
        var composer = SystemPromptComposer()
        composer.append(.static(id: "base", label: "Base Prompt", content: base))
        return composer.withWorkSections(executionMode: executionMode, compact: compact, secretNames: secretNames)
    }

    private func withWorkSections(
        executionMode: WorkExecutionMode,
        compact: Bool,
        secretNames: [String]
    ) -> SystemPromptComposer {
        let variant: SystemPromptTemplates.WorkModeVariant = compact ? .compact : .full
        var result = self
        result.append(
            .static(
                id: "workMode",
                label: "Work Mode",
                content: SystemPromptTemplates.workMode(variant, hasSandbox: executionMode.usesSandboxTools)
            )
        )
        if case .sandbox = executionMode {
            result.append(
                .static(
                    id: "sandbox",
                    label: "Sandbox",
                    content: SystemPromptTemplates.sandbox(mode: .work, compact: compact, secretNames: secretNames)
                )
            )
        }
        return result
    }

    // MARK: - Message Array Helpers

    /// Prepend a memory snippet to the latest user message instead of
    /// stuffing it into the system prompt. This keeps the system message
    /// byte-stable across turns (so the MLX paged KV cache can reuse the
    /// entire conversation prefix) and confines memory churn to the volatile
    /// user-message suffix. No-op when `memorySection` is nil/blank, no user
    /// message exists, or the latest user message is multimodal (we leave
    /// `contentParts`-bearing messages alone to avoid silently dropping
    /// images).
    static func injectMemoryPrefix(
        _ memorySection: String?,
        into messages: inout [ChatMessage]
    ) {
        guard let memorySection,
            case let trimmed = memorySection.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty,
            let idx = messages.lastIndex(where: { $0.role == "user" })
        else { return }

        let existing = messages[idx]
        guard existing.contentParts == nil else { return }

        let original = existing.content ?? ""
        let prefixed = "[Memory]\n\(trimmed)\n[/Memory]\n\n\(original)"
        messages[idx] = ChatMessage(
            role: existing.role,
            content: prefixed,
            tool_calls: existing.tool_calls,
            tool_call_id: existing.tool_call_id
        )
    }

    static func injectSystemContent(
        _ content: String,
        into messages: inout [ChatMessage]
    ) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let idx = messages.firstIndex(where: { $0.role == "system" }),
            let existing = messages[idx].content, !existing.isEmpty
        {
            messages[idx] = ChatMessage(role: "system", content: trimmed + "\n\n" + existing)
        } else {
            messages.insert(ChatMessage(role: "system", content: trimmed), at: 0)
        }
    }

    static func appendSystemContent(
        _ content: String,
        into messages: inout [ChatMessage]
    ) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let idx = messages.firstIndex(where: { $0.role == "system" }),
            let existing = messages[idx].content, !existing.isEmpty
        {
            messages[idx] = ChatMessage(role: "system", content: existing + "\n\n" + trimmed)
        } else {
            messages.insert(ChatMessage(role: "system", content: trimmed), at: 0)
        }
    }
}
