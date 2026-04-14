# Memory/Tools Defaults + Chat-bar Override + Cache Engine — Review Package

> **Branch**: `feat/memory-tools-defaults`
> **Base**: `origin/main` @ `1327e479` (rebased 2026-04-13)
> **Head**: Phase E.10 at `da4d0f48`
> **Status**: ✅ **Code complete. 39 tests passing. Ready for team review.**
>
> Original scope was five fixes (D-1 through D-5) around memory/tools
> defaults + per-agent overrides + chat-bar chip. Scope expanded during
> execution to include the **full 6-stack cache engine configurability
> surface** that tpae/rcn wanted, plus a set of hazard fixes surfaced
> by a deep interaction audit. The original five are all closed.

## Current state — quick jump

| You want... | Read |
|------------|------|
| To understand what this branch is doing | `01-README.md` (this file) |
| To see every issue verified against main's code | `02-VERIFIED-ISSUES.md` |
| To see the execution plan (historical) | `03-FIX-PLAN.md` |
| To see every single change with before/after, blast radius, audit focus | `04-CHANGE-AUDIT.md` |
| To see which settings are user-configurable vs JSON-only | `05-CONFIGURABILITY-AUDIT.md` |
| To cherry-pick only part of this branch | `06-REVERT-GUIDE.md` |
| To see the deferred follow-up items with cohesive fix designs | `07-DEFERRED-FIXES.md` |
| To see cross-system interaction hazards + stop/stats/eviction trace | `08-INTERACTION-AUDIT.md` |
| To run the changes locally against your own models | `09-TEAM-REVIEW-PROMPT.md` |

## Branch contents at a glance

**22 commits ahead of `origin/main` at `1327e479`.**

| Phase | Commit | What |
|-------|--------|------|
| A | `7416dd5d` | Tool safety nets — `resolveTools` mode-aware short-circuit, `allActiveSessionIds()`, batch preflight invalidation |
| B | `956465ed` | Memory safety nets — per-agent `memoryEnabled`, resolver, composer gating, change notification, TTL cache wipe |
| C | `ba860b96` | Chat-bar Tools chip with per-window three-state override + cache invalidation |
| D | `dab594f7` | Flip `MemoryConfiguration.enabled` + `ChatConfiguration.disableTools` defaults to off; runtime preflight invalidation on save |
| E.1 | `80baca9a` | Cache Engine Settings subsection with disk usage readout + Clear button (initial 4/6 stacks) |
| E.2 | `49e9b9ca` | `showChatBarToolsChip` opt-out toggle |
| E.3 | `f0d7fb56` | Full 6-stack cache engine surface (+stacks 1 & 5 via `GenerateParameters`) + TurboQuant as osaurus default |
| E.4 | `3992f50d` | `Agent.memoryEnabled` editor UI toggle (closes configurability gap 1.1) |
| E.5 | `d10f9f64` | Settings save failure → error toast (closes Issue 10) |
| E.6 | `79d85755` | Migration-compat tests (13 tests) |
| E.7 | `8a4db2e2` | Chip override clearing on hide, partial-save messaging, cache subsection width constraint |
| E.8 | `53132792` | Core-logic unit tests (19 more) + `nextToolsOverrideState` pure helper |
| E.9 | `6d766836` | Deferred-fixes design doc (`07-DEFERRED-FIXES.md`) + localization consistency (DF-4) |
| E.10 | `da4d0f48` | Hazard fixes — cacheConfig decoder isolation, override clamping, disk downsize eviction + interaction audit doc (`08-INTERACTION-AUDIT.md`) |

Plus doc-only commits for `CONFIGURATION_KNOBS.md` (user-facing),
`05-CONFIGURABILITY-AUDIT.md`, `06-REVERT-GUIDE.md`, and the preflight
TTFT coordination note for tpae.

## Test coverage

**39 tests passing** in `Packages/OsaurusCore/Tests/Configuration/`:

- 13 migration-compat tests (old JSON files decode as expected post-flip)
- 8 tools chip cycle state machine tests (pure state transitions)
- 14 `makeGenerateParameters` TurboQuant substitution + clamping tests
- 2 `effectiveMemoryEnabled` resolver precedence tests
- 2 `ServerConfiguration` decoder isolation tests (hazard regression)

Run: `swift test --package-path Packages/OsaurusCore --filter Configuration`

---

## Why this branch exists

`osaurus/main` now has tpae's VMLX migration merged (PR #849). That merge took
substantial parts of my earlier `feat/vmlx-cache-migration` work — the package
swap, cache coordinator wiring, cache UI strip, and even scaffolding for a
Memory toggle in Settings. But the merge stopped short of several load-bearing
changes, leaving main in a **partially-shipped** state where the UI lies to
users about the actual defaults.

This branch fixes that gap:

1. Flips the two silent defaults (memory and tools) so the UI copy matches reality
2. Adds the missing chat-bar Tools chip so users can opt in per-conversation
3. Adds per-agent memory override so power users keep their memory-using agents alive
4. Fixes the hard short-circuit in `resolveTools` that would strip agent-level
   manual tools the moment we flip the `disableTools` default

Everything in this branch is small and targeted. No new architecture, no package
changes, no test rewrites. Just close the loop on what main is already half-way
through.

---

## Folder contents

| # | File | What |
|---|------|------|
| 01 | `01-README.md` | You are here — orientation + decision register |
| 02 | `02-VERIFIED-ISSUES.md` | Each issue with file:line references, cross-confirmed against main's code |
| 03 | `03-FIX-PLAN.md` | Phased execution plan with per-change intent |
| 04 | `04-CHANGE-AUDIT.md` | Per-change log as fixes land (appended as work progresses) |

Read in order.

---

## Scope

### In scope (5 fixes)

1. **MemoryConfiguration.enabled → false default** — align with existing UI copy
2. **ChatConfiguration.disableTools → true default** — same, and decoder fallback
3. **ChatWindowState.toolsDisabledOverride + Tools chip in FloatingInputCard** — close the UI-copy gap referencing a "chat bar" toggle that doesn't exist
4. **Agent.memoryEnabled: Bool? + AgentManager.effectiveMemoryEnabled** — per-agent override so memory-using agents survive the global flip
5. **Fix resolveTools hard short-circuit** — honor per-agent manual tools even when `toolsDisabled = true`, so agents configured for tools don't break when the global flips

### Explicitly out of scope

- **BatchEngine migration** — the concurrent-request architecture change. Too big, deserves its own branch
- **Experience Mode presets** (Simple / Balanced / Power / Developer) — a separate UX feature
- **First-launch onboarding modal** — depends on Experience Mode
- **Any package changes to vmlx-swift-lm** — stays where it is. One
  exception: we confirmed with tpae that the preflight TTFT fix and
  the `!isLocalModel` gate removal are his work to land on main.
  Coordination note in `04-CHANGE-AUDIT.md` under "External
  coordination — tpae's preflight TTFT fix".

**Note**: The original plan had "Cache settings hot-reload — not
needed, cache settings don't exist anymore" in this list. That's
now obsolete. The branch scope expanded during execution to build
the full 6-stack cache engine Settings surface, with hot-reload
behavior documented explicitly (stacks 1+5 hot, stacks 2+3+4+6 on
next model load). See Phase E.1/E.3 entries in `04-CHANGE-AUDIT.md`.

---

## Decision register

Each of these is reversible. Call out in review if you disagree.

### D-1: Flip MemoryConfiguration.enabled default to `false`

- **Rationale**: The UI copy on main already says "Off by default — memory can add thousands of tokens per request." The data layer contradicts the UI. This is a bug.
- **Alternative**: Leave default on, fix the UI copy instead. Rejected because the user explicitly asked for memory to be opt-in ("no automatic memory feature").
- **Migration**: Existing users with explicit `"enabled": true` in their `MemoryConfiguration.json` keep memory on (decoder reads explicit value, only falls back to `false` when the key is absent). Users who never touched the file get memory off on next launch.

### D-2: Flip ChatConfiguration.disableTools default to `true` + fix decoder

- **Rationale**: UI copy on main says "Tools are off by default — enable them here or via the chat bar". Data layer says tools on. Mismatch. The UI copy also references a "chat bar" toggle that doesn't exist — that's part of D-3.
- **Migration**: Existing users with explicit `"disableTools": false` keep tools on. Everyone else gets tools off on next launch.

### D-3: Add chat-bar Tools chip (the one the UI copy already references)

- **Rationale**: Main's Tools subsection help text already promises "enable them here or via the chat bar". The chat bar toggle doesn't exist. Either add the chip or remove the reference from the copy. Adding the chip is the better UX.
- **Scope**: Minimal — a single on/off chip that cycles `nil → opposite-of-global → nil`. Per-conversation, ephemeral (resets on window close). No popover, no per-tool list. Matches the sandbox/clipboard/thinking chip pattern already in the selector row.
- **Scope explicitly excluded**: Per-tool checkboxes, scope picker, "save as agent default" action. Those can come later as a richer popover.

### D-4: Add `Agent.memoryEnabled: Bool?` per-agent override

- **Rationale**: D-1 flips memory off globally. Users who had explicitly set up memory-using agents (a journaling bot, a long-running project assistant) lose the feature. A per-agent override lets them keep those agents working without turning memory on globally.
- **Alternative**: No per-agent override; users must enable memory globally. Rejected because it's all-or-nothing.
- **UI**: Add a toggle in the Agent editor. Tri-state: "Use global default" (nil) / "Force on" (true) / "Force off" (false). Defaults to nil.
- **Resolution**: `AgentManager.effectiveMemoryEnabled(for:)` returns the agent's override if set, otherwise reads `MemoryConfigurationStore.load().enabled`.

### D-5: Fix `SystemPromptComposer.resolveTools` hard short-circuit

- **Current behavior** (line 168): `guard !toolsDisabled else { return [] }` strips ALL tools when global is off, including per-agent manual tools. Before D-2 this was dead code (global default was `false`). After D-2 it becomes a real user-visible bug: agents configured with `toolSelectionMode: .manual` + `manualToolNames: [...]` suddenly have no tools.
- **Proposed change**: Rewrite the guard to honor per-agent manual tools:
  ```swift
  // Old:
  guard !toolsDisabled else { return [] }
  let toolMode = AgentManager.shared.effectiveToolSelectionMode(for: agentId)

  // New:
  let toolMode = AgentManager.shared.effectiveToolSelectionMode(for: agentId)
  // When global tools are disabled, only respect explicit per-agent manual
  // configuration. Agent defaults (auto-discovery) are still blocked.
  if toolsDisabled && toolMode != .manual {
      return []
  }
  ```
- **Semantic change**: `disableTools` now means "disable auto-discovery and built-in capability tools" rather than "strip every tool". Per-agent explicit config wins. Documented in the audit entry.
- **Trade-off**: Breaks the existing use case where `disableTools = true` was the "plain LLM backend, zero tools ever" flag. Users relying on that need to ensure their agents don't have `manualToolNames` set. Acceptable because:
  - Very few users explicitly set `manualToolNames` without also wanting those tools
  - The existing "plain backend" use case is also satisfied by just not configuring manual tools on the agent
- **Alternative considered**: Leave the short-circuit, add a warning in the audit that agent-level tools are dead when global is off, and document it in the chip help text. Rejected because it creates a confusing mental model.

### D-6: Migration for existing users

- New installs: memory off, tools off. Clean slate.
- Upgrading users: their explicit settings are preserved via decoder fallbacks. Users who had tools on (default) will notice tools are now off on next launch. **Small breaking change** — documented in the audit for the team to decide if we need a release note.

---

## What reviewers should challenge

1. **D-5 is the riskiest call.** Changing the semantics of `disableTools` from "absolute kill" to "auto-discovery kill" is a behavior change. If the team prefers the kill-switch semantics, we can instead:
   - Keep the short-circuit as-is
   - Add an explicit warning in the settings UI ("Disabling tools also strips per-agent manual tools")
   - Document the limitation in agent editor ("agent manual tools only work when global tools are enabled")

2. **D-2 is a visible behavior change.** Users upgrading will see the "Disable tools" toggle flip from off to on. Is a release note / upgrade nudge enough, or do we need an in-app notification?

3. **D-3 Tools chip is a new UI element.** It sits in the chat input bar selector row next to the existing chips. Review whether the placement / iconography / label feels right, or if we should defer to a Settings-only approach.

4. **D-4 per-agent memory override adds an Agent field.** Every Agent JSON gets a new optional field. Decoder has a fallback so existing Agent files still decode. Worth confirming we're OK with expanding the Agent schema again.

---

## Relationship to other in-flight work

- **`feat/vmlx-cache-migration` branch**: this branch's ancestor. Most of its work is already on main via tpae's PR. The Round 3 changes (this branch's scope) are what didn't make it. After this branch merges, `feat/vmlx-cache-migration` can be abandoned.
- **`feat/chat-experience-modes` branch**: historical. Experience Mode presets are out of scope here; that branch can still be revived later.

---

## Reviewing this branch

Worktree at `/Users/eric/osaurus-feat` on branch `feat/memory-tools-defaults`
rebased onto `origin/main` at `1327e479`. Head at `da4d0f48` (Phase E.10).
Not yet pushed to remote.

**For the team reviewer**: see `09-TEAM-REVIEW-PROMPT.md` for a
copy-pasteable prompt you can use to audit this branch against your
own models, verify defaults, and run the test suite. It walks through
checkout, build, tests, and the manual-check checklist from
`08-INTERACTION-AUDIT.md` §"Checklist for the team reviewer".

**For decision review** (before approving merge), focus on:
- `04-CHANGE-AUDIT.md` — every single change with before/after,
  blast radius, audit focus. This is the most important doc.
- `08-INTERACTION-AUDIT.md` — cross-system interactions, edge cases,
  hazards found + fixed, stop/stats/eviction trace
- `06-REVERT-GUIDE.md` — decision tree if you want to land only part
  of this branch (e.g. keep cache engine work, drop chat-bar UI)
- `07-DEFERRED-FIXES.md` — follow-up PR designs for the four minor
  items that didn't make this branch (three with full designs, one
  already closed)

**For historical context** (why this branch exists at all):
- `02-VERIFIED-ISSUES.md` — the original 10 issues verified against main
- `03-FIX-PLAN.md` — the original phased plan (superseded by the
  actual progress table in `04-CHANGE-AUDIT.md`)
