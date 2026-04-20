//
//  StreamingMiddleware.swift
//  osaurus
//
//  Transforms raw streaming deltas before they reach `StreamingDeltaProcessor`.
//
//  Historically osaurus needed model-specific delta rewriting (e.g. prepend
//  a missing `<think>` opener for GLM/Qwen3.5 templates that only emit the
//  closing `</think>` tag). That logic became unnecessary once the engine
//  layer started owning reasoning extraction:
//    - Local MLX: vmlx-swift-lm's `BatchEngine.generate` strips reasoning
//      segments and emits pure text on `.chunk(_:)`.
//    - Remote providers: `RemoteProviderService` re-emits provider-side
//      `reasoning_content` via `StreamingReasoningHint.encode`.
//  The protocol is preserved so any future per-model rewrite can be slotted
//  in without re-plumbing the resolver call site.
//

/// Transforms raw streaming deltas before they reach the processor.
/// Stateful — create a new instance per streaming session.
@MainActor
protocol StreamingMiddleware: AnyObject {
    func process(_ delta: String) -> String
}

// MARK: - Resolver

enum StreamingMiddlewareResolver {
    @MainActor
    static func resolve(
        for modelId: String,
        modelOptions: [String: ModelOptionValue] = [:]
    ) -> StreamingMiddleware? {
        // No active middleware today — engine layer owns reasoning extraction.
        // Returning nil keeps the call site cheap (single nil check per delta).
        _ = modelId
        _ = modelOptions
        return nil
    }
}
