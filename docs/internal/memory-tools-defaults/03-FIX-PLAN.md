# Fix Plan — Execution Order

> Phased execution for the 5 verified issues in `02-VERIFIED-ISSUES.md`.
> Each phase is an atomic commit that leaves the branch in a buildable state.

---

## Ordering rationale

The fixes have dependencies. Wrong order breaks things:

- **Issue 4 must be fixed before Issue 2** — otherwise flipping `disableTools`
  to `true` silently strips agent manual tools for every user of a configured
  agent. Fix the hard short-circuit first, then flip the default.
- **Issue 8 must be fixed before Issue 2** — otherwise flipping `disableTools`
  leaves stale tool specs in the preflight cache for every active session.
  Fix the invalidation hook first, then flip the default.
- **Issue 5 should land alongside Issue 1** — flipping memory off globally
  without a per-agent escape hatch is a regression for power users who
  configured memory agents.
- **Issue 6 (memory notification) should land alongside Issue 7 (TTL cache
  invalidation)** — both are part of the memory-reactive plumbing that makes
  the memory system correctly observable.
- **Issue 3 (chat-bar chip) should land before Issue 2** — so by the time the
  global default flips, users already have the in-chat toggle to flip it back
  per-conversation. Also: the chip's cycle function is where we invalidate
  the per-session preflight cache (Issue 8), so the chip and the invalidation
  hook land together.

### Proposed order

1. **Phase A — Tool safety nets**
   - Issue 4 — fix `resolveTools` hard short-circuit
   - Issue 8 — add preflight cache invalidation hooks (accessor on `ChatWindowManager`, invalidation helpers in `PluginHostContext`)
2. **Phase B — Memory safety nets**
   - Issue 5 — per-agent memory override (`Agent.memoryEnabled: Bool?`, `AgentManager.effectiveMemoryEnabled`, wiring in `MemoryContextAssembler`/`SystemPromptComposer`)
   - Issue 6 — `MemoryConfigurationStore.save()` posts `.memoryConfigurationChanged`
   - Issue 7 — `MemoryContextAssembler.invalidateCacheForConfigChange()` + observer on the new notification
3. **Phase C — Chat-bar Tools chip**
   - Issue 3 — `ChatWindowState.toolsDisabledOverride`, chip in `FloatingInputCard`, threading through `ChatView.sendMessage` and `WorkView`
   - Chip tap handler invalidates that session's preflight cache (uses the hook from Phase A)
4. **Phase D — Flip the defaults**
   - Issues 1 + 2 — flip both defaults together
   - Settings save now invalidates preflight cache for all active sessions when `disableTools` flips (uses the hook from Phase A)
5. **Phase E — Cleanup + tests + docs**
   - @State cosmetic cleanup
   - Issue 10 — wrap `saveConfiguration()` store writes in try-catch with error toast
   - Issue 9 — verify `ChatWindowState.refreshAgentConfig` scope, or switch chip to `@ObservedObject AppConfiguration.shared` approach
   - Migration-compat tests
   - Update `04-CHANGE-AUDIT.md` with final state

Each phase is shippable on its own. If we stop partway through, main is still
in a coherent state (each phase either adds safety nets or adds UX, and the
actual default flip is last).

---

## Phase A — Tool safety nets (Issues 4 + 8)

**Risk**: Medium. Fixes two pre-existing gaps that become load-bearing the
moment we flip `disableTools` default in Phase D.

### A.1 Fix `resolveTools` hard short-circuit (Issue 4)

Changes the semantics of `disableTools` from "kill all tools" to "kill
auto-discovery, honor per-agent manual". Existing users with
`"disableTools": false` (the default) see zero behavior change because the
guard doesn't fire for them. Existing users with `"disableTools": true` who
also had per-agent manual tools configured were getting NO tools before this
fix — after this fix, they start getting their manual tools. That's the
intended behavior, but it IS a silent correctness change for them.

**File**: `Packages/OsaurusCore/Services/Chat/SystemPromptComposer.swift`

- Replace the `guard !toolsDisabled else { return [] }` at line 168
- New logic:
  - Look up `toolMode` first
  - If `toolsDisabled == true && toolMode != .manual` → return `[]`
  - If `toolsDisabled == true && toolMode == .manual` → skip always-loaded +
    preflight, only return manual tools
  - If `toolsDisabled == false` → existing full path

### A.2 Preflight cache invalidation hooks (Issue 8)

The preflight cache holds tool specs per session and is never invalidated when
`disableTools` changes. After Phase D, this becomes a user-visible regression.
Need two hooks.

**File**: `Packages/OsaurusCore/Managers/Chat/ChatWindowManager.swift`

- Add a new accessor:
  ```swift
  public func allActiveSessionIds() -> [UUID] {
      windows.values.compactMap { $0.sessionId }
  }
  ```
- Needed by Settings save handler (Phase D) to iterate all open windows.

**File**: `Packages/OsaurusCore/Services/Plugin/PluginHostAPI.swift` (or wherever
`PluginHostContext.invalidatePreflightCache` lives)

- Verify there's already an `invalidatePreflightCache(sessionId:)` function
- If missing, add it (it's called from `ChatWindowManager.closeWindow`)
- Consider adding a batch variant:
  ```swift
  public static func invalidatePreflightCaches(sessionIds: [String]) {
      for sid in sessionIds {
          invalidatePreflightCache(sessionId: sid)
      }
  }
  ```
  to keep the Settings save handler clean.

### Change IDs

- `M-01` — Fix resolveTools to honor per-agent manual tools
- `M-02` — Add `ChatWindowManager.allActiveSessionIds()` accessor
- `M-03` — Verify / add `PluginHostContext.invalidatePreflightCache` batch variant

---

## Phase B — Memory safety nets (Issues 5 + 6 + 7)

**Risk**: Low. Additive field on Agent, new method on AgentManager, new
notification + observer. Existing Agent JSON decodes unchanged (new field
is optional with nil fallback).

### B.1 Per-agent memory override (Issue 5)

**File**: `Packages/OsaurusCore/Models/Agent/Agent.swift`

- Add `public var memoryEnabled: Bool?` with default nil
- Add to `CodingKeys`, decoder, memberwise init
- Ensure JSON encoding/decoding round-trips cleanly

**File**: `Packages/OsaurusCore/Managers/AgentManager.swift`

- Add `public func effectiveMemoryEnabled(for agentId: UUID) -> Bool`
- Pattern: agent-override-wins-over-global

**File**: `Packages/OsaurusCore/Services/Chat/SystemPromptComposer.swift`
(at `appendMemory`)

- Replace any direct read of `MemoryConfigurationStore.load().enabled` with
  `AgentManager.shared.effectiveMemoryEnabled(for: agentId)`
- The agent ID is already in scope in `appendMemory`

### B.2 `MemoryConfigurationStore` notification (Issue 6)

**File**: `Packages/OsaurusCore/Models/Memory/MemoryConfiguration.swift`

- Add a `Notification.Name.memoryConfigurationChanged` extension
- `MemoryConfigurationStore.save()` posts the notification after a successful save

### B.3 `MemoryContextAssembler` cache invalidation hook (Issue 7)

**File**: `Packages/OsaurusCore/Services/Memory/MemoryContextAssembler.swift`

- Add a public async method:
  ```swift
  public func invalidateAll() {
      cache.removeAll()
  }
  ```
- Add an observer at assembler init (or a fire-once app-launch observer)
  for `.memoryConfigurationChanged` that calls `invalidateAll()`
- Alternative: let `ConfigurationView.saveConfiguration()` call
  `invalidateAll()` directly after `MemoryConfigurationStore.save()`. Simpler,
  no observer pattern. **Recommended** for scope control.

### Change IDs

- `M-04` — `Agent.memoryEnabled: Bool?` field
- `M-05` — `AgentManager.effectiveMemoryEnabled` resolver
- `M-06` — Wire resolver into `SystemPromptComposer.appendMemory`
- `M-07` — `.memoryConfigurationChanged` notification + poster
- `M-08` — `MemoryContextAssembler.invalidateAll()` + caller from Settings save

---

## Phase C — Chat-bar Tools chip (Issue 3 + invalidation hook)

**Risk**: Medium. UI change in a high-traffic view (chat input bar). Binding
threading affects three files. Adds a new visible element to every chat window.
Plus per-chip preflight invalidation.

### Changes

**File**: `Packages/OsaurusCore/Managers/Chat/ChatWindowState.swift`

- Add `@Published var toolsDisabledOverride: Bool?`
- Document as ephemeral, per-window, resets on close

**File**: `Packages/OsaurusCore/Views/Chat/FloatingInputCard.swift`

- Add `@Binding var toolsDisabledOverride: Bool?` to struct
- Add `private var toolsToggleChip: some View` following the sandbox chip pattern
- Add helpers: `effectiveToolsDisabled`, `toolsChipActive`, `toolsChipBadge`,
  `cycleToolsOverride`, `toolsChipHelpText`
- Insert chip in `selectorRow` between sandbox and clipboard chips
- Wrap with `if workInputState == nil` so it only shows in chat mode
- **`cycleToolsOverride()` must also call
  `PluginHostContext.invalidatePreflightCache(sessionId: windowState.session.sessionId.uuidString)`**
  after mutating the override — otherwise the next request in that session
  still hits the stale preflight cache (Issue 8).
- Rely on `@ObservedObject var appConfig = AppConfiguration.shared` (already
  present at line 130) for reactivity on the global side (Issue 9 resolution).

**File**: `Packages/OsaurusCore/Views/Chat/ChatView.swift`

- Add binding pass-through: `toolsDisabledOverride: $windowState.toolsDisabledOverride`
- In `sendMessage`, resolve `effectiveToolsDisabled = override ?? chatCfg.disableTools`
- Pass `effectiveToolsDisabled` to `composeChatContext(toolsDisabled:)`

**File**: `Packages/OsaurusCore/Views/Work/WorkView.swift`

- Same binding pass-through (WorkView also instantiates FloatingInputCard)
- Chip hidden via the `workInputState == nil` gate in selector row

**File**: `Packages/OsaurusCore/Views/Chat/FloatingInputCard.swift` preview wrapper

- Pass `toolsDisabledOverride: .constant(nil)`

### Change IDs

- `M-09` — `ChatWindowState.toolsDisabledOverride`
- `M-10` — `FloatingInputCard.toolsToggleChip` + helpers + selectorRow integration
- `M-11` — Chip tap handler invalidates session preflight cache
- `M-12` — `ChatView.sendMessage` override resolution
- `M-13` — `WorkView` + preview call-site wiring

---

## Phase D — Flip the defaults (Issues 1 + 2 + Settings save invalidation)

**Risk**: High. This is the actual user-visible behavior change. Everything in
Phases A/B/C is the safety net.

### Changes

**File**: `Packages/OsaurusCore/Models/Memory/MemoryConfiguration.swift`

- Line 94: `enabled: Bool = true` → `enabled: Bool = false`

**File**: `Packages/OsaurusCore/Models/Chat/ChatConfiguration.swift`

- Line 102 (init default): `disableTools: Bool = false` → `disableTools: Bool = true`
- Line 149 (decoder fallback): `?? false` → `?? true`

**File**: `Packages/OsaurusCore/Views/Settings/ConfigurationView.swift`

- Update help text to remove the references to "chat bar" being a future thing
  (since Phase C adds the chip, the copy can now be accurate)
- **Critical invalidation wiring**:
  ```swift
  // In saveConfiguration() after ChatConfigurationStore.save(chatCfg):
  if previousChatCfg.disableTools != chatCfg.disableTools {
      let allSessionIds = ChatWindowManager.shared.allActiveSessionIds()
      PluginHostContext.invalidatePreflightCaches(
          sessionIds: allSessionIds.map { $0.uuidString }
      )
  }

  // After MemoryConfigurationStore.save(memoryCfg):
  if memoryCfg.enabled != tempMemoryEnabled {
      Task { await MemoryContextAssembler.shared.invalidateAll() }
  }
  ```
  Uses the hooks added in Phases A and B.

### Migration notes

- Users with `MemoryConfiguration.json` containing `"enabled": true` explicitly:
  preserved, memory still on
- Users without the key: get the new default (false)
- Same pattern for `ChatConfiguration.json` / `disableTools`

### Release note

```
Osaurus now ships with memory and tools disabled by default. Both can be
re-enabled in Settings → Chat or per-conversation via the Tools chip in
the chat input bar. Existing users with explicit configuration are
preserved; new installs start clean.
```

### Change IDs

- `M-14` — Flip `MemoryConfiguration.enabled` default
- `M-15` — Flip `ChatConfiguration.disableTools` default + decoder fallback
- `M-16` — Update Settings UI help copy to match new reality
- `M-17` — Settings save invalidates preflight + memory caches on relevant change

---

## Phase E — Cleanup + error handling + tests + docs

**Risk**: Low. Housekeeping + Issue 10 (saveConfiguration atomicity).

### Changes

- `ConfigurationView.swift`: update `tempDisableTools` and `tempMemoryEnabled`
  `@State` initial values to match new defaults (cosmetic, not a bug)
- `ConfigurationView.swift`: update `resetToDefaults()` to match new defaults
  if it touches these fields
- `ConfigurationView.swift`: wrap `saveConfiguration()` store writes in
  try-catch (Issue 10). Add error toast on failure. The try-catch scope:
  ServerConfigurationStore.save, ChatConfigurationStore.save, and the
  conditional MemoryConfigurationStore.save. ToastConfigurationStore is
  outside the scope (separate failure mode).
- Verify Issue 9 is resolved by `@ObservedObject AppConfiguration.shared`
  approach taken in Phase C. If not, add an explicit observer in
  `ChatWindowState` for memory changes.
- `ChatConfigurationStoreTests` (if it exists): add migration-compat test for
  `disableTools` flip — old JSON with `"disableTools": false` still decodes
  as `false` (explicit preservation)
- Add a `MemoryConfigurationStoreTests` if one doesn't exist, same pattern
- Update `docs/OpenAI_API_GUIDE.md` if it says anything about memory / tools
  defaults (likely not — the API is unaffected)
- Update `04-CHANGE-AUDIT.md` with the final state

### Change IDs

- `M-18` — @State initial cleanup + resetToDefaults match
- `M-19` — `saveConfiguration()` try-catch + error toast (Issue 10)
- `M-20` — Migration-compat tests for ChatConfiguration + MemoryConfiguration
- `M-21` — Final `04-CHANGE-AUDIT.md` entries

---

## Summary

| Phase | Risk | Change IDs | Count | Test / verify |
|-------|------|-----------|-------|---------------|
| A | Medium | M-01..M-03 | 3 | Manual: agent with `manualToolNames` + `disableTools=true` should get its tools. Verify `invalidatePreflightCache` helpers exist. |
| B | Low | M-04..M-08 | 5 | Decode existing Agent JSON, verify new field is nil. Toggle memory in Settings → verify `MemoryContextAssembler` cache is wiped on next request. |
| C | Medium | M-09..M-13 | 5 | Open a chat, verify chip appears; cycle through states; close window, verify override resets. Chip cycle invalidates that session's preflight cache. |
| D | High | M-14..M-17 | 4 | Fresh install: memory off, tools off. Upgrade with explicit settings: preserved. Settings save wipes preflight + memory caches when relevant. |
| E | Low | M-18..M-21 | 4 | Run `swift test`. Settings save with a simulated failure shows error toast. No stale state in `ChatWindowState.refreshAgentConfig`. |

**Total**: 21 individual changes across 5 phases. Each phase is a reviewable
atomic commit. Each change is documented in `04-CHANGE-AUDIT.md` as work
lands.

---

## What to do if review pushes back

Each phase is independently revertable:

- If D-5 (semantic change in `disableTools`) is rejected: revert Phase A, keep Phase C's chip, document the limitation in the chip help text
- If Issue 3 (chat-bar chip) is rejected: revert Phase C, keep Settings-only control, update help text to remove "chat bar" reference
- If Issue 5 (per-agent memory override) is rejected: revert Phase B, accept memory as a purely global setting
- If the default flip (Phase D) is rejected: revert Phases A-D entirely, ship only Phase C (chip) and E (docs) for future use

Phase A and B are the safety nets — without them Phase D is dangerous. Phase C
is the main user-facing feature alongside the default flip.
