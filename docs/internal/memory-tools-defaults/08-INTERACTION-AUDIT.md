# Interaction Audit — Cross-System Behavior, Edge Cases, Hazards

> Team doc: a deep trace of how the changes on `feat/memory-tools-defaults`
> interact with the rest of osaurus. Focuses on **real hazards** that
> could crash, silently break user workflows, or produce misleading UI.
> Complements `07-DEFERRED-FIXES.md` (quality-of-life items) — this doc
> is about correctness.
>
> **Branch**: `feat/memory-tools-defaults` at commit `da4d0f48` (Phase E.10).
> This doc captures the interaction audit plus the three hazard fixes
> that landed in the same Phase E.10 commit.
>
> Investigation scope: stop button, stats measurement, disk L2 eviction,
> JSON decoder robustness, runtime parameter forwarding, actor
> boundaries, streaming interactions, cross-feature state sync.

---

## Executive summary

| Area | Finding | Severity | Status |
|------|---------|----------|--------|
| Stop button ↔ vmlx cancellation | Works correctly — Task.cancel propagates through genTask → token loop via Task.isCancelled checks | ✅ safe | No fix needed |
| TTFT / tokens/sec / context size display | Properly measured from streams; one benign staleness after chip cycle | ✅ safe | Documented as known behavior |
| Disk L2 cache eviction during generation | Works — FIFO-by-creation-time eviction in `DiskCache.evictIfNeeded()` on every write | ✅ safe | No fix needed |
| **Disk L2 cache downsize** (user lowers cap) | **🔴 Old entries stayed on disk until next generation triggered eviction — could pay 10 GB footprint for a 2 GB budget indefinitely** | 🔴 → ✅ | **Fixed in E.10** |
| **Hand-edited `cacheConfig` JSON typo** | **🔴 Would throw during ServerConfiguration decode, taking port/hotkey/CORS/eviction policy with it** | 🔴 → ✅ | **Fixed in E.10** |
| **Out-of-range overrides from hand-edited JSON** | **🔴 Values like `turboKeyBits: 99` were forwarded straight into vmlx without clamping** | 🔴 → ✅ | **Fixed in E.10** |
| Chip cycle during mid-stream | Safe — cycle updates state and invalidates cache, in-flight generation is untouched | ✅ safe | No fix needed |
| `toolsDisabledOverride` surviving agent switch within same window | Intentional (per-window, not per-agent) but undocumented | ⚠️ | Documented below |
| Memory TTL race on `MemoryConfiguration.enabled` flip | Narrow 10s window where a request could see stale context between save and cache wipe | ⚠️ | Documented; acceptable |

---

## Q1: Does the Stop button actually stop inference? ✅

**Verdict**: Yes, the cancellation path is sound.

**Trace**:

1. **`FloatingInputCard.swift`** — Stop button calls `onStop()` closure
2. **`ChatView.swift:1517`** — closure fires `observedSession.stop()`
3. **`ChatSession.stop()` (`ChatView.swift:369-377`)** — calls
   `currentTask?.cancel()`
4. **`ChatView.swift:799`** — `currentTask` is the `Task<Void, Never>?`
   that wraps the generation pipeline
5. **`MLXGenerationEngine.swift:160-166`** — creates `genTask` via
   `generateTokenTask()` and returns it in `ResultBox`
6. **`ModelRuntime.swift` ~line 270** — wraps the inner task in
   `withTaskCancellationHandler` so cancellation propagates through
7. **vmlx `Evaluate.swift`** — the token generation loop checks
   `Task.isCancelled` between tokens and breaks with
   `stopReason = .cancelled`

**What this means**:
- Cancellation is honored at the **next token boundary** — not
  instantaneously, but within one decode step (~ms to tens of ms on
  typical hardware).
- The UI stops streaming immediately when the user taps Stop; there's
  no waiting for natural stream end.
- Preflight search (if running) is part of `prepareAndGenerate` — also
  inside the cancellable task, so it too stops cleanly.
- Nothing our branch added breaks this path. Phase A/D preflight cache
  invalidation is a separate concern from stop — they never contend.

**Not a concern**, but worth knowing:
- If a Stop happens while vmlx is mid-`prefill` (before the first
  output token), the cancellation still fires — prefill yields to
  cancellation checks at chunk boundaries controlled by
  `prefillStepSize`. Users who set a very large `prefillStepSize`
  (e.g. 4096) on a long prompt may see slightly delayed cancellation
  response. This is an upstream vmlx behavior, not something osaurus
  should patch.

---

## Q2: Are displayed stats properly measured? ✅ (with one benign edge case)

**Verdict**: Yes, measured stats are sourced from real telemetry. One
staleness edge case around the chip cycle is semantically correct but
could feel unintuitive — documented below.

**Stats surveyed**:

| Stat | Source | Location | Correctness |
|------|--------|----------|-------------|
| **TTFT** | `streamStartTime` captured after stream is ready; delta computed on first token | `NativeMessageCellView.swift:679-684`, `ChatView.swift:1017` | ✅ Excludes model load; measures real first-token latency |
| **Tokens/sec** | MLX stats when available; falls back to `generatedText.count / elapsed / 4` heuristic | `NativeMessageCellView.swift:686-688`, `ChatView.swift:1085-1088` | ✅ Measured path preferred; fallback labeled |
| **Token count** | Actual tokens emitted by the stream | `NativeMessageCellView.swift:689+` | ✅ True count |
| **Context size indicator (estimate)** | `ContextBudgetManager.estimateTokens()` (4 chars/token) + `ComposedContext.toolTokens` | `FloatingInputCard.swift:1179-1181`, `ChatView.swift:282-284` | ✅ Labeled as estimate via `~` prefix before streaming |
| **Cumulative tokens (work mode)** | Sum from work task execution | `FloatingInputCard.swift:52,1190-1192` | ✅ (not on hot path for this branch) |

**No stats on this branch lie**. TTFT still excludes model load, so
Phase D's shrunken default prompts (no tools, no memory) produce
legitimately lower TTFT numbers. Users see the win.

**Benign staleness** (documented, not a bug):

When the user cycles the Tools chip (Phase C), `effectiveToolsDisabled`
changes immediately and the preflight cache is dropped. But the
**displayed** `estimatedContextTokens` value reflects the *last*
composed context — i.e., the number is still showing tokens from the
previous message. It's not lying (the chip update doesn't retroactively
change past messages), but a user watching the number might expect it
to dip when they cycle to "tools off".

Fix: not necessary. The estimate updates naturally on the next send.
If we forced a recompute on chip cycle, we'd have to re-run preflight
just to produce a display number — too expensive for a cosmetic fix.

---

## Q3: Does the disk L2 cache properly rotate/evict? ✅ during generation, 🔴 on downsize (fixed)

### On-write eviction (normal operation) — works

**Evidence**: `vmlx-swift-lm/Libraries/MLXLMCommon/Cache/DiskCache.swift`

- `store()` at `DiskCache.swift:95-136` writes the new entry to disk
- `evictIfNeeded()` at `DiskCache.swift:250-296` runs after every store
- Eviction policy: **FIFO by creation time**, not strict LRU —
  `"ORDER BY created_at ASC"` at line 271
- Deletes oldest entries until total size ≤ `maxSizeBytes`
- **Never refuses a write** and **never crashes** — if the new entry
  itself exceeds the budget, older entries are deleted until it fits
  (or until the budget is fully cleared, in which case the new entry
  is the only one stored)

**Verdict**: Rotation works during active generation. The disk cache
cannot grow unbounded during normal use.

**Minor note**: the policy is FIFO-by-insertion, not true LRU (which
would require tracking access time). For cache-hit patterns, FIFO is
weaker than LRU but not dramatically so — warm prefixes tend to be
stored early and reused often, and FIFO evicts based on when they
were created, not when they were last used. This is an upstream vmlx
design choice, not something osaurus patches.

### Downsize case (user lowers `diskCacheMaxGB` in Settings) — 🔴 bug, now fixed

**Scenario**: User has 10 GB of cache on disk. Opens Settings, changes
`diskCacheMaxGB` from 10.0 to 2.0, clicks Save, then goes to bed
without sending a message.

**Pre-fix behavior**:

1. `ServerConfigurationStore.save` writes the new config to disk ✓
2. Next time a model loads, `installCacheCoordinator` reads the new
   cap (2 GB) and passes it to `CacheCoordinator` ✓
3. **But the existing 10 GB of files on disk are not touched** ❌
4. `DiskCache.evictIfNeeded()` runs on the **next write**, which
   requires the user to start generating
5. If the user never generates, the old 10 GB sits there indefinitely
   even though the configured budget is 2 GB

**Post-fix behavior** (Phase E.10):

In `ConfigurationView.saveConfiguration`, right after
`ServerConfigurationStore.saveThrowing` succeeds, we now check:

```swift
let oldDiskCap = previousServerCfg.cacheConfig.diskCacheMaxGB ?? 4.0
let newDiskCap = configuration.cacheConfig.diskCacheMaxGB ?? 4.0
if newDiskCap < oldDiskCap {
    let currentBytes = OsaurusPaths.diskKVCacheUsageBytes()
    let newLimitBytes = Int(newDiskCap * 1024 * 1024 * 1024)
    if currentBytes > newLimitBytes {
        _ = OsaurusPaths.clearDiskKVCache()
        diskCacheUsageBytes = OsaurusPaths.diskKVCacheUsageBytes()
        ToastManager.shared.info("Disk cache cleared", ...)
    }
}
```

Rationale:
- **Full clear is safer than partial prune**. Partial pruning would
  need to delete raw `.safetensors` blocks without desyncing the
  SQLite index. vmlx's `DiskCache` is the only authoritative layer
  that knows how to do this correctly, and it doesn't expose a
  "prune to N GB" method publicly. Full clear via
  `OsaurusPaths.clearDiskKVCache()` is the atomic safe operation.
- **User is informed via toast**. The cache wasn't silently wiped —
  there's explicit feedback explaining why and what happened.
- **Only fires when actually needed**. If the user lowers the cap from
  10 GB to 2 GB but currently has 1 GB on disk, nothing happens.

**Cost of full clear vs partial prune**: the user loses their warm
prefix cache, so the next few prompts see worse TTFT until the cache
re-warms. For the common downsize case (user reclaiming disk space),
this is acceptable. For a fine-grained prune we'd need to add
`DiskCache.pruneToBytes(_:)` upstream in vmlx.

---

## Hazard 1: `cacheConfig` decoder isolation — 🔴 fixed in E.10

**Scenario**: User hand-edits `~/.osaurus/config/server.json` to try a
Cache Engine knob that's not yet in the Settings UI. They type:

```json
{
    "cacheConfig": {
        "kvQuantMode": "TurboQuant"
    }
}
```

Wrong case on `TurboQuant` — the `CacheQuantMode` enum raw value is
the camelCase `turboQuant`. The `ServerCacheConfig` Codable decoder
throws a `DecodingError.dataCorrupted` because `"TurboQuant"` can't
parse to `CacheQuantMode`.

**Pre-fix behavior**:

The exception propagates up to `ServerConfiguration.init(from:)`,
which re-throws to `ServerConfigurationStore.load()`, which catches
the error and returns `nil`. Callers fall back to
`ServerConfiguration.default`. The user silently loses:
- `port` → back to 1337
- `hotkey` → back to ⌘;
- `allowedOrigins` → back to empty
- `modelEvictionPolicy` → back to .strictSingleModel
- `appearanceMode` → back to .system

One typo in a JSON knob they probably weren't even actively tuning
bricks their entire server config.

**Post-fix behavior**:

`ServerConfiguration.init(from:)` wraps the `cacheConfig` decode in
its own try-catch. On failure it logs the error and substitutes
`ServerCacheConfig.default`. Every other field keeps its value from
the JSON. User only loses the malformed cache config, not the whole
server config.

Regression test: `ServerConfigurationDecoderIsolationTests` in
`Packages/OsaurusCore/Tests/Configuration/CoreLogicTests.swift`
proves that a typo in `kvQuantMode` preserves port, CORS, and
appearance mode while falling back to cache defaults.

---

## Hazard 2: Out-of-range override values forwarded to vmlx — 🔴 fixed in E.10

**Scenario**: User hand-edits `server.json` because they want
aggressive compression:

```json
{
    "cacheConfig": {
        "kvQuantMode": "turboQuant",
        "turboKeyBits": 99,
        "turboValueBits": -3,
        "prefillStepSize": 999999
    }
}
```

The Settings UI has validation — `SettingsStepperField` clamps to a
declared range. But hand-edited JSON bypasses the UI entirely. These
values would previously flow straight through `ServerCacheConfig` →
`ModelRuntime.makeGenerateParameters` → `GenerateParameters` and into
vmlx's TurboQuant/prefill code paths. The consequence is
unspecified — could crash the quant pipeline, could produce garbage
output, could allocate absurd amounts of memory on prefill.

**Pre-fix behavior**: forward as-is, unknown consequences.

**Post-fix behavior**: `makeGenerateParameters` now clamps every
quant/step value into the same range the UI declares, via a new
private helper:

```swift
nonisolated private static func clampOrDefault(
    _ value: Int?,
    _ range: ClosedRange<Int>,
    default defaultValue: Int
) -> Int {
    guard let value = value else { return defaultValue }
    return min(max(value, range.lowerBound), range.upperBound)
}
```

Clamping is applied to:
- `affineKVBits` → `2...8`
- `affineKVGroupSize` → `16...256`
- `turboKeyBits` → `2...8`
- `turboValueBits` → `2...8`
- `quantizedKVStart` → `0...1_000_000` (generous cap, user might
  legitimately want to preserve a long prompt)
- `prefillStepSize` → `64...4096`

Regression tests: five new tests in `MakeGenerateParametersTests`
cover `turboKeyBits=99 → 8`, `turboValueBits=0 → 2`,
`affineKVBits=16 → 8`, `prefillStepSize=-500 → 64`, and
`prefillStepSize=999999 → 4096`.

---

## Tool call flow audit — kwargs and schema safety

**Scope**: confirm nothing on this branch breaks the tool-call argument
forwarding path (the model emits JSON args → osaurus parses → plugin
receives them → returns result → osaurus feeds back).

**Our branch's touchpoints**:

1. **`resolveTools`** (Phase A M-01) — determines which tool specs are
   available per request. We changed the hard short-circuit to
   mode-aware but did NOT change what gets returned. Tool specs come
   from `ToolRegistry.shared.alwaysLoadedSpecs` +
   `ToolRegistry.shared.specs(forTools: manualNames)` +
   `preflight.toolSpecs`. None of these were modified.

2. **`ChatView.sendMessage`** (Phase C M-12) — resolves
   `effectiveToolsDisabled` and passes it through
   `composeChatContext(toolsDisabled:)`. Does NOT touch
   `toolChoice`, `makeTokenizerTools`, or the arg-forwarding layer.

3. **`makeGenerateParameters`** (Phase E.3) — only changes the `kvMode`
   and `prefillStepSize` fields. Does NOT touch anything related to
   tool calls. The `kvMode` affects KV cache compression (how attention
   is cached), not how tool call JSON is parsed or forwarded.

**Verdict**: no regressions in tool call kwargs forwarding.

**Adjacent risks we're NOT claiming to fix**:

- Model emits a tool call with hallucinated argument name (e.g.
  `{"query_text": "..."}` when the plugin expects `{"query": "..."}`).
  Upstream parser concern, not ours.
- Model emits a tool call for a tool that got removed between the
  `resolveTools` call and the decoded response. Rare but possible if
  the user cycles the chip mid-turn or saves Settings mid-stream.
  **Currently**: osaurus logs "unknown tool" and returns an error
  back to the model, which either retries or gives up. Graceful
  degradation.

---

## Cross-system interaction nuances

These are not bugs — they're intentional or documented behaviors
that are worth being explicit about.

### `toolsDisabledOverride` survives agent switch within the same window

If a user in window A sets the Tools chip to `.forceOff`, then
switches from agent X to agent Y (via the agent picker in the same
window), the override persists. This is **intentional** — the override
is per-window, not per-agent. The mental model is "this window is in
tools-off mode" not "this agent has tools off".

**Rationale**:
- Agent switching is cheap and frequent; resetting the chip on every
  switch would annoy users who are deliberately muting tools for a
  conversation across multiple agents.
- Per-agent memory overrides (Phase B/E.4) provide a separate control
  for the "I want this agent to always/never use memory" case.

**Documented**: this doc. Worth mentioning in release notes if the
branch ships.

### Memory TTL race on `enabled` flip

`MemoryContextAssembler` has a 10-second TTL cache keyed by agent ID
(`cacheTTL: TimeInterval = 10`). When the user flips
`MemoryConfiguration.enabled` in Settings, we call
`MemoryContextAssembler.invalidateAll()` (Phase B M-08) to wipe the
cache. But if a send happens **in the microsecond window** between
`ChatConfigurationStore.save` returning and the `Task { await
MemoryContextAssembler.invalidateAll() }` firing, that send could
still see the stale cached context.

**Likelihood**: negligible. The window is < 1ms on typical hardware.

**Consequence if it hits**: one request sees stale memory context.
Next request sees fresh state (cache is wiped by the time the second
request runs).

**Fix cost**: would need to change the invalidation from `Task { await }`
to a synchronous await on `saveConfiguration`, which would block the
SwiftUI main thread for the duration of the actor hop. Not worth it
for a sub-millisecond race.

**Decision**: accept as documented edge case.

### Mid-generation cache config change

User saves a `cacheConfig` change while a generation is in-flight.
The in-flight generation uses the `RuntimeConfig` snapshot captured
at `prepareAndGenerate` time, which is *before* the save. The next
generation sees the new config because `RuntimeConfig.snapshot()`
re-reads on every request.

**Stack 1 and 5 changes** (prefill, quant) apply on the next request
automatically.

**Stack 2/3/4/6 changes** (paged blocks, disk cache size, SSM entries)
are baked into `CacheCoordinator` at model load time. They apply on
the next **model load**, not next request. User has to switch models
(or restart) to trigger.

**Covered by**: `07-DEFERRED-FIXES.md` DF-2. Recommended fix is a
post-save "pending reload" banner — not landed on this branch.

### `showChatBarToolsChip` default-true on first launch

Phase E.2 added the `showChatBarToolsChip: Bool` field with a default
of `true`. Pre-branch `chat.json` files don't have the key and decode
as `true` → the chip appears in every window on first launch after
upgrade.

Users who don't want the chip have to discover the toggle in
Settings → Chat → Tools. There's no onboarding notification.

**Not a bug, but a friction point**. Options:
- Add a first-launch notification: "New: Tools chip in chat bar, you
  can hide it in Settings → Chat → Tools". Scope creep, probably
  better in a release note than a modal.
- Default to `false`: hides the feature from users who would've
  ignored it. Rejected because the chip is our main Phase D escape
  hatch for re-enabling tools per conversation.
- Leave as-is. **Chosen**.

### Agent memoryEnabled UI trap (closed during E.4)

During the audit I worried that `AgentDetailView` might render for
the built-in default agent, showing the `memoryOverride` picker that
is silently no-op'd by `AgentManager.effectiveMemoryEnabled`'s
hard-coded "default agent always follows global" rule. **Verified not
the case**: `AgentsView` filters `customAgents = agents.filter {
!$0.isBuiltIn }` before passing to `AgentDetailView`, so the default
agent never gets an edit surface. The picker is only shown for agents
where it actually takes effect.

---

## Regression tests added in E.10

All in `Packages/OsaurusCore/Tests/Configuration/CoreLogicTests.swift`:

- **`turboKeyBitsClampedHigh`** — `turboKeyBits = 99` clamps to `8`
- **`turboValueBitsClampedLow`** — `turboValueBits = 0` clamps to `2`
- **`affineKVBitsClamped`** — `affineKVBits = 16` clamps to `8`
- **`prefillStepSizeClamped`** — `prefillStepSize = -500` clamps to `64`
- **`prefillStepSizeClampedHigh`** — `prefillStepSize = 999999` clamps to `4096`
- **`cacheConfigTypoDoesNotBrickServerConfig`** — typo in
  `kvQuantMode` preserves port/CORS/appearance, falls back to cache defaults
- **`validCacheConfigStillDecodes`** — sanity check that valid
  cacheConfig still parses correctly after the decoder isolation change

Total test count: **39 tests passing** (up from 32 at E.8).

---

## Checklist for the team reviewer

- [ ] Stop button still stops mid-stream (manual test)
- [ ] TTFT displayed is shorter under Phase D defaults (tools + memory off)
- [ ] Lower `diskCacheMaxGB` below current usage → toast fires, cache wiped
- [ ] Hand-edit `server.json` with a bad `kvQuantMode` → osaurus still boots with port/hotkey intact
- [ ] Hand-edit `server.json` with `turboKeyBits: 99` → osaurus doesn't crash on next generation
- [ ] Tools chip `.forceOff` → agent switch → chip stays `.forceOff` (intentional)
- [ ] Cycle chip rapidly during streaming → generation continues, preflight cache drops, no crash
- [ ] First launch after upgrade → chip appears, Tools Settings toggle hides it, hiding clears any stale override
- [ ] `swift test --package-path Packages/OsaurusCore --filter Configuration` → 39 tests pass

---

**Document status**: interaction audit complete for the state of the
branch at Phase E.10.
**Last updated**: alongside the E.10 hazard-fix commit.
