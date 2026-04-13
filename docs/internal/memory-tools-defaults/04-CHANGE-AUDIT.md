# Change Audit Log — memory-tools-defaults

> Running log of changes made on the `feat/memory-tools-defaults` branch.
> Each entry has: change ID, file, before/after, why, blast radius, audit focus.
>
> **Format**: Appended as changes land. Change IDs are `M-01` through `M-14`
> per the phase plan in `03-FIX-PLAN.md`.

---

## Format key

- **Change ID**: `M-NN` per the fix plan
- **Phase**: A / B / C / D / E
- **File**: Path relative to repo root
- **Kind**: `add` / `edit` / `remove`
- **Severity**: P0 / P1 / P2
- **Depends on**: Previous change IDs this builds on
- **Audit focus**: What reviewers should verify

---

## Entries

<!-- Changes will be appended below this line as work lands. -->

---

### M-01 — Fix `resolveTools` hard short-circuit

- **Phase**: A
- **File**: `Packages/OsaurusCore/Services/Chat/SystemPromptComposer.swift`
- **Kind**: `edit` — rewrite the early guard into a mode-aware check
- **Severity**: P1
- **Depends on**: None
- **Doc ref**: `02-VERIFIED-ISSUES.md` Issue 4
- **Why**: Before this change, `guard !toolsDisabled else { return [] }` at
  line 168 stripped all tools — including per-agent explicit manual tools —
  the moment the global `disableTools` flag was `true`. After we flip the
  default in Phase D, every agent that was set up with
  `toolSelectionMode: .manual` + `manualToolNames: [...]` would silently
  lose its tool list. This fix makes the global flag mean "no auto-discovery
  and no built-in capability tools" rather than "no tools ever", so agents
  with explicit manual configuration keep working.

**Before** (lines 160-194):

```swift
/// Resolve the full tool set for a request: built-in + preflight/manual, deduped.
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

    var tools = ToolRegistry.shared.alwaysLoadedSpecs(
        mode: executionMode,
        excludeCapabilityTools: isManual
    )
    var seen = Set(tools.map { $0.function.name })

    if isManual {
        if let manualNames = AgentManager.shared.effectiveManualToolNames(for: agentId) {
            for spec in ToolRegistry.shared.specs(forTools: manualNames)
            where seen.insert(spec.function.name).inserted {
                tools.append(spec)
            }
        }
    } else {
        for spec in preflight.toolSpecs
        where seen.insert(spec.function.name).inserted {
            tools.append(spec)
        }
    }

    return tools
}
```

**After**:

```swift
/// Resolve the full tool set for a request: built-in + preflight/manual, deduped.
///
/// Semantics of `toolsDisabled`:
/// - `false` (default) — normal path: always-loaded built-in tools +
///   preflight-selected auto tools or per-agent manual tools
/// - `true` — auto-discovery and built-in capability tools are blocked,
///   but per-agent **explicit manual tools** still run. This means an
///   agent that was configured with `toolSelectionMode: .manual` and
///   an explicit `manualToolNames` list keeps working even when the
///   global tools toggle is off. Use-case: user wants "no tools by
///   default" but has a handful of agents that need specific tools.
@MainActor
static func resolveTools(
    agentId: UUID,
    executionMode: WorkExecutionMode,
    toolsDisabled: Bool = false,
    preflight: PreflightResult = .empty
) -> [Tool] {
    let toolMode = AgentManager.shared.effectiveToolSelectionMode(for: agentId)
    let isManual = toolMode == .manual

    // When global tools are disabled and the agent isn't in manual mode,
    // return empty. Auto-discovery and preflight are blocked.
    if toolsDisabled && !isManual {
        return []
    }

    // Always-loaded built-in tools (capability search etc.) are only
    // injected when the global toggle is on. Manual-mode agents running
    // under a global disable skip them too — the user explicitly
    // configured their specific tool list.
    var tools: [Tool] = []
    if !toolsDisabled {
        tools = ToolRegistry.shared.alwaysLoadedSpecs(
            mode: executionMode,
            excludeCapabilityTools: isManual
        )
    }
    var seen = Set(tools.map { $0.function.name })

    if isManual {
        if let manualNames = AgentManager.shared.effectiveManualToolNames(for: agentId) {
            for spec in ToolRegistry.shared.specs(forTools: manualNames)
            where seen.insert(spec.function.name).inserted {
                tools.append(spec)
            }
        }
    } else {
        for spec in preflight.toolSpecs
        where seen.insert(spec.function.name).inserted {
            tools.append(spec)
        }
    }

    return tools
}
```

**Semantics diff**:

| State | Before | After |
|-------|--------|-------|
| `disableTools=false`, agent `.auto` | built-in + preflight tools | **unchanged** |
| `disableTools=false`, agent `.manual` | built-in (no capability) + manualToolNames | **unchanged** |
| `disableTools=true`, agent `.auto` | `[]` | `[]` (same) |
| `disableTools=true`, agent `.manual` | `[]` **(bug)** | `manualToolNames` only (fixed) |

The only behavior change is in the fourth row. Agents with explicit manual
tools now get them even under a global disable. This is the intended fix.

**Blast radius**:
- Every call site of `resolveTools` is unchanged — the function signature
  is identical. Only the internal behavior differs.
- Only one caller in the codebase: `SystemPromptComposer.finalizeContext`
  at line 132. The call there already passes `toolsDisabled: toolsDisabled`
  from the outer `composeChatContext` invocation. No plumbing changes needed.
- On main today, `disableTools` defaults to `false` so the new code path
  never fires. This change is a no-op until Phase D flips the default.
- After Phase D, agents with `.manual` mode get tools as intended. Agents
  with `.auto` mode still get nothing (matches the user's "no tools by default"
  direction).

**Audit focus**:
- Verify the comment docstring correctly describes the new semantics
- Verify the `if toolsDisabled && !isManual` guard matches the intent
  ("only return empty when global is off AND the agent isn't manual")
- Verify `isManual` is computed before the early return so the check works
- Verify the `alwaysLoadedSpecs` call is skipped under the global disable
  even for manual agents (user wants ONLY their manual list, not capability
  search tools that the user never explicitly selected)
- Grep for other call sites of `resolveTools` — should be zero outside this
  file. (`composeWorkPrompt` has its own separate tool resolution path that
  lives below `resolveTools` in the same file.)
- Run `swift test` to verify existing tests still pass. None of them exercise
  the `toolsDisabled=true && isManual=true` path specifically (since that path
  was broken before), so nothing should regress.

**Follow-up**: A dedicated unit test for the four-state matrix above would
be valuable. Deferred to Phase E tests (M-20).

---

### M-02 — Add `ChatWindowManager.allActiveSessionIds()` accessor

- **Phase**: A
- **File**: `Packages/OsaurusCore/Managers/Chat/ChatWindowManager.swift`
- **Kind**: `add` — new public method
- **Severity**: P1
- **Depends on**: None
- **Doc ref**: `02-VERIFIED-ISSUES.md` Issue 8
- **Why**: Phase D needs to bulk-invalidate the preflight cache for every
  active session when `disableTools` changes in Settings. There's currently
  no way to enumerate session IDs from the manager — `closeWindow()` knows
  about a single session it's about to close, and that's it. Adding a
  dedicated accessor keeps the Settings save handler clean.

**New method** (inserted after `activeLocalModelNames()`, line ~274):

```swift
/// Returns every active chat session ID across all open windows.
///
/// Used by `ConfigurationView.saveConfiguration` to bulk-invalidate the
/// per-session preflight cache when `ChatConfiguration.disableTools`
/// changes — otherwise sessions keep serving stale tool specs from
/// before the toggle. See `docs/internal/memory-tools-defaults/02-VERIFIED-ISSUES.md`
/// Issue 8 for the reasoning.
///
/// Compacts out windows that don't have a session yet (fresh window,
/// model not selected, etc.) — those have nothing to invalidate.
public func allActiveSessionIds() -> [UUID] {
    windows.values.compactMap { $0.sessionId }
}
```

**Design choice**: reads from `windows` (the `[UUID: ChatWindowInfo]` dict at
line 36) rather than `windowStates`. `ChatWindowInfo.sessionId` is the
canonical record of what session a window belongs to; `windowStates` holds
the richer `ChatWindowState` object which may not be ready yet for freshly
opened windows. `windows` is the source of truth for "this window has a
session".

**Thread safety**: `ChatWindowManager` is `@MainActor` — all reads of
`windows` must happen on the main actor. Returning a `[UUID]` value type
makes the result safe to hand across async boundaries.

**Return semantics**:
- Returns all session IDs currently registered with the manager
- Includes work-mode windows (they also carry session IDs)
- Excludes windows that haven't been assigned a session (rare — usually
  just a brief window during creation)
- Returns an array, not a set — preserves window creation order, which
  doesn't matter for the invalidation use case but is cheaper than
  building a set

**Blast radius**:
- Purely additive. New method, no existing caller changes.
- Called in Phase D (M-17) by the Settings save handler.
- Also called in Phase C (M-11) by the chat-bar chip tap handler to
  invalidate its own session's preflight.

**Audit focus**:
- Verify `windows` is actually `[UUID: ChatWindowInfo]` with `sessionId`
  optional on `ChatWindowInfo` (confirmed at line 17 of the same file:
  `public let sessionId: UUID?`).
- Verify the method is `public` since `ConfigurationView` is in a sibling
  module subtree but the whole package is one module (`OsaurusCore`), so
  `internal` would also work. Using `public` for consistency with the rest
  of the class's API.
- Verify no existing method does the same thing under a different name.
  Grep for `sessionId` returns: `closeWindow` (single session), `windows`
  dict access in a few places. No existing enumerate-all helper.

---

### M-03 — Add batch + nuke preflight cache helpers to `PluginHostContext`

- **Phase**: A
- **File**: `Packages/OsaurusCore/Services/Plugin/PluginHostAPI.swift`
- **Kind**: `add` — two new static methods
- **Severity**: P1
- **Depends on**: None
- **Doc ref**: `02-VERIFIED-ISSUES.md` Issue 8
- **Why**: The existing `invalidatePreflightCache(sessionId:)` at line 588
  takes a single session ID. Phase D needs to invalidate multiple sessions
  in one go when the user flips `disableTools` in Settings — iterating N
  times and acquiring the lock N times is wasteful and leaves a race
  window between invalidations. Adding a batch variant keeps the lock
  acquisition atomic.
  Also adding a nuke-everything variant for global plugin/tool registry
  changes, where enumerating every affected session is not possible.

**Existing method** (line 587-590, unchanged):

```swift
/// Call when a session ends (e.g. chat window closes) to release the memoized result.
static func invalidatePreflightCache(sessionId: String) {
    _ = preflightCacheLock.withLock { preflightCache.removeValue(forKey: sessionId) }
}
```

**New methods** (inserted after the existing one):

```swift
/// Bulk variant — invalidates the cached preflight result for every
/// session ID in `sessionIds`. Acquires the lock once and drops all
/// matching entries in a single critical section so Settings save can
/// flush cache for every open window without thrashing the lock.
///
/// Used by `ConfigurationView.saveConfiguration()` when
/// `ChatConfiguration.disableTools` changes — otherwise sessions with
/// cached tool specs from before the toggle keep injecting them into
/// the next request. See `docs/internal/memory-tools-defaults/02-VERIFIED-ISSUES.md`
/// Issue 8 for the reasoning.
static func invalidatePreflightCaches(sessionIds: [String]) {
    guard !sessionIds.isEmpty else { return }
    preflightCacheLock.withLock {
        for sid in sessionIds {
            preflightCache.removeValue(forKey: sid)
        }
    }
}

/// Drop every cached preflight result regardless of session. Used when
/// tool-affecting configuration changes globally (e.g., tool policies,
/// plugin install/uninstall) and we can't enumerate every affected
/// session ID cheaply.
static func invalidateAllPreflightCaches() {
    preflightCacheLock.withLock { preflightCache.removeAll() }
}
```

**Design choices**:

1. **Batch variant holds the lock once** for all N removals. Alternative
   was to call `invalidatePreflightCache(sessionId:)` N times, which would
   acquire + release the lock N times. For the expected use case (a handful
   of open windows), both work; the batch version is cleaner and avoids
   a theoretical race where a session is invalidated, immediately
   re-populated by a concurrent preflight, then the next iteration misses
   it. Not likely in practice, but correctness first.

2. **`guard !sessionIds.isEmpty else { return }`** on the batch variant
   avoids acquiring the lock at all when there's nothing to do. Cheap
   optimization; more importantly it makes the empty-case semantics
   obvious to readers.

3. **Nuke variant (`invalidateAllPreflightCaches`)** is speculative — not
   called by any code in this branch. Included because it's a trivial
   companion and future plugin install/uninstall flows will want it.
   Alternatively we could defer this until it has a caller. Kept it in
   for completeness since it's two lines.

**Blast radius**:
- Purely additive. Existing `invalidatePreflightCache(sessionId:)` is
  unchanged, so existing callers (`ChatWindowManager.closeWindow` at line
  580 of `ChatWindowManager.swift`) keep working.
- New methods are only called in later phases (C, D).

**Audit focus**:
- Verify the lock type: `preflightCacheLock` is `NSLock()` on line 585.
  `withLock { ... }` acquires + releases around the closure — correct.
- Verify the `preflightCache` type: `[String: PreflightResult]` at line 584.
  `removeValue(forKey:)` and `removeAll()` are standard Dictionary API.
- Verify no thread-safety issue with the `guard !sessionIds.isEmpty` check
  happening outside the lock — the argument is a value type `[String]`,
  captured by the guard, so no race.
- Confirm the nuke variant is safe to call: only touches
  `preflightCache`, no related caches are affected. (Scanning `PluginHostAPI.swift`
  for other caches: none related to preflight — `contexts` is plugin
  instance registry, `agentMappings` is plugin config, etc.)

---

### M-04 — Add `Agent.memoryEnabled: Bool?` field

- **Phase**: B
- **File**: `Packages/OsaurusCore/Models/Agent/Agent.swift` (+ one
  companion edit in `Views/Agent/AgentsView.swift`)
- **Kind**: `edit` — new optional field on the `Agent` struct
- **Severity**: P1
- **Depends on**: None
- **Doc ref**: `02-VERIFIED-ISSUES.md` Issue 5
- **Why**: Phase D flips the global memory default from `true` to `false`.
  Power users who built up memory-using agents (trained agents with
  working-memory context, profile, summaries, etc.) would silently lose
  that context the moment the default flip lands, with no UI signal.
  Adding a per-agent override that wins over the global setting gives
  those users an escape hatch without forcing everyone back to global-on.

**New field** (inserted after `manualSkillNames`):

```swift
/// Per-agent override for persistent memory injection.
///
/// - `nil` (default) — follow the global `MemoryConfiguration.enabled` setting
/// - `true`  — force memory injection for this agent, even when the global toggle is off
/// - `false` — suppress memory injection for this agent, even when the global toggle is on
public var memoryEnabled: Bool?
```

Also threaded through:
- `init(...)` parameter list — defaults to `nil` so every existing
  call site keeps working without changes
- `init(from decoder:)` custom decoder — uses `decodeIfPresent(Bool.self)`
  so old JSON files on disk decode cleanly with `memoryEnabled = nil`
- `ExportData` builder — preserves the field across export/import

**Migration guarantee**: `memoryEnabled` is `Bool?`, not `Bool`. Existing
`Agent.json` files written before this change do not contain the key,
and `decodeIfPresent` returns `nil` for missing keys — so loading an
old agent file produces an `Agent` with `memoryEnabled == nil`, which
the Phase B resolver interprets as "fall back to global". No migration
step needed.

**Companion edit — `AgentsView.swift`**:

The agent editor view reconstructs an `Agent` value from its editing
state on save. That rebuild must include the new field or round-tripping
through the editor would clobber it to `nil`. Added
`memoryEnabled: current.memoryEnabled` to the init call at line ~2869.

The editor does not yet expose a UI toggle for `memoryEnabled` — that
is deferred until the defaults flip actually lands in Phase D, at
which point a toggle becomes user-relevant. Until then, power users
can set the field directly in `Agent.json`.

**Blast radius**:
- Every call to the `Agent` initializer is unchanged — `memoryEnabled`
  defaults to `nil` in the init param list.
- Codable autosynthesis continues to work because the custom decoder
  explicitly handles the new key.
- `Equatable` autosynthesis picks up the new field and stays correct.
- Export/import round-trip preserves the field end-to-end.
- No behavior change on its own: the field is not read anywhere until
  M-05 introduces the resolver.

**Audit focus**:
- Verify `decodeIfPresent` is used (not `decode`) so old files load.
- Verify the init param list matches field order for readability.
- Verify `ExportData` inclusion — otherwise exporting then re-importing
  an agent would drop the override.
- Verify `AgentsView.swift` rebuilds the agent with the field preserved.
- Grep for any other place that constructs `Agent(...)` without the new
  field — all existing sites pass positional or named args, Swift accepts
  either since the new param has a default.

---

### M-05 — Add `AgentManager.effectiveMemoryEnabled(for:)` resolver

- **Phase**: B
- **File**: `Packages/OsaurusCore/Managers/AgentManager.swift`
- **Kind**: `add` — new method in the existing
  "Agent Configuration Helpers" extension
- **Severity**: P1
- **Depends on**: M-04
- **Doc ref**: `02-VERIFIED-ISSUES.md` Issue 5
- **Why**: M-04 added the field; this is the read-side resolver that
  every memory-aware call site should go through. Centralizes the
  "per-agent override wins over global" rule so callers don't reach
  directly into `Agent.memoryEnabled` and `MemoryConfigurationStore`.

**New method** (inserted after `effectiveManualSkillNames`):

```swift
/// Resolves whether persistent memory injection should run for an agent.
///
/// Precedence:
/// 1. `Agent.memoryEnabled` if set — per-agent override wins over global
/// 2. Global `MemoryConfiguration.enabled` otherwise
///
/// The default agent (`Agent.defaultId`) always follows the global setting
/// because it represents "use the global chat settings". Custom agents
/// can override with their own `memoryEnabled` value.
public func effectiveMemoryEnabled(for agentId: UUID) -> Bool {
    let globalEnabled = MemoryConfigurationStore.load().enabled
    guard let agent = agent(for: agentId) else { return globalEnabled }
    if agent.id == Agent.defaultId { return globalEnabled }
    return agent.memoryEnabled ?? globalEnabled
}
```

**Design choices**:

1. **Default agent always uses global**. The default agent has no
   independent "agent record" conceptually — it represents "whatever
   the global chat settings say". Making it ignore an attempted
   per-agent override keeps the semantics consistent with the other
   `effective*` resolvers in the same extension (`effectiveSystemPrompt`,
   `effectiveModel`, `effectiveTemperature`), all of which short-circuit
   on `Agent.defaultId`.

2. **Unknown-agent fallback is the global value**, not `false`. If a
   malformed request somehow passes an unknown agent UUID, we'd rather
   the user's global preference be honored than silently disable memory.

3. **Returns `Bool`, not `Bool?`**. Callers need a definitive answer;
   the three-state nil/true/false model lives on `Agent.memoryEnabled`
   where it represents "unset/force-on/force-off". The resolver collapses
   that to a clear yes/no.

**Blast radius**:
- Purely additive. New method, no existing caller changes.
- Called only by M-06 (`SystemPromptComposer.appendMemory`) on this branch.

**Audit focus**:
- Verify the precedence order matches the doc comment: override → global.
- Verify the default-agent short-circuit matches the pattern used by
  `effectiveSystemPrompt` / `effectiveModel` / `effectiveTemperature`.
- Verify `MemoryConfigurationStore.load()` is the right source of truth
  for the global flag. (Cross-checked: it's the only store that owns
  `MemoryConfiguration.enabled`; `AppConfiguration.shared` caches
  `ChatConfiguration`, not memory config.)
- Grep for other call sites that read `MemoryConfiguration.enabled`
  directly and consider whether they should switch to the resolver too.
  (Deferred: `MemoryContextAssembler.assembleContextCached` still gates
  on `config.enabled` directly, which is correct — it's the "follow
  whatever config was handed to me" layer and doesn't know about agents.)

---

### M-06 — Wire `effectiveMemoryEnabled` into `SystemPromptComposer.appendMemory`

- **Phase**: B
- **File**: `Packages/OsaurusCore/Services/Chat/SystemPromptComposer.swift`
- **Kind**: `edit` — rewrite `appendMemory` to gate on the resolver
- **Severity**: P1
- **Depends on**: M-05
- **Doc ref**: `02-VERIFIED-ISSUES.md` Issue 5
- **Why**: `appendMemory` is the single call site that composes the
  memory section into the system prompt for both chat and work contexts
  (via `finalizeContext`). Without this wiring, M-04/M-05 would be
  dead weight — the per-agent override would exist on disk and in the
  resolver but never actually affect any prompt.

**Before** (original body):

```swift
public mutating func appendMemory(agentId: String, query: String? = nil) async {
    let config = MemoryConfigurationStore.load()
    let context: String
    if let query, !query.isEmpty {
        context = await MemoryContextAssembler.assembleContext(
            agentId: agentId, config: config, query: query)
    } else {
        context = await MemoryContextAssembler.assembleContext(
            agentId: agentId, config: config)
    }
    append(.dynamic(id: "memory", label: "Memory", content: context))
}
```

**After**:

```swift
public mutating func appendMemory(agentId: String, query: String? = nil) async {
    // Resolve effective memory-enabled state — per-agent override wins.
    let agentUUID = UUID(uuidString: agentId)
    let memoryEnabled: Bool
    if let agentUUID {
        memoryEnabled = await AgentManager.shared.effectiveMemoryEnabled(for: agentUUID)
    } else {
        // Malformed ID — fall back to global so we never silently disable.
        memoryEnabled = MemoryConfigurationStore.load().enabled
    }

    guard memoryEnabled else {
        append(.dynamic(id: "memory", label: "Memory", content: ""))
        return
    }

    // ... existing assemble logic unchanged ...
}
```

**Design choices**:

1. **UUID parse outside the `await`**. `UUID(uuidString:)` is cheap and
   synchronous; keeping the parse outside the actor hop means we don't
   pay for a main-actor bounce just to discover the ID was malformed.

2. **Fall-through to global on parse failure**. The function signature
   takes a `String`, not a `UUID`, and some call sites have already lost
   type info by the time they reach this layer. Silently disabling
   memory for those cases would be a correctness regression; falling
   back to the global flag preserves existing behavior.

3. **Still append an empty "memory" section** when gated off. The
   `PromptSection.dynamic` contract is that the section exists but is
   empty — the renderer's `filter { !$0.isEmpty }` collapses it away
   in the output, and the manifest still records the section for
   prefix-cache hashing. This keeps the manifest shape stable whether
   memory is on or off, which matters for prefix cache hit rates.

4. **`await AgentManager.shared...`** is already safe — the call site
   runs inside `composeChatContext` / `composeWorkContext`, both of
   which are `@MainActor`. The `await` is a formality.

**Blast radius**:
- Every caller of `appendMemory` (`composeChatContext`, `composeWorkContext`,
  `injectAgentContext`) gets the new gating automatically.
- No signature change — existing callers compile unchanged.
- Before Phase D flips the default, this is a no-op for users who
  haven't set a per-agent override: global is `true`, `memoryEnabled`
  is `nil`, resolver returns `true`, code proceeds exactly as before.

**Audit focus**:
- Verify `UUID(uuidString:)` returns `nil` for malformed IDs, not
  throws. (Confirmed: Foundation returns `Optional<UUID>`.)
- Verify the guard still appends an empty section so the manifest
  stays stable — otherwise prefix-cache hits across on/off toggles
  regress.
- Verify no double assemble: early return on `guard memoryEnabled`
  prevents the assembler from running when gated off.
- Confirm `AgentManager.shared.effectiveMemoryEnabled` is `@MainActor`
  and this call is inside a `@MainActor` composer path.

---

### M-07 — `MemoryConfigurationStore.save()` posts `.memoryConfigurationChanged`

- **Phase**: B
- **File**: `Packages/OsaurusCore/Models/Memory/MemoryConfiguration.swift`
- **Kind**: `edit` — add Notification.Name + post in save()
- **Severity**: P2
- **Depends on**: None
- **Doc ref**: `02-VERIFIED-ISSUES.md` Issue 6
- **Why**: Memory configuration writes currently have no observable
  signal. Anything that caches derived memory state has no way to know
  when to invalidate, so a user flipping the global memory toggle in
  Settings sees stale memory context in prompts for up to 10 seconds
  (the `MemoryContextAssembler` TTL window).

**New Notification.Name** (module-level, above the struct):

```swift
extension Notification.Name {
    public static let memoryConfigurationChanged =
        Notification.Name("memoryConfigurationChanged")
}
```

**Edit to `save(_:)`**:

```swift
public static func save(_ config: MemoryConfiguration) {
    let validated = config.validated()
    let url = OsaurusPaths.memoryConfigFile()
    OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
    do {
        let data = try encoder.encode(validated)
        try data.write(to: url, options: .atomic)
        lock.withLock { $0 = validated }
        NotificationCenter.default.post(
            name: .memoryConfigurationChanged, object: nil)
    } catch {
        MemoryLogger.config.error("Failed to save config: \(error)")
    }
}
```

**Design choices**:

1. **Post inside the `do` block, after the cache update**. Posting
   only on successful save means observers never see "updated"
   notifications for a write that actually threw — they can trust that
   by the time they see the notification, `load()` will return the
   new config from the cache.

2. **Post after the in-memory cache is updated** (`lock.withLock { $0 = validated }`),
   so any observer that immediately calls `MemoryConfigurationStore.load()`
   gets the new value, not the pre-save one.

3. **Match the existing `appConfigurationChanged` pattern** in
   `AppConfiguration.swift:12`. Same naming convention
   (`<scope>ConfigurationChanged`), same placement (extension above
   the struct/enum), same posting pattern.

**Blast radius**:
- Purely additive. Nothing observes the notification on main today, so
  this is a no-op until M-08 installs an observer.
- No behavior change on the write side — `load()` already returns the
  cached validated value after save; the notification is a signal,
  not a side-channel.

**Audit focus**:
- Verify the notification is posted from `save()`, not `invalidateCache()`.
  (`invalidateCache()` is a no-side-effect reset used internally — it
  doesn't mean the on-disk config changed, so notifying would be wrong.)
- Verify the Name string matches exactly so the observer in M-08 links
  to the same notification.

---

### M-08 — `MemoryContextAssembler.invalidateAll()` + Settings save wiring

- **Phase**: B
- **File**: `Packages/OsaurusCore/Services/Memory/MemoryContextAssembler.swift`
  (add) + `Packages/OsaurusCore/Views/Settings/ConfigurationView.swift`
  (call site)
- **Kind**: `add` method + `edit` caller
- **Severity**: P2
- **Depends on**: M-07
- **Doc ref**: `02-VERIFIED-ISSUES.md` Issue 7
- **Why**: `MemoryContextAssembler` already has a private
  `invalidateCache(agentId:)` actor method that handles both single-agent
  and full-wipe invalidation. The gap was an external caller: the
  Settings save handler that flips `MemoryConfiguration.enabled` needs
  to drop the 10-second TTL cache so the next request reflects the new
  state immediately instead of waiting for entries to expire naturally.

**New method on `MemoryContextAssembler`** (inserted after the cache fields):

```swift
/// Clear the per-agent context cache for every agent. Used by Settings save
/// after `MemoryConfiguration` changes so the next prompt reflects the new
/// config within the same request rather than waiting for the 10-second TTL
/// to expire.
public static func invalidateAll() async {
    await shared.invalidateCache()
}
```

**Edit in `ConfigurationView.saveConfiguration()`**:

```swift
var memoryCfg = MemoryConfigurationStore.load()
if memoryCfg.enabled != tempMemoryEnabled {
    memoryCfg.enabled = tempMemoryEnabled
    MemoryConfigurationStore.save(memoryCfg)
    // Drop the 10-second TTL cache so the next prompt reflects the new
    // enabled state immediately instead of waiting for entries to expire.
    Task { await MemoryContextAssembler.invalidateAll() }
}
```

**Design choices**:

1. **Static convenience wraps the existing actor method** rather than
   adding a second cache-wipe implementation. `invalidateCache(agentId: nil)`
   already hits `cache.removeAll()` in the actor body — M-08 just
   surfaces a zero-argument entry point so callers don't need to know
   about the shared instance.

2. **Direct call from `saveConfiguration` rather than a
   NotificationCenter observer**. M-07 established the notification
   infrastructure, but M-08's only real caller today is the Settings
   save handler — and that handler already owns the "enabled changed"
   decision directly. Wiring through a notification would mean
   installing an observer in an actor-isolated context (fiddly) for
   exactly one hop. Direct call is simpler. The notification from M-07
   remains useful for future observers that don't control the save site.

3. **Fire-and-forget `Task { ... }`**. The cache invalidation is
   best-effort and doesn't need to block the Settings save flow — if
   it races a concurrent request, that request will either use the
   old-now-wiped cache (miss → recompute, correct) or the new
   soon-to-be-wiped cache (hit → stale for one request, self-heals
   on next). Either way the system converges.

4. **Guard on `memoryCfg.enabled != tempMemoryEnabled`** — only
   invalidate when the enabled flag actually changed. Other memory
   config fields aren't user-editable from this view, so "no change
   to enabled" means "no change that affects the cache".

**Blast radius**:
- New `invalidateAll()` method is purely additive.
- Settings save wiring only fires when the user actually flips the
  toggle. On the common path (user saves settings without touching
  memory), nothing changes.
- `MemoryContextAssembler.shared` is actor-isolated; the `await` in
  `invalidateAll()` goes through the normal actor queue, so the wipe
  is serialized with any in-flight assembles.

**Audit focus**:
- Verify `shared` is accessible from the new static method (yes —
  `static let shared` is internal by default, same module).
- Verify `invalidateCache(agentId: nil)` is the correct call — check
  the default param value. (Confirmed: `agentId: String? = nil` on
  line 79; nil branch hits `cache.removeAll()`.)
- Verify the `Task { ... }` in `ConfigurationView` doesn't leak — it
  captures no `self`-owned state and self-completes, so no retain issue.
- Verify no existing test or call site relies on `saveConfiguration`
  being fully synchronous (it already has other async side effects
  like `Task { await ... }` for server restart).

---

### Phase B wrap-up

All five Phase B changes (M-04 through M-08) are code-complete and
build clean. Together they give the memory system:
1. A per-agent override field on `Agent` (M-04)
2. A centralized resolver that honors the override (M-05)
3. Wiring into the single prompt composer call site (M-06)
4. An observable signal when memory config changes (M-07)
5. A live cache invalidator driven by Settings save (M-08)

Phase B is a pure no-op until Phase D flips the global default,
because every resolver/fallback path still lands on the existing
`enabled: true` default. It lands the safety nets first, on purpose.

---

### M-09 — `ChatWindowState.toolsDisabledOverride`

- **Phase**: C
- **File**: `Packages/OsaurusCore/Managers/Chat/ChatWindowState.swift`
- **Kind**: `add` — new `@Published` property
- **Severity**: P1
- **Depends on**: None
- **Doc ref**: `02-VERIFIED-ISSUES.md` Issue 3
- **Why**: The chat-bar Tools chip needs a place to store its per-window
  state. `ChatWindowState` is the per-window ObservableObject that
  already holds every window-scoped piece of state (mode, sidebar,
  agent, theme). This is the natural home.

**New property** (inserted after `showSidebar`):

```swift
/// Per-window, ephemeral override for `ChatConfiguration.disableTools`.
/// - nil: follow global
/// - true: disable tools for this window only
/// - false: enable tools for this window only
@Published var toolsDisabledOverride: Bool?
```

**Design choices**:
1. **`Bool?`, not `Bool`** — the three-state (follow-global / explicit-on
   / explicit-off) model is what makes the chip actually useful. A
   two-state `Bool` would force the user to re-toggle whenever the
   global default flipped.
2. **Not persisted** — the override lives only as long as the window.
   Closing and reopening a window resets it. This matches the mental
   model of a per-conversation toggle and avoids persistence overhead
   for an ephemeral UI affordance.
3. **`@Published`** — SwiftUI binding from `FloatingInputCard` needs
   the property to be observable so the chip re-renders when cycled.

**Blast radius**: Purely additive. No existing caller affected.

**Audit focus**: Verify the property is `@Published` so SwiftUI
bindings work, and that it's `var` not `let`.

---

### M-10 — `FloatingInputCard.toolsToggleChip` + selector row integration

- **Phase**: C
- **File**: `Packages/OsaurusCore/Views/Chat/FloatingInputCard.swift`
- **Kind**: `add` — new `@Binding`, helpers, chip view, init threading
- **Severity**: P1
- **Depends on**: M-09
- **Doc ref**: `02-VERIFIED-ISSUES.md` Issue 3
- **Why**: The user-facing surface for the per-window tools override.
  Users need a visible, discoverable control in the chat bar to toggle
  tools on/off without diving into Settings — especially after Phase D
  flips the global default to off.

**New bindings** on the struct (after `pendingSkillId`):

```swift
@Binding var toolsDisabledOverride: Bool?
var sessionId: UUID? = nil
```

Both are additive with defaults (`.constant(nil)` and `nil`) so every
existing call site compiles unchanged. `sessionId` is threaded
through for M-11's cache invalidation hook, not for the chip's visual
state.

**Init threading**: Added two new parameters to the memberwise init
with defaults, plus matching assignments in the init body.

**Chip insertion** in `selectorRow` after the clipboard chip, gated on
`workInputState == nil` so it only appears in chat mode:

```swift
if workInputState == nil {
    toolsToggleChip
}
```

**Helper accessors**:

- `effectiveToolsDisabled: Bool` — resolves override → global, matching
  the same rule used in `ChatView.sendMessage`. Single source of truth
  for the chip's visual state.
- `toolsChipEnabled: Bool` — inverse of `effectiveToolsDisabled`, used
  for color/icon emphasis. A chip feels "active" when tools are on.
- `toolsChipBadge: String?` — returns `"on"` or `"off"` when the user
  has set an override that differs from global. When the override
  matches global (or is nil), the badge is hidden. This is the key
  affordance that tells the user "I've overridden this" without
  requiring a hover tooltip.
- `toolsChipHelpText: String` — full tooltip showing current state and
  global default.
- `cycleToolsOverride()` — see M-11 below.

**Chip view** (`toolsToggleChip`): Follows the same shape pattern as
`sandboxToggleChip` (capsule, padding, border) but lighter — no
animations, no async state. Uses `wrench.and.screwdriver` SF symbol
filled/unfilled based on `toolsChipEnabled`. Context menu offers
"Open Tools Settings" that jumps to `ManagementTab.tools`.

**Styling decisions**:
1. **Uses `theme.accentColor` for the enabled state**, matching the
   app's accent surface. The sandbox chip uses green because it's a
   system state (running/not), but tools are a user preference so
   accent color is more appropriate.
2. **No pulse animation**. The sandbox chip pulses while provisioning
   because it's genuinely async. The tools chip flips instantly.
3. **No disable state**. The chip is always tappable.

**Blast radius**:
- Adds one chip to every chat window's input bar. Hidden in work mode.
- New init params default to nil/constant, so existing callers
  (including `WorkView` and the preview) compile unchanged.
- No behavior change until the user actually taps the chip.

**Audit focus**:
- Verify `workInputState == nil` gating so the chip doesn't appear in
  work mode (where tools semantics are different — work has its own
  permission model).
- Verify all three chip states render correctly: follow-global-on,
  follow-global-off, override-on, override-off. The badge should only
  appear when the override differs from global.
- Verify the init param order — `toolsDisabledOverride` and `sessionId`
  come after `pendingSkillId` so positional call sites (if any) still
  work. Our call-site audit found none; all call sites use keyword args.

---

### M-11 — `cycleToolsOverride` invalidates session preflight cache

- **Phase**: C
- **File**: `Packages/OsaurusCore/Views/Chat/FloatingInputCard.swift`
  (part of the `toolsToggleChip` infrastructure from M-10)
- **Kind**: `add` — the tap handler method
- **Severity**: P1
- **Depends on**: M-03 (batch + single preflight cache hooks), M-10
- **Doc ref**: `02-VERIFIED-ISSUES.md` Issues 3 + 8
- **Why**: `PluginHostContext.preflightCache` holds per-session tool
  specs that are computed once from `ChatConfiguration.disableTools`
  and reused for subsequent requests. If the user cycles the chip
  without invalidating this cache, the next request in that session
  keeps serving the old tool specs — the chip visibly toggled but
  nothing actually changed. This is Issue 8 reincarnated at the
  per-chip level instead of the per-settings-save level.

**The method**:

```swift
private func cycleToolsOverride() {
    let globalDisabled = appConfig.chatConfig.disableTools
    switch toolsDisabledOverride {
    case .none:
        // First tap: override to the opposite of global
        toolsDisabledOverride = !globalDisabled
    case .some(let current):
        if current != globalDisabled {
            // Second tap: flip to match global (explicit, user may want to re-override)
            toolsDisabledOverride = globalDisabled
        } else {
            // Third tap: clear override entirely, return to follow-global
            toolsDisabledOverride = nil
        }
    }
    if let sid = sessionId {
        PluginHostContext.invalidatePreflightCache(sessionId: sid.uuidString)
    }
}
```

**Cycle design**:

The three-state cycle walks:
- `nil` (follow global) → opposite of global (visibly overridden)
- opposite of global → same as global (explicit, no-op semantically
  but the user can tell they've chosen it)
- same as global → `nil` (back to follow-global, badge disappears)

This gives the user a way to both quickly flip and eventually return
to the "no opinion" state. An alternative two-state cycle would stick
at "explicit override" forever once tapped — less good UX because the
badge never goes away.

**Invalidation**: After every state transition, we call the existing
`PluginHostContext.invalidatePreflightCache(sessionId:)` hook (not
the batch variant — only this session needs it). The call is a no-op
if `sessionId` is nil (e.g. a freshly created window that hasn't
attached to a session yet), which is the correct behavior: no session
means no cache entry exists yet.

**Blast radius**:
- Only fires on chip tap. No passive impact.
- The invalidation is scoped to one session — other windows are
  untouched, which is what we want (per-window override means per-window
  cache effect).

**Audit focus**:
- Verify the three-state cycle matches the spec in the doc comment.
  Easy off-by-one territory.
- Verify the `invalidatePreflightCache` call is **outside** the switch
  but **inside** the method body — it must fire on every tap,
  regardless of which branch ran.
- Verify `sessionId` is optional and the invalidation is conditionally
  called with `if let sid` — otherwise the chip would crash during
  window construction.
- Cross-check: does `ChatView.sendMessage` also honor the override?
  Yes, via M-12 below — otherwise the chip would be cosmetic only.

---

### M-12 — `ChatView.sendMessage` resolves the override

- **Phase**: C
- **File**: `Packages/OsaurusCore/Views/Chat/ChatView.swift`
- **Kind**: `edit` — passes resolved value to `composeChatContext`
- **Severity**: P1
- **Depends on**: M-09
- **Doc ref**: `02-VERIFIED-ISSUES.md` Issue 3
- **Why**: Without this edit, the chip is decorative — the per-window
  state gets updated but the send path still reads
  `chatCfg.disableTools` directly. This wires the override into the
  actual prompt composition call.

**Before** (line 831-838):

```swift
let context = await SystemPromptComposer.composeChatContext(
    agentId: effectiveAgentId,
    executionMode: executionMode,
    model: selectedModel,
    query: trimmed,
    toolsDisabled: chatCfg.disableTools,
    trace: ttftTrace
)
```

**After**:

```swift
// Per-window override from the Tools chip wins over the global flag.
let effectiveToolsDisabled = windowState?.toolsDisabledOverride ?? chatCfg.disableTools
let context = await SystemPromptComposer.composeChatContext(
    agentId: effectiveAgentId,
    executionMode: executionMode,
    model: selectedModel,
    query: trimmed,
    toolsDisabled: effectiveToolsDisabled,
    trace: ttftTrace
)
```

**`windowState` is Optional**: The property is `ChatWindowState?` on
the view, not `ChatWindowState`. The optional chain (`?.`) falls
through to `chatCfg.disableTools` when the window state hasn't been
attached yet (rare, but valid during construction).

**Blast radius**:
- Only one call site changed.
- No behavior change when `toolsDisabledOverride` is nil (the default),
  so existing users see the same send path.

**Audit focus**:
- Verify the override resolution matches the chip's `effectiveToolsDisabled`
  helper — both reach for `windowState.toolsDisabledOverride ?? chatCfg.disableTools`.
  If these drift apart, the chip lies to the user.
- Verify the optional chain on `windowState?.` — without it, the
  compiler rejects because `windowState` is declared optional in the
  enclosing scope.

---

### M-13 — Pass binding + sessionId to `FloatingInputCard`

- **Phase**: C
- **File**: `Packages/OsaurusCore/Views/Chat/ChatView.swift`
- **Kind**: `edit` — adds two keyword args to the existing init call
- **Severity**: P1
- **Depends on**: M-09, M-10
- **Doc ref**: `02-VERIFIED-ISSUES.md` Issue 3
- **Why**: Connects the per-window state to the chip UI. Without this,
  the chip would render but its binding would point at the constant
  default (`.constant(nil)`), so taps would be silently dropped.

**Edit** (appended to the existing `FloatingInputCard(...)` call):

```swift
FloatingInputCard(
    // ... existing args unchanged ...
    pendingSkillId: $observedSession.pendingOneOffSkillId,
    toolsDisabledOverride: $windowState.toolsDisabledOverride,
    sessionId: windowState.session.sessionId
)
```

**`windowState.session.sessionId`** is `UUID?` — `ChatSession.sessionId`
is optional (see `ChatWindowManager.swift:17` — `public let sessionId: UUID?`).
The chip handles nil gracefully in `cycleToolsOverride` (see M-11).

**WorkView call site**: Intentionally NOT edited. `WorkView` also
instantiates `FloatingInputCard` (line 65) but the chip is hidden by
the `workInputState == nil` gate in `selectorRow`, so passing the
binding would be dead weight. The new init params default to
`.constant(nil)` / `nil`, so WorkView compiles unchanged.

**Blast radius**:
- Only the ChatView call site gets the new args.
- Existing preview (if any) uses positional/keyword args; param
  defaults keep them compiling.

**Audit focus**:
- Verify `$windowState.toolsDisabledOverride` is a valid binding — it
  is, because `windowState` is an `@ObservedObject` and
  `toolsDisabledOverride` is `@Published var`.
- Verify `windowState.session.sessionId` is reachable — yes, `session`
  is a `let` property on `ChatWindowState`.
- Verify WorkView compiles without edits (confirmed: default values
  handle it).

---

### Phase C wrap-up

All five Phase C changes (M-09 through M-13) land the chat-bar Tools
chip end-to-end:
1. State model (M-09) — per-window override property
2. UI control (M-10) — the chip view + helpers
3. Cache hygiene (M-11) — invalidate preflight on every chip tap
4. Resolution at send time (M-12) — chip actually affects prompt composition
5. Binding wiring (M-13) — connects UI to state

The chip appears in chat mode only. Its cycle is nil → opposite-of-global
→ same-as-global → nil, with a badge indicator when the override differs
from global.

Phase C is again a pure no-op until the user actually taps the chip.
Existing users see a new capsule in the chat bar — nothing else changes
until they engage with it. Phase D flip gives the chip its reason to
exist.

---

### M-14 — Flip `MemoryConfiguration.enabled` default to `false`

- **Phase**: D
- **File**: `Packages/OsaurusCore/Models/Memory/MemoryConfiguration.swift`
- **Kind**: `edit` — one character change in the init default
- **Severity**: P1 — user-visible behavior change
- **Depends on**: Phase B (per-agent override + invalidation hooks)
- **Doc ref**: `02-VERIFIED-ISSUES.md` Issue 1
- **Why**: The central default flip. Main's UI help text says memory
  is off by default, but the code default was `true`. This aligns the
  code with the UI promise. New users get memory off; existing users
  who never explicitly set the flag also get memory off; users who
  set `"enabled": true` in their `memory.json` keep memory on.

**Before** (line 94):

```swift
enabled: Bool = true,
```

**After**:

```swift
enabled: Bool = false,
```

**Decoder fallback cascades automatically**: The custom `init(from decoder:)`
uses `defaults.enabled` (line 170) where `defaults = MemoryConfiguration()`.
Changing the init default propagates through to the decoder fallback
without a second edit. Users on old `memory.json` files missing the
`enabled` key read the new default (false) on next launch.

**Migration behavior**:
- New install: `MemoryConfigurationStore.load()` writes a fresh file
  with `enabled: false`.
- Upgrade, explicit `"enabled": true` in file: preserved (true).
- Upgrade, explicit `"enabled": false` in file: preserved (false).
- Upgrade, key missing from file: reads the new default (false).

The third case is the one user-visible regression path — users who
relied on the implicit default-true. For those users, the per-agent
`memoryEnabled` override from M-04 is the escape hatch: they can set
`memoryEnabled: true` on specific agents that need memory without
re-flipping the global.

**Blast radius**:
- First request after upgrade on an affected user's agent: no memory
  context injected. Prompt is shorter, TTFT improves, but context
  the user was relying on is gone.
- Second and subsequent requests: same as first, until user opts back in.
- Power users affected by this regression have Phase B as the escape.

**Audit focus**:
- Verify only the init default changed, not any other reference to
  `enabled`. Grep confirms: one hit in the init, one in the decoder
  (which reads from `defaults.enabled`), one in the `validated()`
  branch (untouched because `enabled` has no clamp).
- Verify the migration is backwards-compatible — reading an old file
  with `"enabled": true` preserves it. Decoder uses `decodeIfPresent`
  which returns the value if present; only falls through to the
  default when the key is absent.
- Verify `MemoryConfigurationStore.load()`'s fresh-file branch writes
  the new default. It does: `let defaults = MemoryConfiguration()` at
  line 201 (before our edit, now `MemoryConfiguration()` is
  `enabled: false`).

---

### M-15 — Flip `ChatConfiguration.disableTools` default to `true`

- **Phase**: D
- **File**: `Packages/OsaurusCore/Models/Chat/ChatConfiguration.swift`
- **Kind**: `edit` — init default + decoder fallback
- **Severity**: P1 — user-visible behavior change
- **Depends on**: Phase A (resolveTools fix + preflight invalidation),
  Phase C (Tools chip)
- **Doc ref**: `02-VERIFIED-ISSUES.md` Issue 2
- **Why**: The second half of the default flip. Like memory, main's
  UI copy said tools were off by default but the code default was
  `false` (tools on). This aligns code with UI. Users who had tools
  enabled and want to keep them use the new Tools chip from Phase C
  to re-enable per conversation, or flip the global flag back in
  Settings.

**Edit 1 — init default** (line 102):

```swift
disableTools: Bool = false,  →  disableTools: Bool = true,
```

**Edit 2 — decoder fallback** (line 149, now with explanatory comment):

```swift
// Decoder fallback updated to match the new init default. Existing
// on-disk ChatConfiguration.json files written before the Phase D
// flip do not contain this key → they now decode with `true` (tools
// off by default), matching the new behavior. Users who explicitly
// set `"disableTools": false` in their config keep tools on.
disableTools = try container.decodeIfPresent(Bool.self, forKey: .disableTools) ?? true
```

**Unlike `MemoryConfiguration`**, the `ChatConfiguration` decoder
does NOT read from a `defaults` instance — it has hardcoded fallback
literals. So both edits are required: init default for new
instances, decoder fallback for on-disk files missing the key.

**Migration behavior**: mirrors M-14 exactly.
- New install: fresh `chat.json` with `disableTools: true`.
- Upgrade, explicit `"disableTools": false`: preserved.
- Upgrade, explicit `"disableTools": true`: preserved.
- Upgrade, key missing: reads new default (true = tools off).

**Safety nets in place from earlier phases**:
- M-01 (Phase A): agents with `toolSelectionMode: .manual` and a
  `manualToolNames` list still get their manual tools even under
  `disableTools: true`. No silent regression for configured agents.
- M-16 (Phase D, below): Settings save now invalidates all active
  session preflight caches when the flag changes, so flipping the
  toggle back to `false` in Settings takes effect immediately.
- Phase C Tools chip: per-conversation override.

**Blast radius**:
- First request after upgrade: no tool specs in the prompt, unless
  the agent is in manual mode. Prompt is dramatically shorter, TTFT
  improves, tool-calling stops until re-enabled.
- Users who depended on auto-discovered tools must either tap the
  new Tools chip per conversation or flip the global back in
  Settings. The chip gives them a low-friction path; the regression
  is mitigated but not zero.

**Audit focus**:
- Verify both the init default AND the decoder fallback changed. One
  without the other would produce a subtle bug: new windows read one
  default, on-disk config reads another.
- Verify `ChatConfiguration.default` doesn't pass an explicit
  `disableTools:` arg (it doesn't — relies on the init default, so
  our edit flows through).
- Verify the preflight cache invalidation hook (M-16) fires when this
  flag changes at runtime, not just at launch.
- Grep for other `disableTools` references outside the model — they
  should all read from `ChatConfiguration` instances, never hardcode.
  (Confirmed: `ChatView.sendMessage`, `SystemPromptComposer`,
  `ConfigurationView` all read from `chatCfg` or the
  `@State tempDisableTools`.)

---

### M-16 — Settings save invalidates preflight caches on `disableTools` change

- **Phase**: D
- **File**: `Packages/OsaurusCore/Views/Settings/ConfigurationView.swift`
- **Kind**: `edit` — new invalidation block after `ChatConfigurationStore.save`
- **Severity**: P1 — correctness for runtime toggles
- **Depends on**: M-02 (`allActiveSessionIds`), M-03 (batch invalidation)
- **Doc ref**: `02-VERIFIED-ISSUES.md` Issue 8
- **Why**: Without this, a user flipping `disableTools` in Settings
  finds that open chat windows keep using the old tool-spec cache
  indefinitely — the next request in each session still injects the
  old tool list. The first user-visible symptom would be "I turned
  tools off but they're still being called". Settings save is the
  central choke point for the global flag change, so this is where
  the bulk invalidation belongs.

**Edit** (inserted immediately after `ChatConfigurationStore.save(chatCfg)`):

```swift
// If disableTools actually changed, every open session's preflight
// cache is holding tool specs computed under the old flag. Bulk-
// invalidate them so the next request in each session recomputes
// with the new state.
if previousChatCfg.disableTools != chatCfg.disableTools {
    let allSessionIds = ChatWindowManager.shared.allActiveSessionIds()
    PluginHostContext.invalidatePreflightCaches(
        sessionIds: allSessionIds.map { $0.uuidString }
    )
}
```

**Design choices**:

1. **Gated on "actually changed"**. `previousChatCfg.disableTools !=
   chatCfg.disableTools` — no-op on every save that didn't touch the
   flag. Avoids thrashing the preflight cache on unrelated setting
   changes (temperature, hotkey, etc.).

2. **Uses the batch variant from M-03**, not a loop of single-session
   invalidations. One lock acquisition for all N sessions.

3. **Fires before server restart**. The existing async block at line
   971 handles server restart / runtime reconfig; the preflight
   invalidation runs synchronously and returns before that block is
   scheduled. This ordering matters because the batch invalidation is
   cheap and doesn't need to be deferred.

4. **Called from the main actor**. `saveConfiguration()` is a SwiftUI
   view method, main-actor-isolated. `ChatWindowManager.shared` is
   also `@MainActor`; `allActiveSessionIds()` (M-02) is safe to call
   directly.

**Blast radius**:
- Only fires when `disableTools` flag flipped. No passive impact.
- Invalidation scope is "every open chat window" — intended, because
  the global flag affects every session.
- Fresh windows opened after the save will compute their own
  preflight on first send, so there's no race.

**Audit focus**:
- Verify the `previousChatCfg.disableTools != chatCfg.disableTools`
  guard. Without it, every save hits the batch hook.
- Verify `allActiveSessionIds()` returns `[UUID]` and we convert to
  `[String]` for the `sessionIds:` param (PluginHostContext uses
  String keys).
- Verify the invalidation happens AFTER `ChatConfigurationStore.save`
  so if another thread races into a preflight between our save and
  invalidate, the new computation reads the fresh config.
- Verify it doesn't double-invalidate alongside the existing
  `Task { await MemoryContextAssembler.invalidateAll() }` from M-08
  — they're independent caches (tool specs vs memory context), both
  need their own path.

---

### M-17 — (merged into M-16)

M-17 in the original plan was "memory assembler invalidation from
Settings save". That wiring already landed as part of M-08 in Phase B,
so there's nothing for M-17 to do here. Kept the ID in the plan for
traceability; no code entry.

---

### Phase D wrap-up

The two default flips + the runtime invalidation hook land as a
single atomic commit, on top of the full Phase A/B/C safety nets.
Verification matrix:

| Scenario | Old behavior | New behavior (Phase D) |
|----------|-------------|------------------------|
| New user, fresh install | memory on, tools on | memory off, tools off |
| Upgrade, explicit `enabled:true` / `disableTools:false` | same | same (preserved) |
| Upgrade, keys missing | memory on, tools on | memory off, tools off |
| Upgrade, configured manual-tools agent | broken under toolsDisabled=true | works (M-01 safety net) |
| Upgrade, power user with memory-trained agent | broken under memory=false | works if user sets `memoryEnabled: true` on agent (M-04/M-05) |
| User flips tools in Settings after upgrade | stale preflight cache (bug) | caches invalidated (M-16) |
| User flips memory in Settings after upgrade | stale TTL cache (bug) | cache cleared (M-08) |
| User wants tools just for one conversation | no option | Tools chip (Phase C) |

Phases A + B + C were all no-ops on their own. Phase D is where the
actual behavior change lands, and it lands on top of a net that
catches every regression path we identified.

Phase E is cleanup: cosmetic @State fixes, saveConfiguration error
handling (Issue 10), migration-compat tests, and final audit entries.

---

## Branch housekeeping — rebase onto latest main

The branch has been rebased onto `origin/main` at `1327e479` (Update
appcast for 0.16.10 release). Prior base was `82faed57`; main had
moved ahead by 5 commits while Phase D was being audited:

```
1327e479 Update appcast for 0.16.10 (release)
90ec7825 fix build
c2a82fe1 set standard size
d53aa961 use public repo
ef96d8cf fix dep resolution
```

The rebase applied **cleanly with zero conflicts** — none of the
upstream commits touched any file in our change surface
(`ConfigurationView.swift`, `FloatingInputCard.swift`, `ChatView.swift`,
`SystemPromptComposer.swift`, memory/chat config models, `Agent` model,
or `AgentsView.swift`). Build verified clean on top of the new base.

Post-rebase commit hashes (original → rebased):

| Phase | Original | Rebased |
|-------|----------|---------|
| Review package | `e6972788` | `8abd4e9d` |
| Second-pass wiring revision | `9bab8716` | `4736057a` |
| A — tool safety nets | `6af27be9` | `7416dd5d` |
| B — memory safety nets | `0a6c1e29` | `956465ed` |
| C — chat-bar Tools chip | `012a03ad` | `ba860b96` |
| D — default flip + save invalidation | `66eeb7fe` | `dab594f7` |
| Configurability audit doc | `28a51623` | `93a84f2c` |
| Configuration knobs user guide | `edb5a755` | `499993a6` |

All subsequent phase work should be based on the rebased commits.

---

## Progress status — as of rebase

| Phase | Status | Commit |
|-------|--------|--------|
| Pre-work: verification + plan | ✅ done | `8abd4e9d`, `4736057a` |
| A — tool safety nets (M-01..M-03) | ✅ done, committed, built clean | `7416dd5d` |
| B — memory safety nets (M-04..M-08) | ✅ done, committed, built clean | `956465ed` |
| C — chat-bar Tools chip (M-09..M-13) | ✅ done, committed, built clean | `ba860b96` |
| D — default flip + runtime invalidation (M-14..M-16) | ✅ done, committed, built clean | `dab594f7` |
| E — cleanup, error handling, tests, audit closure (M-18..M-21) | ⏳ not started | — |
| Configurability audit (team review) | ✅ done | `93a84f2c` |
| CONFIGURATION_KNOBS user guide | ✅ done | `499993a6` |
| Rebase onto latest main | ✅ done | — |
| Cache-settings audit + close gaps | ⏳ in progress | — |
| Push to remote | ⏳ not done | — |

**Confirmed hard gaps still open** (from
`05-CONFIGURABILITY-AUDIT.md`):
- Gap 1.1 — `Agent.memoryEnabled` editor UI toggle (recommended to
  close on this branch; blocks the Phase D escape hatch design goal)
- Gaps 1.2, 1.3, 1.4, 1.5, 1.6, 1.7 — deferred to follow-up PRs per
  audit recommendation

**New scope added on rebase**: Cache-related settings surface must
be verified configurable end-to-end. Audit in flight — entries will
be added below as gaps are found and closed.

---

## External coordination — tpae's preflight TTFT fix

tpae flagged on 2026-04-13 that `PreflightCapabilitySearch.search` is
currently called synchronously from `SystemPromptComposer.finalizeContext`
(line ~139) and adds to measured TTFT, which is why the
`&& !isLocalModel` gate exists at that line (local models pay the
biggest relative TTFT penalty for the ~50-150ms preflight cost). Quote:

> "preflight shouldn't impact TTFT, let me change it so it doesn't add
> to that time… rcn added load models… which doesn't extend TTFT so
> i'll add in extra step for preflight search so it doesn't impact
> the actual model TTFT"

**Expected change**: preflight moves to a pre-load step that runs in
parallel with model loading, similar to rcn's load-models step.
Synchronous composer callers then await an already-resolved
`PreflightResult` (~0ms), so there's no TTFT penalty.

This is a vmlx/osaurus-integration-layer change outside the scope of
this branch. tpae owns it.

### Compatibility audit — our branch vs. tpae's change

Every one of our preflight-touching changes is **invalidation-based,
not timing-dependent**. We never assume when preflight runs — we just
make sure the cache is correct when state changes.

| Our change | File | Behavior under tpae's new timing |
|-----------|------|----------------------------------|
| M-01 `resolveTools` reads `preflight: PreflightResult` | `SystemPromptComposer.swift:196` | No change. The function takes a resolved `PreflightResult`; whether that came from synchronous compute or a pre-loaded cache hit is opaque to `resolveTools`. |
| M-03 `PluginHostContext.invalidatePreflightCaches(sessionIds:)` | `PluginHostAPI.swift` | No change. Lock-based invalidation works regardless of when the next compute runs. |
| M-11 chat-bar chip cycle invalidates session cache | `FloatingInputCard.swift` `cycleToolsOverride()` | Works. After a chip toggle, the session's cache entry is dropped; the next request triggers a fresh preflight. If tpae's pre-load step has already cached the result from session start, this invalidation forces a re-run on the next message — a one-shot TTFT cost per chip toggle. Acceptable. |
| M-16 Settings save bulk-invalidates all sessions | `ConfigurationView.swift:saveConfiguration` | Works. Same as M-11 but across every open session. First request after a settings-save pays the preflight cost; subsequent requests benefit from the fresh cache. Acceptable. |

### Required action on our side

**None.** Our code is forward-compatible.

### Things to coordinate with tpae

1. **`!isLocalModel` gate removal.** Once preflight is off the
   critical path, the gate at `SystemPromptComposer.swift:139`
   (`if !toolsDisabled && toolMode == .auto && !query.isEmpty && !isLocalModel`)
   should drop the `!isLocalModel` clause. This is the "local models
   can't see tools" bug tpae is chasing in a separate thread. He'll
   almost certainly handle this as part of the same change.

2. **Cache keying by session ID stays stable.** Our invalidation
   hooks all key off `sessionId.uuidString`. As long as tpae's
   pre-load step caches by the same key (and sessions exist before
   pre-load fires — which they do, sessions are created when a chat
   window opens), our invalidation continues to work untouched.

3. **Order of operations on Settings save.** M-16 invalidates
   preflight caches AFTER `ChatConfigurationStore.save()` returns.
   If tpae introduces a background preflight re-prime (e.g. "after
   Settings save, re-run preflight for every open session in
   parallel"), he should consume the same `allActiveSessionIds()`
   accessor we added in M-02. No code change needed on either side.

4. **Don't reinstate the gate downstream.** Once tpae drops the
   `!isLocalModel` clause, subsequent patches in this file shouldn't
   re-add it. If we ever rebase and see it back, that's a sign a
   merge went wrong.

### Pinning this for the team reviewer

When tpae's preflight-TTFT fix lands on main and we rebase, the
**only** merge conflict risk is the area around line 139 of
`SystemPromptComposer.swift` if both sides edit it. Our branch
doesn't edit line 139 (we only edit `resolveTools` at line ~196),
so the rebase should be clean. If a conflict does appear, it's
almost certainly cosmetic — both sides are editing around the gate,
not the gate logic itself.

---


