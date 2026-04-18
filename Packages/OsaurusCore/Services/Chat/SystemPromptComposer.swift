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

    public mutating func appendMemory(
        agentId: String,
        query: String? = nil,
        toolsAvailable: Bool = true
    ) async {
        let config = MemoryConfigurationStore.load()
        let context: String
        if let query, !query.isEmpty {
            context = await MemoryContextAssembler.assembleContext(
                agentId: agentId,
                config: config,
                query: query,
                toolsAvailable: toolsAvailable
            )
        } else {
            context = await MemoryContextAssembler.assembleContext(
                agentId: agentId,
                config: config,
                toolsAvailable: toolsAvailable
            )
        }
        append(.dynamic(id: "memory", label: "Memory", content: context))
    }

    // MARK: - High-Level API

    /// Compose the full chat context: prompt + tools + manifest in one call.
    ///
    /// `query` is used to seed pre-flight capability search. If `query` is
    /// empty, the most recent `"user"` message in `messages` is used as a
    /// fallback so retries / regenerations still drive preflight.
    @MainActor
    static func composeChatContext(
        agentId: UUID,
        executionMode: WorkExecutionMode,
        model: String? = nil,
        query: String = "",
        messages: [ChatMessage] = [],
        toolsDisabled: Bool = false,
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

    /// Shared pipeline: append memory + preflight + skills + resolve tools + build ComposedContext.
    @MainActor
    private static func finalizeContext(
        composer: SystemPromptComposer,
        agentId: UUID,
        executionMode: WorkExecutionMode,
        query: String,
        toolsDisabled: Bool,
        model: String? = nil,
        trace: TTFTTrace? = nil
    ) async -> ComposedContext {
        var comp = composer

        let effectiveToolsOff = toolsDisabled || AgentManager.shared.effectiveToolsDisabled(for: agentId)
        let memoryOff = AgentManager.shared.effectiveMemoryDisabled(for: agentId)
        let autonomousEnabled = AgentManager.shared.effectiveAutonomousExec(for: agentId)?.enabled == true
        let toolMode = AgentManager.shared.effectiveToolSelectionMode(for: agentId)

        trace?.mark("memory_start")
        if !memoryOff {
            await comp.appendMemory(
                agentId: agentId.uuidString,
                toolsAvailable: !effectiveToolsOff
            )
        }
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
        if !effectiveToolsOff && toolMode == .auto && !query.isEmpty {
            let mode = ChatConfigurationStore.load().preflightSearchMode ?? .balanced
            trace?.mark("preflight_search_start")
            preflight = await PreflightCapabilitySearch.search(query: query, mode: mode, agentId: agentId)
            trace?.mark("preflight_search_done")
        } else {
            preflight = .empty
        }
        comp.append(.dynamic(id: "preflight", label: "Pre-flight RAG", content: preflight.contextSnippet))

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
            preflight: preflight
        )
        trace?.mark("resolve_tools_done")

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

    /// Resolve the full tool set for a request: built-in + preflight/manual, deduped.
    ///
    /// Manual mode is strict: only the user's explicitly selected tools are
    /// included, with one exception — when `executionMode` requires sandbox
    /// tools (autonomous execution), the sandbox built-ins are always added so
    /// the agent can act. Group 1 (selection) and Group 2 (sandbox) are
    /// orthogonal: enabling sandbox does not weaken the manual selection in
    /// any other way.
    @MainActor
    static func resolveTools(
        agentId: UUID,
        executionMode: WorkExecutionMode,
        toolsDisabled: Bool = false,
        preflight: PreflightResult = .empty
    ) -> [Tool] {
        guard !toolsDisabled else { return [] }

        let toolMode = AgentManager.shared.effectiveToolSelectionMode(for: agentId)
        let isManual = toolMode == .manual

        if isManual {
            var tools: [Tool] = []
            var seen = Set<String>()
            if executionMode.usesSandboxTools {
                for spec in ToolRegistry.shared.sandboxBuiltInSpecs(mode: executionMode)
                where seen.insert(spec.function.name).inserted {
                    tools.append(spec)
                }
            }
            if let manualNames = AgentManager.shared.effectiveManualToolNames(for: agentId) {
                for spec in ToolRegistry.shared.specs(forTools: manualNames)
                where seen.insert(spec.function.name).inserted {
                    tools.append(spec)
                }
            }
            return tools
        }

        var tools = ToolRegistry.shared.alwaysLoadedSpecs(mode: executionMode)
        var seen = Set(tools.map { $0.function.name })

        for spec in preflight.toolSpecs
        where seen.insert(spec.function.name).inserted {
            tools.append(spec)
        }

        return tools
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

    /// Full work context: base + workMode + sandbox + memory + tools.
    /// Memory is correctly classified as dynamic for prefix cache optimization.
    @MainActor
    static func composeWorkContext(
        agentId: UUID,
        executionMode: WorkExecutionMode,
        model: String? = nil,
        secretNames: [String] = [],
        query: String = "",
        toolsDisabled: Bool = false
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
            toolsDisabled: toolsDisabled
        )
    }

    /// Compose from a pre-resolved base with optional dynamic sections (preflight, skills).
    public static func composePrompt(
        base: String,
        preflightSnippet: String = "",
        skillSection: String? = nil
    ) -> (prompt: String, manifest: PromptManifest) {
        var composer = SystemPromptComposer()
        composer.append(.static(id: "base", label: "System Prompt", content: base))
        composer.append(.dynamic(id: "preflight", label: "Pre-flight RAG", content: preflightSnippet))
        if let section = skillSection {
            composer.append(.dynamic(id: "skills", label: "Skills", content: section))
        }
        return (composer.render(), composer.manifest())
    }

    /// Compose agent context (base prompt + memory) and inject into an existing message array.
    /// Returns `(cacheHint, staticPrefix)` for the caller to set on the request.
    @discardableResult
    static func injectAgentContext(
        agentId: UUID,
        query: String = "",
        into messages: inout [ChatMessage]
    ) async -> (cacheHint: String, staticPrefix: String) {
        // only forChat needs @MainActor. so hop there briefly and return the value type composer.
        // appendMemory (memory search + embeddings) then runs on the cooperative thread pool to
        // keep the mac app responsive during HTTP API requests
        var composer = await MainActor.run { forChat(agentId: agentId, executionMode: .none) }
        let toolsOff = await AgentManager.shared.effectiveToolsDisabled(for: agentId)
        await composer.appendMemory(
            agentId: agentId.uuidString,
            query: query.isEmpty ? nil : query,
            toolsAvailable: !toolsOff
        )
        let manifest = composer.manifest()
        let rendered = composer.render()
        debugLog("[Context:inject] \(manifest.debugDescription)")
        if !rendered.isEmpty {
            injectSystemContent(rendered, into: &messages)
        }
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
