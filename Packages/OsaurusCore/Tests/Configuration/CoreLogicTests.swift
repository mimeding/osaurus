//
//  CoreLogicTests.swift
//  osaurusTests
//
//  Unit tests for the core logic paths added across Phases A through E.
//  Complements MigrationCompatTests.swift which focuses on JSON decoder
//  backward compatibility. This file tests pure behavior — state machine
//  transitions, substitution logic, and resolver precedence — without
//  touching disk or SwiftUI.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Chip cycle state machine (Phase C M-11)

@Suite("Tools chip cycle state machine")
struct ToolsChipCycleTests {

    /// Starting from nil (follow global), first tap should produce an
    /// explicit override equal to `!globalDisabled` — i.e. the opposite
    /// of whatever the global flag currently says. This is the "first
    /// visible override" step the user sees.

    @Test("nil + global-disabled-true → false (override to enabled)")
    func nilWithGlobalDisabledTrueBecomesFalse() {
        let next = FloatingInputCard.nextToolsOverrideState(
            current: nil,
            globalDisabled: true
        )
        #expect(next == false, "first tap when tools are off globally should force them on")
    }

    @Test("nil + global-disabled-false → true (override to disabled)")
    func nilWithGlobalDisabledFalseBecomesTrue() {
        let next = FloatingInputCard.nextToolsOverrideState(
            current: nil,
            globalDisabled: false
        )
        #expect(next == true, "first tap when tools are on globally should force them off")
    }

    /// Starting from an explicit override that differs from global, second
    /// tap should move to match global — still an explicit override, but
    /// now aligned with the global state. Feedback that the tap did something.

    @Test("override=false + global=true → true (flip to match global)")
    func explicitOverrideDifferingFromGlobalFlipsToMatch() {
        let next = FloatingInputCard.nextToolsOverrideState(
            current: false,
            globalDisabled: true
        )
        #expect(next == true, "second tap should move from 'force on' to 'force off matching global'")
    }

    @Test("override=true + global=false → false (flip to match global)")
    func explicitOverrideDifferingFromGlobalFlipsToMatchFalse() {
        let next = FloatingInputCard.nextToolsOverrideState(
            current: true,
            globalDisabled: false
        )
        #expect(next == false, "second tap should move from 'force off' to 'force on matching global'")
    }

    /// Starting from an explicit override that matches global, third tap
    /// should clear back to nil (follow global). Completes the three-state cycle.

    @Test("override=true + global=true → nil (clear to follow-global)")
    func explicitOverrideMatchingGlobalClearsToNil() {
        let next = FloatingInputCard.nextToolsOverrideState(
            current: true,
            globalDisabled: true
        )
        #expect(next == nil, "third tap should clear the explicit override")
    }

    @Test("override=false + global=false → nil (clear to follow-global)")
    func explicitOverrideMatchingGlobalClearsToNilFalse() {
        let next = FloatingInputCard.nextToolsOverrideState(
            current: false,
            globalDisabled: false
        )
        #expect(next == nil, "third tap should clear the explicit override")
    }

    /// Three-tap round trip should return to nil for both starting global
    /// states. Proves the cycle length is exactly 3 and is closed.

    @Test("nil → explicit → match-global → nil round trip (global=false)")
    func roundTripGlobalFalse() {
        let step1 = FloatingInputCard.nextToolsOverrideState(current: nil, globalDisabled: false)
        let step2 = FloatingInputCard.nextToolsOverrideState(current: step1, globalDisabled: false)
        let step3 = FloatingInputCard.nextToolsOverrideState(current: step2, globalDisabled: false)
        #expect(step1 == true)
        #expect(step2 == false)
        #expect(step3 == nil, "three taps should complete the cycle back to nil")
    }

    @Test("nil → explicit → match-global → nil round trip (global=true)")
    func roundTripGlobalTrue() {
        let step1 = FloatingInputCard.nextToolsOverrideState(current: nil, globalDisabled: true)
        let step2 = FloatingInputCard.nextToolsOverrideState(current: step1, globalDisabled: true)
        let step3 = FloatingInputCard.nextToolsOverrideState(current: step2, globalDisabled: true)
        #expect(step1 == false)
        #expect(step2 == true)
        #expect(step3 == nil, "three taps should complete the cycle back to nil")
    }
}

// MARK: - TurboQuant substitution (Phase E.3)

@Suite("makeGenerateParameters TurboQuant substitution")
struct MakeGenerateParametersTests {

    /// The flagship Phase E.3 decision: osaurus defaults to TurboQuant(3,3)
    /// when the user hasn't explicitly picked a quant mode. vmlx's package
    /// default is `.none`, so there's a deliberate substitution in
    /// `ModelRuntime.makeGenerateParameters`. These tests lock that in.

    @Test("nil cacheOverrides.kvQuantMode → TurboQuant(3,3) (osaurus default)")
    func nilModeSubstitutesTurboQuant() {
        let params = ModelRuntime.makeGenerateParameters(
            temperature: 0.7,
            maxTokens: 256,
            topP: 1.0,
            repetitionPenalty: nil,
            maxKV: nil,
            cacheOverrides: ServerCacheConfig()
        )
        // Expected: TurboQuant with 3/3. Any other mode means the
        // substitution is broken and users are getting raw full-precision
        // KV without asking for it.
        if case .turboQuant(let keyBits, let valueBits) = params.kvMode {
            #expect(keyBits == 3, "key bits should default to 3")
            #expect(valueBits == 3, "value bits should default to 3")
        } else {
            Issue.record("expected .turboQuant default, got \(params.kvMode)")
        }
    }

    @Test("explicit .none kvQuantMode → .none (user opt-out respected)")
    func explicitNoneModeRespected() {
        var overrides = ServerCacheConfig()
        // Explicit type prefix is required here: bare `.none` resolves to
        // `Optional<CacheQuantMode>.none` (i.e. nil), which would hit the
        // substitution branch and return TurboQuant. The production code
        // avoids this ambiguity by using `CacheQuantMode.none` explicitly
        // in the ConfigurationView save path (see `CacheQuantModeChoice.optionalMode`).
        overrides.kvQuantMode = CacheQuantMode.none
        let params = ModelRuntime.makeGenerateParameters(
            temperature: 0.7,
            maxTokens: 256,
            topP: 1.0,
            repetitionPenalty: nil,
            maxKV: nil,
            cacheOverrides: overrides
        )
        if case .none = params.kvMode {
            // Pass — user explicitly disabled quant, no substitution.
        } else {
            Issue.record("expected .none when user explicitly opts out, got \(params.kvMode)")
        }
    }

    @Test("explicit .turboQuant with custom bits → those bits used")
    func explicitTurboQuantCustomBits() {
        var overrides = ServerCacheConfig()
        overrides.kvQuantMode = .turboQuant
        overrides.turboKeyBits = 4
        overrides.turboValueBits = 5
        let params = ModelRuntime.makeGenerateParameters(
            temperature: 0.7,
            maxTokens: 256,
            topP: 1.0,
            repetitionPenalty: nil,
            maxKV: nil,
            cacheOverrides: overrides
        )
        if case .turboQuant(let keyBits, let valueBits) = params.kvMode {
            #expect(keyBits == 4, "custom key bits should be honored")
            #expect(valueBits == 5, "custom value bits should be honored")
        } else {
            Issue.record("expected .turboQuant with custom bits")
        }
    }

    @Test("explicit .affine mode → .affine with configured bits")
    func explicitAffineMode() {
        var overrides = ServerCacheConfig()
        overrides.kvQuantMode = .affine
        overrides.affineKVBits = 8
        overrides.affineKVGroupSize = 128
        let params = ModelRuntime.makeGenerateParameters(
            temperature: 0.7,
            maxTokens: 256,
            topP: 1.0,
            repetitionPenalty: nil,
            maxKV: nil,
            cacheOverrides: overrides
        )
        if case .affine(let bits, let groupSize) = params.kvMode {
            #expect(bits == 8, "affine bits should be honored")
            #expect(groupSize == 128, "affine groupSize should be honored")
        } else {
            Issue.record("expected .affine, got \(params.kvMode)")
        }
    }

    @Test("explicit .affine mode without bits → defaults (4, 64)")
    func explicitAffineModeUsesDefaults() {
        var overrides = ServerCacheConfig()
        overrides.kvQuantMode = .affine
        let params = ModelRuntime.makeGenerateParameters(
            temperature: 0.7,
            maxTokens: 256,
            topP: 1.0,
            repetitionPenalty: nil,
            maxKV: nil,
            cacheOverrides: overrides
        )
        if case .affine(let bits, let groupSize) = params.kvMode {
            #expect(bits == 4, "affine bits default should be 4")
            #expect(groupSize == 64, "affine groupSize default should be 64")
        } else {
            Issue.record("expected .affine with defaults")
        }
    }

    @Test("prefillStepSize nil → 512 package default")
    func prefillStepSizeDefault() {
        let params = ModelRuntime.makeGenerateParameters(
            temperature: 0.7,
            maxTokens: 256,
            topP: 1.0,
            repetitionPenalty: nil,
            maxKV: nil,
            cacheOverrides: ServerCacheConfig()
        )
        #expect(params.prefillStepSize == 512, "nil prefillStepSize should produce the package default")
    }

    @Test("prefillStepSize set → forwarded to GenerateParameters")
    func prefillStepSizeForwarded() {
        var overrides = ServerCacheConfig()
        overrides.prefillStepSize = 1024
        let params = ModelRuntime.makeGenerateParameters(
            temperature: 0.7,
            maxTokens: 256,
            topP: 1.0,
            repetitionPenalty: nil,
            maxKV: nil,
            cacheOverrides: overrides
        )
        #expect(params.prefillStepSize == 1024, "custom prefillStepSize should flow through")
    }

    @Test("quantizedKVStart nil → 0 default")
    func quantizedKVStartDefault() {
        let params = ModelRuntime.makeGenerateParameters(
            temperature: 0.7,
            maxTokens: 256,
            topP: 1.0,
            repetitionPenalty: nil,
            maxKV: nil,
            cacheOverrides: ServerCacheConfig()
        )
        #expect(params.quantizedKVStart == 0, "nil quantizedKVStart should default to 0")
    }

    @Test("quantizedKVStart set → forwarded")
    func quantizedKVStartForwarded() {
        var overrides = ServerCacheConfig()
        overrides.quantizedKVStart = 256
        let params = ModelRuntime.makeGenerateParameters(
            temperature: 0.7,
            maxTokens: 256,
            topP: 1.0,
            repetitionPenalty: nil,
            maxKV: nil,
            cacheOverrides: overrides
        )
        #expect(params.quantizedKVStart == 256, "custom quantizedKVStart should flow through")
    }
}

// MARK: - AgentManager.effectiveMemoryEnabled precedence (Phase B M-05)

@Suite("AgentManager.effectiveMemoryEnabled precedence")
@MainActor
struct EffectiveMemoryEnabledTests {

    /// The default agent (built-in) is hard-coded to always follow the
    /// global setting, regardless of any attempted per-agent override.
    /// This keeps its semantics consistent with every other
    /// `effective*` resolver on AgentManager.

    @Test("default agent follows global (unknown or present)")
    func defaultAgentFollowsGlobal() {
        let global = MemoryConfigurationStore.load().enabled
        let effective = AgentManager.shared.effectiveMemoryEnabled(for: Agent.defaultId)
        #expect(effective == global, "default agent should mirror the global memory setting")
    }

    /// An unknown UUID should fall back to the global setting, NOT silently
    /// return false. Regression guard — the fallback branch was flagged
    /// during the Phase B audit as a place where a bad default could
    /// silently disable memory for malformed requests.

    @Test("unknown UUID falls back to global")
    func unknownAgentFallsBackToGlobal() {
        let global = MemoryConfigurationStore.load().enabled
        let unknownId = UUID()
        let effective = AgentManager.shared.effectiveMemoryEnabled(for: unknownId)
        #expect(effective == global, "unknown agent should fall back to global, not silent false")
    }
}
