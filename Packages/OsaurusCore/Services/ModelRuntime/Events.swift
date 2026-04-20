//
//  Events.swift
//  osaurus
//
//  Typed events emitted by the unified generation pipeline.
//

import Foundation

enum ModelRuntimeEvent: Sendable {
    case tokens(String)
    /// Reasoning text (thinking / chain-of-thought). Currently never emitted
    /// by `GenerationEventMapper` because vmlx-swift-lm's `Generation` enum
    /// does not yet expose a `.reasoning(String)` case — it strips reasoning
    /// internally before yielding `.chunk(_:)`. Wired through the entire
    /// pipeline (HTTP `reasoning_content`, ChatView Think panel, plugin
    /// streaming hint) so that adding a single switch arm in the mapper
    /// when upstream lands the event surfaces reasoning end-to-end.
    case reasoning(String)
    case toolInvocation(name: String, argsJSON: String)
    case completionInfo(tokenCount: Int, tokensPerSecond: Double)
}
