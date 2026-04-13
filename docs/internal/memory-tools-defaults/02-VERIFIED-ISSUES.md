# Verified Issues — Cross-Confirmed Against Main

> Every issue in this doc was verified by reading the actual file on main at
> commit `82faed57` (the worktree at `/Users/eric/osaurus-feat`). Each entry
> has file:line references and quoted code so reviewers can confirm without
> re-exploring.

---

## Issue 1: `MemoryConfiguration.enabled` default is `true`, UI says "off by default"

**Severity**: P0 — UI lies to users

### Where

**File**: `Packages/OsaurusCore/Models/Memory/MemoryConfiguration.swift`
**Line 94** (init default):

```swift
public init(
    ...
    maxEntriesPerAgent: Int = 500,
    enabled: Bool = true,     // ← default ON
    verificationEnabled: Bool = true,
    ...
)
```

### The lie

**File**: `Packages/OsaurusCore/Views/Settings/ConfigurationView.swift`
**Lines 350-353** (Memory subsection help text):

```swift
Text(
    "Inject persistent memory (profile, working memory, summaries, relationships) into the system prompt. Off by default — memory can add thousands of tokens per request. Enable for agents that need long-term context across conversations.",
    bundle: .module
)
```

### Consequence

On a fresh install, the Settings UI shows "Enable memory" toggle OFF (because
the initial `@State` value is `false` on line 31). Then `loadConfiguration()`
at line 725 runs `tempMemoryEnabled = MemoryConfigurationStore.load().enabled`
which loads `true`, so the toggle immediately flips to ON. Users see a toggle
labeled "Enable memory" that's ON by default, next to help text claiming memory
is OFF by default.

Meanwhile, every chat request runs `SystemPromptComposer.appendMemory()` which
delegates to `MemoryContextAssembler.assembleContextCached()` — and because
`enabled == true`, that assembly runs on every request. Up to ~9,300 tokens
(`workingMemoryBudgetTokens + summaryBudgetTokens + chunkBudgetTokens +
graphBudgetTokens` = 3000+3000+3000+300) get injected into the system prompt.

Users silently pay the token cost. If they read the UI help text, they're told
memory is off by default and think it's opt-in. It isn't.

### Fix

Flip line 94 to `enabled: Bool = false`. The decoder at line 170 uses
`defaults.enabled`, which now resolves to `false` — so existing JSON files
without the key get `false` on next load. Explicit `"enabled": true` in user's
JSON is preserved.

---

## Issue 2: `ChatConfiguration.disableTools` default is `false`, UI says "off by default"

**Severity**: P0 — UI lies to users

### Where (two places)

**File**: `Packages/OsaurusCore/Models/Chat/ChatConfiguration.swift`

**Line 102** (init default):
```swift
public init(
    ...
    preflightSearchMode: PreflightSearchMode? = nil,
    disableTools: Bool = false,      // ← tools ON (disableTools = false means tools enabled)
    enableClipboardMonitoring: Bool = true
) {
```

**Line 149** (decoder fallback):
```swift
disableTools = try container.decodeIfPresent(Bool.self, forKey: .disableTools) ?? false
```

Both must be flipped. The decoder fallback and the init default are independent
— Swift's `init(from decoder:)` doesn't run through `init(...)`, so the two
have to be kept in sync manually.

### The lie

**File**: `Packages/OsaurusCore/Views/Settings/ConfigurationView.swift`
**Lines 333-336** (Tools subsection help text):

```swift
Text(
    "Send messages directly to the model with no tool specs or capability injection. Tools are off by default — enable them here or via the chat bar to let agents use built-in and plugin tools.",
    bundle: .module
)
```

Two lies in one sentence:
- "Tools are off by default" — false, they're on
- "enable them here or via the chat bar" — the chat bar toggle doesn't exist (see Issue 4)

### Consequence

Same pattern as Issue 1. The Toggle binds to `$tempDisableTools` which has an
initial `@State` value of `true` on line 30 (suggesting "Disable tools: ON" at
first render). Then `loadConfiguration()` line 724 runs
`tempDisableTools = chat.disableTools`, loading `false`. The toggle flips to
"Disable tools: OFF", which means tools are ON. Users see tools enabled by
default, contradicting the help text.

Every chat request runs through `SystemPromptComposer.resolveTools()` which
invokes the always-loaded capability tools + preflight search (~320-640 tokens
of tool specs injected into the prompt).

### Fix

Flip both line 102 and line 149 to `true`. Migration: explicit
`"disableTools": false` in user JSON is preserved.

---

## Issue 3: Chat-bar Tools chip doesn't exist

**Severity**: P1 — referenced by UI copy that doesn't work

### Where

**File**: `Packages/OsaurusCore/Views/Chat/FloatingInputCard.swift`

Greps for `toolsChip`, `toolsToggleChip`, `toolsDisabledOverride`, `wrench` all
return zero matches in this file. The `selectorRow` (lines 1119+) has chips for:
- Model selector
- Thinking toggle
- Model options
- Sandbox toggle
- Clipboard
- Folder context

No Tools chip.

Similarly:

**File**: `Packages/OsaurusCore/Managers/Chat/ChatWindowState.swift`

Grep for `toolsDisabledOverride` returns zero matches. The class has:
- `session: ChatSession`
- `agentId: UUID`
- `mode: ChatMode`
- `showSidebar: Bool`
- Various cached view values

No per-conversation tool override state.

### The lie

**Help text referenced in Issue 2** promises "enable them here or via the chat bar" — but "the chat bar" doesn't have a toggle.

### Consequence

Users reading the Tools help text in Settings look for a chat-bar toggle, fail
to find it, and have to either toggle in Settings every time or give up on
per-conversation control. After fixing Issue 2 (flipping `disableTools` default
to true), this becomes the normal path: users want to enable tools for one
conversation without touching global settings.

### Fix

Three parts:

1. Add `@Published var toolsDisabledOverride: Bool?` to `ChatWindowState`
2. Add a `toolsToggleChip` to `FloatingInputCard.selectorRow`, bound to
   `$windowState.toolsDisabledOverride` (new `@Binding` parameter on
   `FloatingInputCard`)
3. In `ChatView.sendMessage`, resolve:
   ```swift
   let effectiveToolsDisabled = windowState.toolsDisabledOverride ?? chatCfg.disableTools
   ```
   and pass to `composeChatContext(toolsDisabled:)`.

Also update the two call sites of `FloatingInputCard` (`ChatView` and
`WorkView`) to pass the new binding. Work mode doesn't need the chip in the
selector row — hide it with `if workInputState == nil`.

---

## Issue 4: `SystemPromptComposer.resolveTools` hard short-circuit

**Severity**: P1 — latent bug, becomes user-visible after Issue 2 fix

### Where

**File**: `Packages/OsaurusCore/Services/Chat/SystemPromptComposer.swift`
**Lines 162-194**:

```swift
@MainActor
static func resolveTools(
    agentId: UUID,
    executionMode: WorkExecutionMode,
    toolsDisabled: Bool = false,
    preflight: PreflightResult = .empty
) -> [Tool] {
    guard !toolsDisabled else { return [] }    // ← HARD SHORT-CIRCUIT on line 168

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

### Consequence

Today: `disableTools` defaults to `false`, so the guard at line 168 never
fires in practice. The code is effectively dead.

After Issue 2 fix: `disableTools` defaults to `true`. The guard fires on every
request. Agents that were configured with `toolSelectionMode: .manual` and an
explicit `manualToolNames: [...]` list have their tools stripped — the
guard returns `[]` before line 179 ever runs. Users who carefully built up
a custom agent lose the feature silently.

### Fix

Rewrite the guard to honor per-agent manual tools:

```swift
let toolMode = AgentManager.shared.effectiveToolSelectionMode(for: agentId)

// When global tools are disabled, only honor explicit per-agent manual
// configuration. Agent defaults (auto-discovery / built-in capability tools)
// are still blocked.
if toolsDisabled && toolMode != .manual {
    return []
}

// When disableTools is true AND the agent is manual, we still skip the
// built-in capability tools (they're auto-discovery aids) and only return
// the explicit manual list.
let isManual = toolMode == .manual
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
```

Semantic change: `disableTools = true` now means "no auto-discovery, no
capability tools, no preflight" rather than "no tools at all". Per-agent
explicit manual config still runs.

**This is the riskiest change in the branch.** See Decision D-5 in `01-README.md`
for the trade-offs.

---

## Issue 5: No per-agent memory override

**Severity**: P1 — required companion to Issue 1

### Where

**File**: `Packages/OsaurusCore/Models/Agent/Agent.swift`

Grep for `memoryEnabled` / `memoryOverride` returns zero matches. The Agent
struct has `toolSelectionMode`, `manualToolNames`, `temperature`, `maxTokens`,
`systemPrompt`, `defaultModel` — but nothing about memory.

**File**: `Packages/OsaurusCore/Services/Memory/MemoryContextAssembler.swift`
reads `config.enabled` from `MemoryConfigurationStore.load()` directly.
No layering over per-agent.

### Consequence

After Issue 1 fix, memory is off globally. An agent the user built up over
weeks with a rich memory profile loses its memory feed. The only way to
restore it is to turn memory on globally, which defeats the point of the
default flip.

### Fix

Three parts:

1. **`Agent.swift`**: add `memoryEnabled: Bool? = nil` field with a new
   CodingKey. Existing Agent JSON decodes without the key → field is nil →
   follow global.
2. **`AgentManager.swift`**: add
   ```swift
   public func effectiveMemoryEnabled(for agentId: UUID) -> Bool {
       guard let agent = agent(for: agentId) else {
           return MemoryConfigurationStore.load().enabled
       }
       if let override = agent.memoryEnabled { return override }
       return MemoryConfigurationStore.load().enabled
   }
   ```
3. **`MemoryContextAssembler.swift`** (or wherever memory is gated): change
   `guard config.enabled else { return "" }` to
   `guard AgentManager.shared.effectiveMemoryEnabled(for: agentUUID) else { return "" }`.
   Need to check the actual call site structure first — the assembler may or
   may not have access to the agent ID at the check point.

Optional follow-up:
4. **Agent editor UI**: add a memory toggle with tri-state (nil / true / false).
   Can ship without this first — users can edit the Agent JSON directly for
   the initial fix, then we add the UI as a follow-up.

---

## Issue 6: `MemoryConfigurationStore.save()` posts no notification

**Severity**: P1 — silent config changes

### Where

**File**: `Packages/OsaurusCore/Models/Memory/MemoryConfiguration.swift`
**Lines 216-227** (`MemoryConfigurationStore.save()`):

```swift
public static func save(_ config: MemoryConfiguration) {
    let validated = config.validated()
    let url = OsaurusPaths.memoryConfigFile()
    OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
    do {
        let data = try encoder.encode(validated)
        try data.write(to: url, options: .atomic)
        lock.withLock { $0 = validated }
    } catch {
        MemoryLogger.config.error("Failed to save config: \(error)")
    }
}
```

### The problem

`ChatConfigurationStore.save()` goes through
`AppConfiguration.updateChatConfig()` which posts `.appConfigurationChanged`.
Views can observe it and refresh.

`MemoryConfigurationStore.save()` writes to disk and updates the lock cache
but **emits no notification**. Any view or manager that wants to react to
memory config changes has to poll or manually invoke `load()` on every
interaction.

This is fine for the current generation path (`SystemPromptComposer.appendMemory`
calls `MemoryConfigurationStore.load()` fresh per request, which reads from the
updated lock cache). But it means:

- If we ever add a UI indicator for "memory is on/off" beside the chat bar,
  it won't update when Settings changes.
- The `MemoryContextAssembler` 10-second TTL cache (see Issue 7) isn't told
  to invalidate.
- Per-agent overrides (D-4) can't reactively refresh.

### Fix

Add a notification posted from `save()`:

```swift
extension Notification.Name {
    public static let memoryConfigurationChanged =
        Notification.Name("memoryConfigurationChanged")
}

public static func save(_ config: MemoryConfiguration) {
    // ... existing save logic ...
    NotificationCenter.default.post(
        name: .memoryConfigurationChanged, object: nil
    )
}
```

Needed for Issue 7 to work correctly.

---

## Issue 7: `MemoryContextAssembler` 10-second TTL cache survives config changes

**Severity**: P1 — stale memory context after toggle

### Where

**File**: `Packages/OsaurusCore/Services/Memory/MemoryContextAssembler.swift`

The assembler has an actor-isolated `cache: [String: CacheEntry]` keyed by
agent ID, with a 10-second TTL per entry. On cache hit, it returns the stored
context string directly.

### The problem

Scenario: user has memory enabled, sends a chat message. The assembler builds
a memory context string and caches it for 10 seconds. User then opens Settings,
toggles memory **off**, saves, closes Settings. Within 10 seconds, user sends
another chat message.

The assembler's outer gate (`guard config.enabled else { return "" }` at
line 46) SHOULD catch this — it reads `MemoryConfigurationStore.load().enabled`
which returns the new `false` value, and returns early with empty string.
**The TTL cache is only hit AFTER that gate passes.** So this specific
scenario is actually safe.

Inverse scenario: user has memory **disabled**, sends a message (the gate
short-circuits with empty string — but the short-circuit path doesn't
populate the cache either, so no stale data). User toggles memory on.
Within 10 seconds, sends another message. The gate now passes `true`,
assembler goes to cache — there's no entry yet because the previous call
short-circuited, so it builds fresh. **Also safe.**

**However**, there's a subtler scenario that IS broken: user with memory on
sends a message (builds + caches context). User edits memory in another view
(adds a new working memory entry via the memory editor UI, which updates the
underlying memory store but does NOT touch `MemoryConfiguration`). Within
10 seconds, user sends another message. The assembler returns the **stale
cached context** that doesn't include the new entry.

The TTL is designed to survive fast repeated calls from the same chat, but
it doesn't distinguish "fast repeated chats" from "meaningful data change
happened in between".

### Fix

Add a memory-content notification from the memory editor (if one exists —
needs verification) OR a manual invalidation hook from Settings save:

```swift
// In MemoryContextAssembler
public static func invalidateCacheForConfigChange() async {
    await shared.cache.removeAll()
}

// In ConfigurationView.saveConfiguration() after MemoryConfigurationStore.save():
Task { await MemoryContextAssembler.shared.invalidateCacheForConfigChange() }
```

The memory-editor-change path is a separate concern, not in scope for this
branch. Focus on the config-change case.

**Honest scope assessment**: The primary scenario (config toggle) is already
safe because of the outer gate. But the TTL cache not having an invalidation
hook is a latent bug waiting for the next feature. Worth fixing now as a
small investment.

---

## Issue 8: `PluginHostContext.preflightCache` never invalidated on `disableTools` change

**Severity**: P0 — stale tool specs after toggle

### Where

**File**: `Packages/OsaurusCore/Services/Plugin/PluginHostAPI.swift`

The preflight cache is a `[sessionId: PreflightResult]` dictionary holding
tool specs that were selected for a session's system prompt. It's populated
during the first request in a session and reused for subsequent requests to
avoid re-running the preflight LLM call.

Currently the cache is invalidated in one place only:
`ChatWindowManager.closeWindow()` (line 580) — when a window closes.

### The problem

Scenario: user has `disableTools = false`, sends a message in window A. The
preflight runs, selects some tool specs, caches them under the session ID.
User opens Settings, flips `disableTools` to `true`, saves. Within the same
window/session, user sends another message.

`SystemPromptComposer.composeChatContext` runs. Because we're in the same
session, `PluginHostAPI.enrich` hits the preflight cache and returns the
old cached result — **which still contains tool specs**. Those tools get
injected into the system prompt despite the user having explicitly disabled
them.

Same problem in reverse for the chat-bar chip I'm adding: flipping the chip
only affects the next request's `toolsDisabled` flag but does NOT touch the
preflight cache.

### Fix

Two invalidation hooks needed:

**Hook 1**: When `disableTools` changes via Settings save, invalidate the
preflight cache for every active session:

```swift
// In ConfigurationView.saveConfiguration() after ChatConfigurationStore.save():
if previousChatCfg.disableTools != chatCfg.disableTools {
    let allSessionIds = ChatWindowManager.shared.allActiveSessionIds()  // new accessor
    for sid in allSessionIds {
        PluginHostContext.invalidatePreflightCache(sessionId: sid.uuidString)
    }
}
```

Need to add `ChatWindowManager.allActiveSessionIds()` accessor that returns
session IDs from all open windows.

**Hook 2**: When the chat-bar Tools chip flips `toolsDisabledOverride` for
a specific window, invalidate that session's preflight cache:

```swift
// In FloatingInputCard.cycleToolsOverride() or wherever the chip mutates state:
if let sid = windowState.session.sessionId {
    PluginHostContext.invalidatePreflightCache(sessionId: sid.uuidString)
}
```

### Blast radius

Every chat-bar chip toggle and every Settings tools-toggle save now invalidates
preflight. Next request re-runs the preflight LLM call (~8 seconds for the
first message in the session with the new state). Acceptable — the cost is
paid only on the flip, not per-request.

---

## Issue 9: `ChatWindowState.refreshAgentConfig()` doesn't refresh tools/memory state

**Severity**: P2 — latent, matters only if we ever add live status indicators

### Where

**File**: `Packages/OsaurusCore/Managers/Chat/ChatWindowState.swift`

The observer at line 353-357 watches `.appConfigurationChanged`:
```swift
notificationCenter.addObserver(
    forName: .appConfigurationChanged,
    object: nil,
    queue: .main
) { [weak self] _ in Task { @MainActor in self?.refreshAgentConfig() } }
```

`refreshAgentConfig()` only updates `cachedSystemPrompt` and `cachedActiveAgent`.
It doesn't touch tools or memory state — because `ChatWindowState` doesn't
HAVE explicit tools or memory state to refresh today.

### The problem

Currently fine. `ChatView.sendMessage` reads `ChatConfigurationStore.load()`
fresh on every send, so tools/memory changes are always reflected in the
next request.

**Becomes a problem when**: I add `ChatWindowState.toolsDisabledOverride`
and a chip that reads the effective state (override or global). The chip
needs to re-render when either side changes. The override side is handled
by `@Published`. The global side needs to fire when `AppConfiguration.chatConfig`
updates — which posts `.appConfigurationChanged` but currently doesn't
cause the chip to refresh because the chip doesn't observe it.

### Fix

Two options:

**Option A**: Make the Tools chip observe `AppConfiguration.shared` directly:
```swift
@ObservedObject private var appConfig = AppConfiguration.shared
```
The chip already has to read `AppConfiguration.shared.chatConfig.disableTools`
as part of the effective-state calculation, so making it an `@ObservedObject`
gives automatic reactivity.

**Option B**: Expand `ChatWindowState.refreshAgentConfig()` to publish a
`chatConfigVersion: Int` counter that increments on every refresh, and have
the chip observe it. Works but more plumbing.

**Recommendation**: Option A. `FloatingInputCard` already uses
`@ObservedObject var appConfig = AppConfiguration.shared` at line 130, so
the chip's computed state will just work via body re-evaluation.

---

## Issue 10: `saveConfiguration()` has no atomicity or error handling

**Severity**: P2 — pre-existing, not caused by this branch but worth noting

### Where

**File**: `Packages/OsaurusCore/Views/Settings/ConfigurationView.swift`
Lines 821-983 (`saveConfiguration()`)

Multiple store writes in sequence:
1. `ServerConfigurationStore.save(configuration)` (line 872)
2. `ChatConfigurationStore.save(chatCfg)` (line 948)
3. Conditional `MemoryConfigurationStore.save(memoryCfg)` (line 956)
4. `ToastConfigurationStore.save(toastConfig)` (somewhere)

No try-catch. No rollback. If step 2 throws, steps 3-4 don't run. User
sees the success toast anyway because it's unconditional at the end.

### The problem

Pre-existing bug on main. Not introduced by this branch. Flagging it here
so we can decide whether to fix as part of Phase E or defer.

### Fix

Wrap the store writes in a do/catch:
```swift
do {
    ServerConfigurationStore.save(configuration)
    ChatConfigurationStore.save(chatCfg)
    if memoryCfg.enabled != tempMemoryEnabled { ... }
    // ...
    showSuccess("Settings saved successfully")
} catch {
    showError("Failed to save settings: \(error.localizedDescription)")
}
```

Needs an `showError` helper. Minor UX addition.

---

## Non-issues (claimed but not actually bugs)

### False finding 1: `@State` initial values don't match defaults

The earlier audit flagged:
- `tempDisableTools: Bool = true` (line 30) vs `disableTools: Bool = false` (line 102)
- `tempMemoryEnabled: Bool = false` (line 31) vs `enabled: Bool = true` (line 94)

These look like mismatches but **are not bugs**. The `@State` initial value is
only the very-first-render value before `loadConfiguration()` runs `.onAppear`.
`loadConfiguration()` at lines 724-725 overwrites both immediately:
```swift
tempDisableTools = chat.disableTools
tempMemoryEnabled = MemoryConfigurationStore.load().enabled
```

The initial values are cosmetic — dead on first render, meaningless thereafter.
We should still flip them to match the new defaults for readability, but that's
cleanup, not a bug fix.

### False finding 2: Cache settings need hot-reload

The earlier audit flagged that `refreshCacheConfig()` isn't called, so cache
settings changes don't propagate. But **main has no user-facing cache settings
anymore** — tpae stripped them. There's nothing to hot-reload. `invalidateConfig()`
correctly drops the `RuntimeConfig` snapshot for gen* fields, which is all that
remains. Not a bug.

### False finding 3: `invalidateConfig()` is dead code

It's not. `ConfigurationView.saveSettings()` line 978 calls it when
`runtimeConfigChanged == true`. The call path is:

```
User saves settings
  → saveConfiguration()
    → computes `runtimeConfigChanged` based on genTopP / genMaxKVSize diff
    → ServerConfigurationStore.save()
    → if runtimeConfigChanged: ModelRuntime.shared.invalidateConfig()
```

Works correctly for everything that's still in `RuntimeConfig`.

---

## Summary

| # | Issue | File | Line | Severity |
|---|-------|------|------|----------|
| 1 | Memory default on, UI says off | `MemoryConfiguration.swift` | 94 | **P0** |
| 2 | Tools default on (`disableTools=false`), UI says off | `ChatConfiguration.swift` | 102, 149 | **P0** |
| 3 | Chat-bar Tools chip referenced by UI but doesn't exist | `FloatingInputCard.swift`, `ChatWindowState.swift`, `ChatView.swift` | — | P1 |
| 4 | `resolveTools` hard short-circuit strips agent manual tools | `SystemPromptComposer.swift` | 168 | P1 (after Issue 2 fix) |
| 5 | No per-agent memory override | `Agent.swift`, `AgentManager.swift` | — | P1 (after Issue 1 fix) |
| 6 | `MemoryConfigurationStore.save()` posts no notification | `MemoryConfiguration.swift` | 216-227 | P1 |
| 7 | `MemoryContextAssembler` 10s TTL cache has no invalidation hook | `MemoryContextAssembler.swift` | 69-75 | P1 |
| 8 | `PluginHostContext.preflightCache` never invalidated on `disableTools` change | `PluginHostAPI.swift` | 584 | **P0** (after Issue 2 fix) |
| 9 | `ChatWindowState.refreshAgentConfig()` doesn't refresh tools/memory state | `ChatWindowState.swift` | 353-357 | P2 |
| 10 | `saveConfiguration()` has no atomicity or error handling | `ConfigurationView.swift` | 821-983 | P2 (pre-existing) |

All ten verified against actual code on main. Issues 1-5 are the user-visible
bugs. Issues 6-10 are the deeper wiring gaps found during a second-pass trace.

**Most critical additions from the second pass**:
- **Issue 8** becomes a P0 the moment Issue 2 is fixed. Flipping `disableTools`
  in Settings leaves old tool specs in the preflight cache for every active
  session, so the first message after the flip still gets tools injected.
  This is a real user-visible regression, not a theoretical concern.
- **Issue 6** is a prerequisite for any future memory-reactive UI. Not urgent
  on its own, but a quick win.
- **Issue 7** is a latent landmine — the 10-second TTL cache doesn't know when
  config changes. Current code is safe because of the outer `config.enabled`
  gate, but the moment we add any feature that bypasses that gate, stale data
  will leak.

See `03-FIX-PLAN.md` for the revised execution order that handles all ten.
