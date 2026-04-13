# Fix Plan — Execution Order

> Phased execution for the 5 verified issues in `02-VERIFIED-ISSUES.md`.
> Each phase is an atomic commit that leaves the branch in a buildable state.

---

## Ordering rationale

The fixes have dependencies. Wrong order breaks things:

- **Issue 4 must be fixed before Issue 2** — otherwise flipping `disableTools`
  to `true` silently strips agent manual tools for every user of a configured
  agent. Fix the hard short-circuit first, then flip the default.
- **Issue 5 should land alongside Issue 1** — flipping memory off globally
  without a per-agent escape hatch is a regression for power users who
  configured memory agents.
- **Issue 3 (chat-bar chip) should land before Issue 2** — so by the time the
  global default flips, users already have the in-chat toggle to flip it back
  per-conversation. If Issue 3 lands after, there's a window where users have
  no UI to enable tools without diving into Settings.

### Proposed order

1. **Phase A**: Issue 4 — fix `resolveTools` hard short-circuit (defensive, no default flip yet)
2. **Phase B**: Issue 5 — add per-agent memory override (defensive, no default flip yet)
3. **Phase C**: Issue 3 — add `ChatWindowState.toolsDisabledOverride` + chat-bar Tools chip + wire through `ChatView.sendMessage` and `WorkView` (UI ready, default still ON)
4. **Phase D**: Issues 1 + 2 — flip both defaults together (the actual behavior change, after all safety nets are in place)
5. **Phase E**: Cleanup + @State initial values + docs + tests

Each phase is shippable on its own. If we stop partway through, main is still
in a coherent state (each phase either adds safety nets or adds UX, and the
actual default flip is last).

---

## Phase A — Fix `resolveTools` hard short-circuit (Issue 4)

**Risk**: Medium. Changes the semantics of `disableTools` from "kill all tools"
to "kill auto-discovery, honor per-agent manual". Existing users with
`"disableTools": false` (the default) see zero behavior change because the
guard doesn't fire for them. Existing users with `"disableTools": true` who
also had per-agent manual tools configured were getting NO tools before this
fix — after this fix, they start getting their manual tools. That's the
intended behavior, but it IS a silent correctness change for them.

### Changes

**File**: `Packages/OsaurusCore/Services/Chat/SystemPromptComposer.swift`

- Replace the `guard !toolsDisabled else { return [] }` at line 168
- New logic:
  - Look up `toolMode` first
  - If `toolsDisabled == true && toolMode != .manual` → return `[]`
  - If `toolsDisabled == true && toolMode == .manual` → skip always-loaded +
    preflight, only return manual tools
  - If `toolsDisabled == false` → existing full path

### Change ID

`M-01` — Fix resolveTools to honor per-agent manual tools

---

## Phase B — Per-agent memory override (Issue 5)

**Risk**: Low. Additive field on Agent, new method on AgentManager, new
resolver lookup. Existing Agent JSON decodes unchanged (new field is optional
with nil fallback).

### Changes

**File**: `Packages/OsaurusCore/Models/Agent/Agent.swift`

- Add `public var memoryEnabled: Bool?` with `default nil`
- Add to `CodingKeys`, decoder, memberwise init
- Ensure JSON encoding/decoding round-trips cleanly

**File**: `Packages/OsaurusCore/Managers/AgentManager.swift`

- Add `public func effectiveMemoryEnabled(for agentId: UUID) -> Bool`
- Pattern: agent-override-wins-over-global

**File**: `Packages/OsaurusCore/Services/Memory/MemoryContextAssembler.swift`
or wherever memory-enabled is checked

- Needs inspection first — does the assembler know the agent ID at the check point?
- If yes: swap `config.enabled` for `AgentManager.shared.effectiveMemoryEnabled(for: agentId)`
- If no: the caller (`SystemPromptComposer.appendMemory`) has the agentId and should do the check before calling the assembler

**File**: Agent editor UI (deferred — see `01-README.md` D-4)

- Not in this phase. Ship the data layer now, add the UI toggle later.

### Change IDs

- `M-02` — `Agent.memoryEnabled: Bool?` field
- `M-03` — `AgentManager.effectiveMemoryEnabled`
- `M-04` — `MemoryContextAssembler` / `SystemPromptComposer` wiring

---

## Phase C — Chat-bar Tools chip (Issue 3)

**Risk**: Medium. UI change in a high-traffic view (chat input bar). Binding
threading affects three files. Adds a new visible element to every chat window.

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

- `M-05` — `ChatWindowState.toolsDisabledOverride`
- `M-06` — `FloatingInputCard.toolsToggleChip` + `@Binding` + helpers + selectorRow integration
- `M-07` — `ChatView.sendMessage` override resolution
- `M-08` — `WorkView` + preview call-site wiring

---

## Phase D — Flip the defaults (Issues 1 + 2)

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
- Verify the toggle labels are consistent after the flip (no "Disable tools"
  renaming — the inverted-logic label is fine, just the help text needs
  updating)

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

- `M-09` — Flip `MemoryConfiguration.enabled` default
- `M-10` — Flip `ChatConfiguration.disableTools` default + decoder fallback
- `M-11` — Update Settings UI help copy to match new reality

---

## Phase E — Cleanup + tests + docs

**Risk**: Low. Housekeeping.

### Changes

- `ConfigurationView.swift`: update `tempDisableTools` and `tempMemoryEnabled`
  `@State` initial values to match new defaults (cosmetic, not a bug)
- `ConfigurationView.swift`: update `resetToDefaults()` to match new defaults
  if it touches these fields
- `ServerConfigurationStoreTests.swift`: add migration-compat test for the
  `disableTools` flip — verify old JSON with `"disableTools": false` still
  decodes as `false` (explicit preservation)
- Add a `MemoryConfigurationStoreTests` if one doesn't exist, with the same
  migration-compat test
- Update `docs/OpenAI_API_GUIDE.md` if it says anything about memory / tools
  defaults (likely not — the API is unaffected)
- Update `04-CHANGE-AUDIT.md` with the final state

### Change IDs

- `M-12` — @State initial cleanup
- `M-13` — Migration-compat tests
- `M-14` — `04-CHANGE-AUDIT.md` final entries

---

## Summary

| Phase | Risk | Changes | Test / verify |
|-------|------|---------|---------------|
| A | Medium | `SystemPromptComposer` line 168 rewrite | Manual: agent with `manualToolNames` + `disableTools=true` should get its tools |
| B | Low | Agent field + AgentManager method + assembler wiring | Decode existing Agent JSON, verify new field is nil |
| C | Medium | 4 files: WindowState + FloatingInputCard + ChatView + WorkView | Open a chat, verify chip appears; cycle through states; close window, verify override resets |
| D | High | 2 files: MemoryConfiguration + ChatConfiguration + Settings copy | Fresh install: memory off, tools off; upgrade with explicit settings: preserved |
| E | Low | Tests + docs + cosmetics | Run `swift test`, verify migration tests pass |

---

## What to do if review pushes back

Each phase is independently revertable:

- If D-5 (semantic change in `disableTools`) is rejected: revert Phase A, keep Phase C's chip, document the limitation in the chip help text
- If Issue 3 (chat-bar chip) is rejected: revert Phase C, keep Settings-only control, update help text to remove "chat bar" reference
- If Issue 5 (per-agent memory override) is rejected: revert Phase B, accept memory as a purely global setting
- If the default flip (Phase D) is rejected: revert Phases A-D entirely, ship only Phase C (chip) and E (docs) for future use

Phase A and B are the safety nets — without them Phase D is dangerous. Phase C
is the main user-facing feature alongside the default flip.
