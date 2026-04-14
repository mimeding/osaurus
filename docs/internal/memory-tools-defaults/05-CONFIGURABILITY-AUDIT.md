# Configurability Audit — `feat/memory-tools-defaults`

> Team review doc: every setting in osaurus that is **not** user-configurable
> through the UI on this branch, cross-referenced against the config models
> that back them. Goal is an approve/defer decision on each gap before we
> finalize the branch for merge.
>
> Generated from a full trace of the config models vs. `ConfigurationView`,
> `MemoryView`, `AgentDetailView`, and `SandboxView` on the current branch.
>
> **Audit scope**: user-facing settings only. System invariants
> (`let` fields, derived values, crypto identity) are listed under
> "non-issues" and don't need review.

---

## How to read this doc

Each gap has:
- **Field** with `file:line` anchor
- **What's persisted** — whether the config is read and saved by the store
- **What UI exists** — where (if anywhere) the field shows up in the UI today
- **Severity**:
  - `HARD` — user cannot configure without hand-editing JSON on disk
  - `SOFT` — intentionally JSON-only power-user knob, acceptable by design
  - `NON-ISSUE` — read-only invariant, not user-configurable by nature
- **Phase D impact** — whether this gap matters for the memory/tools
  default flip we're landing on this branch
- **Recommended action** — what the team is being asked to approve

---

## Section 1 — Hard gaps (JSON-only today)

### 1.1 `Agent.memoryEnabled` — introduced this branch, no editor UI

- **Field**: `Packages/OsaurusCore/Models/Agent/Agent.swift:106`
- **Persisted**: yes — added in M-04, Codable round-trips, `AgentsView`
  save-rebuild preserves it (M-04 companion edit)
- **UI**: **none**. No toggle in `AgentDetailView`.
- **Severity**: `HARD`
- **Phase D impact**: **critical**. The whole point of adding this field
  in Phase B was to give power users a per-agent escape hatch after
  Phase D flips `MemoryConfiguration.enabled` from `true` to `false`.
  Without a UI toggle, the escape hatch is JSON-only, which contradicts
  the stated design goal in `02-VERIFIED-ISSUES.md` Issue 5.
- **Recommended action**: **close on this branch** as part of Phase E.
  Add a three-state toggle in the agent editor (Follow Global / Force On /
  Force Off). Estimated cost: one `Picker` + one rebuild-line edit in
  `AgentsView.swift`.

### 1.2 `ChatConfiguration.defaultModel` — pre-existing gap on main

- **Field**: `Packages/OsaurusCore/Models/Chat/ChatConfiguration.swift:42`
- **Persisted**: yes — round-trips, but `saveConfiguration` at
  `ConfigurationView.swift:928` explicitly preserves the existing value
  (`let existingDefaultModel = previousChatCfg.defaultModel`) without
  providing a way to change it
- **UI**: **none** at the global level. Per-agent model pickers exist in
  `AgentDetailView` and cover most use cases, but there's no way to set
  the fallback the default agent uses
- **Severity**: `HARD`
- **Phase D impact**: none — unrelated to the defaults flip
- **Recommended action**: **defer to a separate PR**. This is
  pre-existing debt on `main` (verified — the gap was not introduced by
  any of our phases). Fixing it here expands the branch scope without
  any Phase D dependency. Worth a follow-up ticket.

### 1.3 `ServerConfiguration.appearanceMode` — pre-existing gap on main

- **Field**: `Packages/OsaurusCore/Models/Server/ServerConfiguration.swift:40`
- **Persisted**: yes — the `AppearanceMode` enum (system / light / dark)
  loads from disk in `ServerConfigurationStore.load()` and writes back
  in `.save()`
- **UI**: **none**. No `Picker` or `Menu` in `ConfigurationView`. There
  is a separate Themes tab, but appearance mode is distinct from theme.
- **Severity**: `HARD`
- **Phase D impact**: none
- **Recommended action**: **defer to a separate PR**. Same reasoning
  as 1.2 — pre-existing, no coupling to defaults flip.

### 1.4 `ChatConfiguration.defaultAutonomousExec` — global sandbox defaults

- **Field**: `Packages/OsaurusCore/Models/Chat/ChatConfiguration.swift:69`
- **Persisted**: yes — stored on disk, readable via
  `ChatConfigurationStore.load()`
- **UI**: **none** at the global level. Per-agent `autonomousExec` is
  exposed in `SandboxView.executionToggles` (lines 1277-1316), which
  covers the common path — but there is no global default editor.
- **Severity**: `HARD`
- **Phase D impact**: none
- **Recommended action**: **defer to sandbox-UX PR**. Fits with the
  other sandbox debt (1.6, 1.7 below). Not blocking for this branch.

### 1.5 `AutonomousExecConfig.maxCommandsPerTurn` + `.commandTimeout`

- **Fields**: `Packages/OsaurusCore/Models/Agent/Agent.swift:229` and `:230`
- **Persisted**: yes — part of the `AutonomousExecConfig` struct
- **UI**: **none** at either agent level or global level. The `enabled`
  and `pluginCreate` sub-fields are exposed in `SandboxView.executionToggles`,
  but these two integer knobs are JSON-only.
- **Severity**: `HARD`
- **Phase D impact**: none
- **Recommended action**: **defer to sandbox-UX PR**. Low priority —
  the defaults (10 commands/turn, 30s timeout) are sane for most users.

### 1.6 `Agent.sandboxPlugins` — split UX

- **Field**: `Packages/OsaurusCore/Models/Agent/Agent.swift:83`
- **Persisted**: yes — `AgentsView.swift` save-rebuild preserves it
- **UI**: **partial**. Plugin assignment lives in `SandboxAgentsView`,
  not in the primary agent editor. Users who open `AgentDetailView`
  don't see which plugins are assigned or have any way to change them.
- **Severity**: `HARD` if the user expects agent editor to be
  authoritative; otherwise `SOFT`.
- **Phase D impact**: none
- **Recommended action**: **defer to sandbox-UX PR**. Unifying the
  two surfaces is a non-trivial UX decision, not a one-line fix.

### 1.7 `Agent.autonomousExec` — split UX

- **Field**: `Packages/OsaurusCore/Models/Agent/Agent.swift:85`
- **Persisted**: yes — `AgentsView.swift:2865` rebuild includes it
- **UI**: **partial**. Same pattern as 1.6 — per-agent toggles live in
  `SandboxView`, not in `AgentDetailView`.
- **Severity**: `HARD` / `SOFT` — same caveat as 1.6
- **Phase D impact**: none
- **Recommended action**: **defer to sandbox-UX PR**. Bundle with 1.6.

---

## Section 2 — Soft gaps (intentional, JSON-only by design)

### 2.1 `MemoryConfiguration` budget / tuning fields

- **Fields**: 17 of them, all under
  `Packages/OsaurusCore/Models/Memory/MemoryConfiguration.swift:24-71`
  - `embeddingBackend`, `embeddingModel`
  - `summaryDebounceSeconds`
  - `profileMaxTokens`, `profileRegenerateThreshold`
  - `workingMemoryBudgetTokens`, `summaryBudgetTokens`,
    `chunkBudgetTokens`, `graphBudgetTokens`
  - `recallTopK`, `temporalDecayHalfLifeDays`
  - `mmrLambda`, `mmrFetchMultiplier`
  - `maxEntriesPerAgent`
  - `verificationEnabled`, `verificationSemanticDedupThreshold`,
    `verificationJaccardDedupThreshold`
- **UI**: `MemoryView` exposes `enabled` and `summaryRetentionDays`;
  everything else is JSON-only by explicit design. See the comment at
  `ConfigurationView.swift:962`:
  > "Budgets are not user-adjustable in this UI — users can edit
  > MemoryConfiguration.json directly for advanced tuning."
- **Severity**: `SOFT`
- **Phase D impact**: none — Phase D only touches `enabled`, which is
  fully UI-exposed
- **Recommended action**: **approve as-is**. Power-user knobs. Exposing
  17 budget sliders would bloat the Settings surface for zero mainstream
  benefit.

---

## Section 3 — Non-issues (system invariants)

For completeness — fields that showed up in the audit but are not
user-configurable by nature. No action needed.

| Field | Location | Reason |
|-------|----------|--------|
| `ServerConfiguration.numberOfThreads` | `ServerConfiguration.swift:43` | `let`, set from `ProcessInfo.activeProcessorCount` |
| `ServerConfiguration.backlog` | `ServerConfiguration.swift:46` | `let`, system constant (256) |
| `Agent.id` | `Agent.swift:53` | `let` UUID |
| `Agent.agentIndex` | `Agent.swift:79` | Derivation index for crypto identity, auto-assigned |
| `Agent.agentAddress` | `Agent.swift:81` | Derived from master key + agentIndex |
| `Agent.isBuiltIn` | `Agent.swift:73` | `let`, set at creation |
| `Agent.createdAt` | `Agent.swift:75` | Auto-set timestamp |
| `Agent.updatedAt` | `Agent.swift:77` | Auto-managed timestamp |

---

## Section 4 — Decision matrix for the team

For each hard gap, the team's approval is being requested on the
recommendation. Marking "approve" on a gap means the recommendation
lands as written; marking "block" means the gap has to be resolved
differently.

| # | Gap | Recommendation | Approve? |
|---|-----|---------------|----------|
| 1.1 | `Agent.memoryEnabled` editor toggle | **Close on this branch** (Phase E) — required to make the Phase D default flip honor its design goal | ☐ |
| 1.2 | `ChatConfiguration.defaultModel` global picker | **Defer to separate PR** — pre-existing, no Phase D coupling | ☐ |
| 1.3 | `ServerConfiguration.appearanceMode` picker | **Defer to separate PR** — pre-existing, no Phase D coupling | ☐ |
| 1.4 | `ChatConfiguration.defaultAutonomousExec` global editor | **Defer to sandbox-UX PR** | ☐ |
| 1.5 | `maxCommandsPerTurn` + `commandTimeout` knobs | **Defer to sandbox-UX PR** | ☐ |
| 1.6 | `Agent.sandboxPlugins` in agent editor | **Defer to sandbox-UX PR** | ☐ |
| 1.7 | `Agent.autonomousExec` in agent editor | **Defer to sandbox-UX PR** | ☐ |
| 2.1 | Memory budget/tuning JSON-only | **Approve as-is** — intentional | ☐ |

---

## Section 5 — What changes if you disagree

If the team wants to close **1.2 and 1.3** on this branch too (since
they're trivial `Picker` additions), that's ~30 extra lines of UI and
two more M-NN entries in `04-CHANGE-AUDIT.md`. Branch stays small and
coherent; merge conflict risk is minimal because the edits sit in
unrelated sections of `ConfigurationView.swift`.

If the team wants to close **any of 1.4-1.7** on this branch, that is
genuinely a sandbox-UX rework (the "split UX" for autonomous exec is a
product decision, not a bug) and I would push back on doing it here.
That work deserves its own design pass, its own audit doc, its own
branch.

If the team wants **1.1 deferred** instead of landing on this branch,
the Phase D default flip ships with an escape hatch that only power
users comfortable editing JSON can access. That is shippable but
contradicts the design goal captured in `02-VERIFIED-ISSUES.md` Issue 5.
Recommend against.

---

## Section 6 — Appendix: fully covered config surface

For reference, these config types were audited and found to have full
UI coverage on this branch. No gaps in these:

### `ChatConfiguration` — all of:
`hotkey`, `systemPrompt`, `temperature`, `maxTokens`, `contextLength`,
`topPOverride`, `maxToolAttempts`, `coreModelProvider`, `coreModelName`,
`workTemperature`, `workMaxTokens`, `workTopPOverride`,
`workMaxIterations`, `preflightSearchMode`, `disableTools`,
`enableClipboardMonitoring`

### `ServerConfiguration` — all of:
`port`, `exposeToNetwork`, `startAtLogin`, `hideDockIcon`,
`modelEvictionPolicy`, `genTopP`, `genMaxKVSize`, `allowedOrigins`

### `Agent` — most fields:
`name`, `description`, `systemPrompt`, `themeId`, `defaultModel`,
`temperature`, `maxTokens`, `chatQuickActions`, `workQuickActions`,
`bonjourEnabled`, `toolSelectionMode`, `manualToolNames`,
`manualSkillNames`, `pluginInstructions`

---

**Document status**: awaiting team review.
**Branch**: `feat/memory-tools-defaults`.
**Audit captured at**: Phase D (`dab594f7` post-rebase, originally
`66eeb7fe` pre-rebase — this doc's findings still apply verbatim).
**Gap 1.1 (Agent.memoryEnabled editor UI) closed in Phase E.4 (`3992f50d`).**
**Issue 10 (silent save failures) closed in Phases E.5 + E.7
(`d10f9f64` + `8a4db2e2`).**
**Next step after approval**: Phase E implements whichever gaps land
on "close on this branch" and the branch opens for PR review.
