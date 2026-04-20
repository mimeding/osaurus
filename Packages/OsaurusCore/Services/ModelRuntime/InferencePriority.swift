//
//  InferencePriority.swift
//  osaurus
//
//  Priority levels for inference admission. Used by callers (ChatEngine,
//  CoreModelService, plugin host) to hint at how their request should be
//  scheduled relative to others. Today the runtime delegates concurrency
//  management entirely to vmlx-swift-lm's `BatchEngine`, so the priority
//  value is informational — it travels alongside `GenerationParameters` and
//  may be re-introduced into a per-model admission queue later if back-
//  pressure becomes necessary.
//

import Foundation

public enum InferencePriority: Int, Sendable, Comparable, CaseIterable {
    /// Internal background work — preflight capability search, memory
    /// extraction, summarization, anything the user didn't explicitly request.
    case maintenance = 0
    /// Scheduled / detached background tasks (chat dispatched via plugin,
    /// schedule, watcher, or HTTP). The user knows it's running; they
    /// don't expect typing latency from it.
    case background = 25
    /// Live plugin inference (`complete`, `complete_stream`, `embed`). Treated
    /// below interactive so a webhook flood can't starve a user mid-typing.
    case plugin = 50
    /// HTTP API requests from external clients. Bumped above plugins because
    /// users typically have an interactive UI on the other end.
    case httpAPI = 75
    /// Foreground UI typing — the user is actively waiting for tokens to render.
    case interactive = 100

    public static func < (lhs: InferencePriority, rhs: InferencePriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .maintenance: return "maintenance"
        case .background: return "background"
        case .plugin: return "plugin"
        case .httpAPI: return "httpAPI"
        case .interactive: return "interactive"
        }
    }
}
