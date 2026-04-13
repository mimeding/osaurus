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

All five verified against actual code on main. All five need fixing on this
branch. See `03-FIX-PLAN.md` for the execution order.
