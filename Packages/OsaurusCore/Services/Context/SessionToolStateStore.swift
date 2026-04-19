//
//  SessionToolStateStore.swift
//  osaurus
//
//  Process-wide store for per-session preflight + always-loaded snapshots.
//  Replaces a duplicated `[id: SessionToolState]` map that previously lived
//  inside both `ChatView` (UUID-keyed) and `PluginHostAPI` (String-keyed).
//
//  Keeping a single store means there is exactly one place to debug "why
//  didn't this tool show up on turn 2?" and one cache invalidation rule
//  when a chat ends. Keys are strings — chat callers pass `UUID.uuidString`,
//  HTTP/plugin callers already use the request `session_id` string.
//

import Foundation

/// Per-session record of the initial preflight selection plus every tool the
/// agent has loaded mid-session via `capabilities_load`. The composer uses
/// this to skip the LLM-based preflight call after turn 1 and to keep the
/// rendered system prompt + `<tools>` block byte-stable across turns
/// (required for KV-cache reuse).
actor SessionToolStateStore {
    static let shared = SessionToolStateStore()

    private var states: [String: SessionToolState] = [:]

    /// Per-session record of the most recent send: turn index + the
    /// cache-hint hex used as the prompt-prefix fingerprint. Lets the
    /// caller log a `[Cache] turn=N hint=... prevHint=... match=...` line
    /// per send so we can audit whether KV reuse is actually happening.
    private var lastSendCacheHint: [String: (turn: Int, hint: String)] = [:]

    private init() {}

    // MARK: - Reads

    func get(_ sessionId: String) -> SessionToolState? {
        states[sessionId]
    }

    // MARK: - Writes

    /// Initialise a session entry on first send. Caller passes the freshly
    /// computed preflight + always-loaded snapshot. Idempotent: if an entry
    /// already exists (e.g. another turn raced ahead) we leave it alone so
    /// the snapshot stays stable.
    func setInitial(
        _ sessionId: String,
        preflight: PreflightResult,
        alwaysLoadedNames: Set<String>?
    ) {
        guard states[sessionId] == nil else { return }
        states[sessionId] = SessionToolState(
            initialPreflight: preflight,
            initialAlwaysLoadedNames: alwaysLoadedNames
        )
    }

    /// Append tool names loaded mid-session (via `capabilities_load` /
    /// `sandbox_plugin_register`). Creates the entry if missing — the
    /// caller supplies a fallback preflight + snapshot so we don't lose
    /// schema stability when the load happens before the first compose
    /// captured a snapshot.
    func appendLoadedTools(
        _ sessionId: String,
        names: [String],
        fallbackPreflight: PreflightResult,
        fallbackAlwaysLoadedNames: Set<String>?
    ) {
        var entry =
            states[sessionId]
            ?? SessionToolState(
                initialPreflight: fallbackPreflight,
                initialAlwaysLoadedNames: fallbackAlwaysLoadedNames
            )
        for name in names { entry.loadedToolNames.insert(name) }
        states[sessionId] = entry
    }

    // MARK: - Cache fingerprint

    /// Record this send's cache-hint, emit a one-line `[Cache]` log entry,
    /// and stamp the matching TTFT trace fields. Lives on the store so the
    /// turn counter + previous-hint comparison sit next to the state they
    /// describe instead of being duplicated at every call site.
    func recordSend(
        sessionId: String,
        cacheHint: String,
        trace: TTFTTrace?
    ) {
        let prev = lastSendCacheHint[sessionId]
        let turn = (prev?.turn ?? 0) + 1
        lastSendCacheHint[sessionId] = (turn: turn, hint: cacheHint)

        let prevHintForLog = prev?.hint ?? "-"
        let matchStr: String
        if let prevHint = prev?.hint {
            matchStr = (prevHint == cacheHint) ? "true" : "false"
        } else {
            matchStr = "n/a"
        }
        debugLog(
            "[Cache] turn=\(turn) hint=\(cacheHint) prevHint=\(prevHintForLog) match=\(matchStr)"
        )
        trace?.set("cacheHint", cacheHint)
        trace?.set("cacheTurn", turn)
        trace?.set("cacheHintMatched", matchStr == "true" ? "1" : (matchStr == "n/a" ? "n/a" : "0"))
    }

    // MARK: - Invalidation

    /// Drop the session's record. Call from chat-window close or HTTP
    /// session teardown so old state doesn't leak between conversations.
    func invalidate(_ sessionId: String) {
        states.removeValue(forKey: sessionId)
        lastSendCacheHint.removeValue(forKey: sessionId)
    }

    /// Reset everything (test helper).
    func reset() {
        states.removeAll()
        lastSendCacheHint.removeAll()
    }
}
