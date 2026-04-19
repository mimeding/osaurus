//
//  SystemPromptTemplates.swift
//  osaurus
//
//  Centralized repository of all system prompt text. Every instruction
//  string sent to the model should be defined here so the full prompt
//  surface can be viewed, compared, and tuned in a single file.
//

import Foundation

public enum SystemPromptTemplates {

    // MARK: - Identity

    public static let defaultIdentity = "You are a helpful AI assistant."

    /// Returns the effective base prompt, falling back to `defaultIdentity`
    /// when the user has not configured one.
    public static func effectiveBasePrompt(_ basePrompt: String) -> String {
        let trimmed = basePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultIdentity : trimmed
    }

    // MARK: - Capability Discovery Nudge

    /// Static guidance appended to the system prompt when `capabilities_search`
    /// / `capabilities_load` are in the active tool set (auto-selection mode).
    /// Tells the model how to recover when its current tool kit is missing
    /// something instead of inventing tool names — works hand-in-hand with
    /// the `toolNotFound` self-heal envelope returned by `ToolRegistry`.
    public static let capabilityDiscoveryNudge = """
        ## Discovering more tools

        Your current tool list is the most relevant subset for this task. \
        If you need a capability that is not listed, call `capabilities_search` \
        with a short description of what you need, then call `capabilities_load` \
        with the returned IDs (e.g. `tool/sandbox_exec`) to make those tools \
        available for the rest of this session. Only call tools that exist \
        in your schema — unknown tools return a `tool not found` error.
        """

    /// Code-style discipline injected into the sandbox section.
    public static let codeStyleGuidance = """
        Code style:
        - Limit changes to what was requested — a bug fix does not warrant adjacent refactoring or style cleanup.
        - Do not add defensive error handling, fallback logic, or input validation for conditions that cannot arise in the current code path.
        - Do not extract helpers or utilities for logic that appears only once.
        - Only add comments when reasoning is genuinely non-obvious — never narrate what the code does.
        - Do not add docstrings, comments, or type annotations to code you did not modify.
        """

    // MARK: - Sandbox

    public static func sandbox(compact: Bool, secretNames: [String] = []) -> String {
        chatSandboxSection(compact: compact, secretNames: secretNames)
    }

    // MARK: Chat sandbox

    private static func chatSandboxSection(compact: Bool, secretNames: [String]) -> String {
        let env = compact ? sandboxEnvironmentBlockCompact : sandboxEnvironmentBlock
        let tools = compact ? sandboxToolGuideCompact : sandboxToolGuide
        let hints = compact ? sandboxRuntimeHintsCompact : sandboxRuntimeHints
        var section = """

            \(sandboxSectionHeading)

            \(env)
            Files persist across messages.

            \(tools)

            \(hints)

            """
        if !compact {
            section += """
                \(sandboxCodeStyle)

                \(sandboxRiskGuidance)

                """
        }
        section += secretsPromptBlock(secretNames)
        return section
    }

    // MARK: - Sandbox Building Blocks

    static let sandboxSectionHeading = "## Linux Sandbox Environment"
    static let sandboxReadFileHint =
        "`sandbox_read_file` with `start_line`/`line_count`/`tail_lines`"

    private static let sandboxEnvironmentBlock = """
        You have access to an isolated Linux sandbox (Alpine Linux, ARM64). \
        Your workspace is your home directory inside the sandbox.

        **IMPORTANT — You have full internet access in this sandbox.** You can \
        use `curl`, `wget`, Python `requests`/`urllib`, Node `fetch`, or any \
        HTTP client to call external APIs, download files, and fetch live data. \
        Do NOT say you lack internet access or cannot reach external services — \
        you can. Always prefer fetching real data over generating fake/placeholder data.

        Pre-installed: bash, python3, node, git, curl, wget, jq, ripgrep (rg), \
        sqlite3, build-base (gcc/make), cmake, vim, tree, and standard POSIX utilities.
        """

    private static let sandboxEnvironmentBlockCompact = """
        Isolated Linux sandbox (Alpine, ARM64). Home dir is your workspace. \
        **You have full internet access.** Use `curl`, Python `requests`, or \
        Node `fetch` to call APIs and download data. Do NOT claim you lack \
        internet — always fetch real data. \
        Pre-installed: bash, python3, node, git, curl, jq, rg, sqlite3, gcc/make, cmake.
        """

    private static let sandboxToolGuide = """
        Tool usage:
        - Use `sandbox_read_file` before editing — never modify code you have not inspected.
        - Use `sandbox_edit_file` for targeted changes (old_string → new_string). Prefer this over rewriting entire files with `sandbox_write_file`.
        - Use `sandbox_write_file` only for new files or complete rewrites.
        - Use `sandbox_find_files` to locate files by name pattern (e.g. `*.py`).
        - Use `sandbox_search_files` to search file contents with regex (ripgrep). Use `sandbox_find_files` for name-based lookup.
        - Use `sandbox_list_directory` with `recursive: true` for project structure overview.
        - Prefer `sandbox_run_script` for multi-line logic (python, bash, node). Use `sandbox_exec` for single shell commands. Use `sandbox_exec_background` for servers, watchers, and long-running processes.
        - Set `timeout` for long operations (default 60 s scripts, 30 s exec, max 300 s).
        - Use dedicated tools instead of shell equivalents: `sandbox_read_file` not `cat`, `sandbox_edit_file` not `sed`, `sandbox_find_files` not `find`.
        - When multiple tool calls have no dependency on each other, issue them in parallel.
        """

    private static let sandboxToolGuideCompact = """
        Tools: `sandbox_read_file` before editing. `sandbox_edit_file` for targeted edits (old_string/new_string) — prefer over full rewrites. \
        `sandbox_find_files` for name patterns, `sandbox_search_files` for content search. \
        `sandbox_run_script` for multi-line scripts; `sandbox_exec` for single commands.
        """

    /// Sandbox section reuses the canonical code-style block exposed at
    /// the top of this file so updates propagate to both surfaces.
    private static let sandboxCodeStyle = codeStyleGuidance

    private static let sandboxRiskGuidance = """
        Risk-aware actions:
        - Local, reversible actions (editing a file, running a test) — proceed without hesitation.
        - Destructive or hard-to-undo actions (deleting files, `rm -rf`, dropping data) — confirm with the user first.
        - When encountering unexpected state (unfamiliar files, unknown processes), investigate before removing anything.
        """

    private static let sandboxRuntimeHints = """
        Runtime hints:
        - Python deps: `sandbox_pip_install` — e.g. `{"packages": ["numpy"]}`.
        - Node deps: `sandbox_npm_install` — e.g. `{"packages": ["express"]}`.
        - System packages: `sandbox_install` — e.g. `{"packages": ["ffmpeg"]}`.
        - Use \(sandboxReadFileHint) to inspect large logs.
        - The sandbox is disposable — experiment freely.
        """

    private static let sandboxRuntimeHintsCompact = """
        `sandbox_pip_install` for Python, `sandbox_npm_install` for Node, `sandbox_install` for system packages.
        """

    private static func secretsPromptBlock(_ names: [String]) -> String {
        guard !names.isEmpty else { return "" }
        let list = names.sorted().map { "- `\($0)`" }.joined(separator: "\n")
        return """
            Configured secrets (available as environment variables):
            \(list)
            Access via `$NAME` in shell, `os.environ["NAME"]` in Python, or `process.env.NAME` in Node.

            """
    }

    // MARK: - Folder Context

    /// Working-directory framing appended to the system prompt when chat
    /// is mounted on a host folder (`ExecutionMode.hostFolder`). Carries
    /// the path, project type, top-level layout, optional git status,
    /// usage guidance, and any project-level context file
    /// (AGENTS.md / CLAUDE.md / .hermes.md / .cursorrules) loaded at
    /// folder-mount time. Returns `""` when no folder is mounted so the
    /// composer can append unconditionally.
    public static func folderContext(from folderContext: FolderContext?) -> String {
        guard let folder = folderContext else { return "" }

        let topLevel = buildTopLevelSummary(from: folder.tree)
        let gitBlock =
            folder.gitStatus.flatMap { status -> String? in
                let trimmed = String(status.prefix(300))
                guard !trimmed.isEmpty else { return nil }
                return "\n**Git status (uncommitted changes):**\n```\n\(trimmed)\n```\n"
            } ?? ""

        var section = """

            ## Working Directory
            **Path:** \(folder.rootPath.path)
            **Project Type:** \(folder.projectType.displayName)
            **Root contents:** \(topLevel)
            \(gitBlock)
            **Tool `path` arguments must be relative to the Working Directory** — pass `README.md`, `src/app.py`, `docs/intro.md`. Absolute paths are rejected (the rule is a security boundary, not a convenience), even ones that point inside the directory. The path above is for your reference when describing the project to the user, not for tool calls.

            Use `file_read`, `file_search`, and `file_list` to explore the project structure. Always read files before editing.

            For multi-step tasks: take the next concrete action each turn — read, write, run. Don't pause to describe what you're going to do; just do it. Stop only when the task is complete or you genuinely need user input.

            **Artifact requests land on disk, not in chat.** When the user asks you to create, save, write, or generate a file (README, script, config, doc, code, etc.), call `file_write` with the file content and tell the user briefly what you wrote. Do NOT paste the file's contents into your reply — the chat is for interaction, the folder is for artifacts. The user can see the file directly.

            """

        // Project-level guidance file (first-found-wins across AGENTS.md,
        // CLAUDE.md, .hermes.md, .cursorrules). Loaded once at folder-mount
        // time and stamped onto the FolderContext so it lives in the static
        // prefix and doesn't break KV-cache reuse across turns. Capped at
        // 20K chars with head+tail truncation by FolderContextService.
        if let contextFiles = folder.contextFiles, !contextFiles.isEmpty {
            section += """

                ## Project Context

                The following project context file has been loaded and should be followed:

                \(contextFiles)

                """
        }

        return section
    }

    private static func buildTopLevelSummary(from tree: String) -> String {
        let lines = tree.components(separatedBy: .newlines)
        let topLevel = lines.compactMap { line -> String? in
            let stripped = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty else { return nil }
            let treeChars = CharacterSet(charactersIn: "│├└─ \u{00A0}")
            let indentPrefix = line.prefix(while: { char in
                char.unicodeScalars.allSatisfy { treeChars.contains($0) }
            })
            guard indentPrefix.count <= 4 else { return nil }
            return stripped.trimmingCharacters(in: treeChars)
        }
        .filter { !$0.isEmpty }

        if topLevel.count <= 8 {
            return topLevel.joined(separator: ", ")
        }
        let shown = topLevel.prefix(6)
        return shown.joined(separator: ", ") + ", and \(topLevel.count - 6) other items"
    }

    // MARK: - Model Classification

    /// Returns true when the model identifier refers to a local model
    /// (Foundation or MLX) that benefits from shorter/compact prompts.
    public static func isLocalModel(_ modelId: String?) -> Bool {
        let trimmed = (modelId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty || trimmed == "default" || trimmed == "foundation" {
            return true
        }
        if trimmed.contains("/") {
            return false
        }
        return ModelManager.findInstalledModel(named: trimmed) != nil
    }
}
