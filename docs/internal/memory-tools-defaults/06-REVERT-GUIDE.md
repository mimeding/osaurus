# Revert / Opt-Out Guide for `feat/memory-tools-defaults`

> Team doc: if you want to land **only part** of this branch, this is the
> instruction sheet. Written for the case where the team keeps the
> **cache engine work** and the **vmlx integration glue** but wants to
> drop or revert the **chat-bar UI changes** (Tools chip, Memory/Tools
> Settings additions, per-window overrides, chip opt-out toggles).
>
> Every option below is reversible and each phase is an atomic commit,
> so the team can cherry-pick freely or revert in place.

---

## TL;DR decision tree

```
Keep the cache engine + vmlx glue ───────────────┐
                                                 │
Want the chat-bar Tools chip visible?            │
├─ Yes, keep as-is ─────────────────────────▶ do nothing
├─ Hide for everyone (soft) ────────────────▶ flip init default to false (§2.1)
├─ Remove the chip entirely (hard) ─────────▶ revert commit ba860b96 (§2.2)
└─ Keep code, hide by policy ───────────────▶ already supported via
                                               ChatConfiguration.showChatBarToolsChip
                                               toggle in Settings (§2.1)

Want the tools/memory default flip?
├─ Keep off-by-default (current) ───────────▶ do nothing
└─ Revert to on-by-default ─────────────────▶ revert commit dab594f7 (§3)

Want the per-agent memory escape hatch?
├─ Keep as dormant code ────────────────────▶ do nothing (no UI, field is inert)
└─ Remove entirely ─────────────────────────▶ revert commit 956465ed (§4)

Want the preflight cache invalidation hooks?
└─ Always keep ─────────────────────────────▶ do nothing — these are pre-existing
                                               bug fixes unrelated to the UX
```

---

## Commit map (post-rebase on `1327e479`)

| Commit | Phase | Touches chat UI? | Touches cache engine? | Worth keeping standalone? |
|--------|-------|------------------|----------------------|---------------------------|
| `8abd4e9d` | Review docs | No | No | Docs only — drop or keep |
| `4736057a` | Revised plan doc | No | No | Docs only — drop or keep |
| `7416dd5d` | **Phase A** — tool safety nets | No | No | **Yes, keep** — pure bug fixes |
| `956465ed` | **Phase B** — memory safety nets | No | No | **Yes, keep** — pure additive |
| `ba860b96` | **Phase C** — chat-bar Tools chip | **Yes** | No | Optional |
| `dab594f7` | **Phase D** — flip defaults + save invalidation | No | No | Optional — behavior change |
| `93a84f2c` | Configurability audit doc | No | No | Docs only — drop or keep |
| `499993a6` | CONFIGURATION_KNOBS user doc | No | No | Docs only — drop or keep |
| `74ecfb54` | Audit doc progress update | No | No | Docs only — drop or keep |
| `80baca9a` | **Phase E.1** — cache engine settings UI (4/6 stacks) | Minor (Settings section) | **Yes** | **Yes, keep** — foundation of the cache work |
| `49e9b9ca` | **Phase E.2** — Tools chip opt-out toggle | Minor (Settings toggle + chip gate) | No | Optional |
| `f0d7fb56` | **Phase E.3** — full 6-stack cache surface + TurboQuant as default | Minor (adds stack 1/5 controls to the existing Cache Engine section) | **Yes** | **Yes, keep** — finishes the cache work |

**Minimum "cache engine only" cherry-pick**: `7416dd5d` + `956465ed` +
`80baca9a` + `f0d7fb56` (Phase A + B + E.1 + E.3). Those four give you:
- The `resolveTools` hard-short-circuit fix (Phase A bug fix)
- The per-agent memory override field (Phase B, dormant without UI)
- The 4-stack cache engine settings surface (Phase E.1)
- Full 6-stack coverage + TurboQuant-as-default (Phase E.3)

Phase E.3 depends textually on E.1 (it extends the same struct and the
same Settings subsection), so skipping E.1 and picking only E.3 will
not apply cleanly. Always take E.1 first.

Everything else is optional.

---

## 1. What "cache engine only" looks like

If the team wants to land **only** the cache/vmlx work, cherry-pick:

```bash
git cherry-pick 7416dd5d     # Phase A — tool safety nets (pre-existing bug fix)
git cherry-pick 956465ed     # Phase B — memory safety nets (dormant without UI)
git cherry-pick 80baca9a     # Phase E.1 — cache engine settings UI (4/6 stacks)
git cherry-pick f0d7fb56     # Phase E.3 — full 6-stack surface + TurboQuant default
```

Skip: `ba860b96` (chip), `dab594f7` (default flip), `49e9b9ca` (chip opt-out),
and all doc commits.

**Caveats**:
- `80baca9a` (Phase E.1) adds a new "Cache Engine" subsection to
  `ConfigurationView` under the "Local Inference" section. It does NOT
  touch the Chat section. Drop-safe.
- `80baca9a` also adds `ServerCacheConfig` to `ServerConfiguration`.
  This is a new Codable field with decoder fallback to `.default`
  (all nil), so old `server.json` files load cleanly without migration.
- `956465ed` (Phase B) adds `Agent.memoryEnabled` but no UI. Field is
  inert; cherry-picking alone has zero runtime behavior change. Codable
  migration is handled.

---

## 2. Options for the chat-bar Tools chip

Three levels of "remove":

### 2.1 Soft hide — flip init default (recommended)

No code is removed. The chip is opt-in rather than opt-out. Existing
users who had the chip visible see it disappear on next launch; users
who explicitly enabled it in Settings keep it.

**File**: `Packages/OsaurusCore/Models/Chat/ChatConfiguration.swift`

**Change 1** — init default:

```swift
// before
showChatBarToolsChip: Bool = true,
// after
showChatBarToolsChip: Bool = false,
```

**Change 2** — decoder fallback (same file, `init(from decoder:)`):

```swift
// before
showChatBarToolsChip =
    try container.decodeIfPresent(Bool.self, forKey: .showChatBarToolsChip) ?? true
// after
showChatBarToolsChip =
    try container.decodeIfPresent(Bool.self, forKey: .showChatBarToolsChip) ?? false
```

**Change 3** — reset-to-defaults in `ConfigurationView.swift`:

```swift
// before
tempShowChatBarToolsChip = true
// after
tempShowChatBarToolsChip = false
```

That's it. Two boolean flips and the chip is hidden for everyone by
default, but the Settings toggle still lets individual users turn it
back on.

**Pros**: zero code removal, trivial revert, every user has the choice.
**Cons**: the code still ships, so the team has to maintain it.

### 2.2 Hard remove — revert the Phase C commit

Removes the chip code entirely. Use this if the team wants to strip
every trace of the chip from the binary.

```bash
git revert ba860b96
```

**What that touches**:
- `ChatWindowState.swift` — removes `toolsDisabledOverride: Bool?`
- `FloatingInputCard.swift` — removes `toolsToggleChip` view,
  `cycleToolsOverride()`, `effectiveToolsDisabled`, `toolsChipEnabled`,
  `toolsChipBadge`, `toolsChipHelpText`, and the `@Binding var toolsDisabledOverride`
- `ChatView.swift` — removes the `windowState?.toolsDisabledOverride ?? chatCfg.disableTools`
  resolution and reverts to passing `chatCfg.disableTools` directly
- Removes the binding pass-through to the `FloatingInputCard` call site

**Knock-on effects**:
- Phase E.2 (`49e9b9ca`) depends on the chip existing — if you revert
  Phase C, you MUST also revert Phase E.2 or the `showChatBarToolsChip`
  toggle becomes meaningless.
- The `showChatBarToolsChip` field on `ChatConfiguration` from
  Phase E.2 is still a no-op without Phase C code, so revert both
  together:

  ```bash
  git revert 49e9b9ca ba860b96
  ```

**Pros**: clean removal, no dead code.
**Cons**: harder to add back later.

### 2.3 Keep code, hide by policy (no code changes)

The Settings toggle we added in Phase E.2 already lets you hide the
chip without changing any code. Ship the branch as-is and include in
release notes:

> "The per-conversation Tools chip is visible by default. If you prefer
> a minimal chat bar, disable it in Settings → Chat → Tools → 'Show
> Tools chip in chat bar'."

**Pros**: zero risk, every user has the choice.
**Cons**: still ships the UI for users who don't want it.

---

## 3. Options for the tools/memory default flip (Phase D)

Phase D changes two defaults:

| Field | Before | After (Phase D) |
|-------|--------|-----------------|
| `MemoryConfiguration.enabled` | `true` | `false` |
| `ChatConfiguration.disableTools` | `false` | `true` |

Plus adds the preflight cache invalidation hook in Settings save (this
is a pre-existing bug fix — keep this bit even if you revert the rest).

### 3.1 Revert the default flip entirely

```bash
git revert dab594f7
```

This undoes both default flips and the preflight invalidation hook in
`saveConfiguration`. Users upgrading get the old behavior (memory on,
tools on).

### 3.2 Keep the flips but revert the help-text wording

Not currently a separate commit — the help-text changes were
pre-existing on main (the "off by default" language was on main before
this branch started). So there's nothing to revert for wording.

### 3.3 Flip only one of the two

If the team wants memory off but tools on (or vice versa), edit by
hand rather than reverting the commit:

**Memory off, tools on**:
- Keep `MemoryConfiguration.enabled = false` (the change from `dab594f7`)
- In `ChatConfiguration.swift`, flip `disableTools: Bool = true` back to
  `= false` (init default) and `?? true` back to `?? false` (decoder)

**Tools off, memory on**:
- Keep `disableTools: Bool = true` (the change from `dab594f7`)
- In `MemoryConfiguration.swift`, flip `enabled: Bool = false` back to
  `= true` (init default). The decoder uses `defaults.enabled` so that
  cascades automatically.

---

## 4. Options for the per-agent memory escape hatch (Phase B)

Phase B adds:
- `Agent.memoryEnabled: Bool?` field (dormant — no editor UI)
- `AgentManager.effectiveMemoryEnabled(for:)` resolver
- `SystemPromptComposer.appendMemory` gating on the resolver
- `MemoryConfiguration.swift` `.memoryConfigurationChanged` notification
- `MemoryContextAssembler.invalidateAll()` + Settings save wiring

### 4.1 Keep as-is

Recommended. The field is inert without UI and the other pieces are
pure correctness fixes (notification posting, TTL cache invalidation).
Nothing to do.

### 4.2 Revert entirely

```bash
git revert 956465ed
```

Undoes:
- The new `memoryEnabled` field on `Agent`
- The resolver on `AgentManager`
- The composer's per-agent check
- The notification on `MemoryConfigurationStore.save()`
- The assembler invalidation hook

**Why you might want this**: if the team thinks the per-agent override
concept isn't worth the API surface, or if `Agent`'s Codable story
shouldn't grow any more fields before a bigger refactor.

**Why you probably shouldn't**: the invalidation hook (M-08) is a
correctness fix for stale memory-context caching, independent of the
per-agent field. Reverting this commit also reverts that fix.

---

## 5. Options for Phase A (tool safety nets)

Phase A contains:
- **M-01** — `resolveTools` hard short-circuit fix (pure bug fix)
- **M-02** — `ChatWindowManager.allActiveSessionIds()` accessor (additive)
- **M-03** — `PluginHostContext.invalidatePreflightCache{s}(sessionIds:)`
  batch helpers (additive)

### 5.1 Keep as-is

Strongly recommended. All three are defensive fixes that only matter
when the global tools flag is flipped. They have zero behavior change
on main today, and they unlock the runtime invalidation in Phase D
(M-16). Keep them regardless of which chat-bar UI decision the team
lands on.

### 5.2 Revert

```bash
git revert 7416dd5d
```

Not recommended — see above.

---

## 6. Options for Phase E.1 + E.3 (cache engine settings UI)

This is the **main deliverable** the team cares about. Phase E.1 laid
the foundation; Phase E.3 finished it. Together they add:

- `ServerCacheConfig` with optional knobs for **all 6 cache stacks**
  (Phase E.1 shipped 4 — stacks 2/3/4/6 — under the false footnote
  that stacks 1 and 5 were "managed automatically by the vmlx
  engine"; Phase E.3 re-audited that claim and exposed the missing
  two as 7 new fields: `prefillStepSize`, `kvQuantMode`,
  `affineKVBits`, `affineKVGroupSize`, `turboKeyBits`,
  `turboValueBits`, `quantizedKVStart`).
- Wiring through `ModelRuntime.buildCacheCoordinatorConfig` (stacks
  2/3/4/6) and `ModelRuntime.makeGenerateParameters` (stacks 1 and 5).
- **TurboQuant (keyBits 3, valueBits 3) as the osaurus default** when
  `kvQuantMode == nil`. This diverges from the vmlx package default of
  `.none` and is osaurus-specific — the substitution lives in
  `makeGenerateParameters` around line 607. Users who want raw
  full-precision KV must set `kvQuantMode: "none"` explicitly.
- New "Cache Engine" subsection in Settings → Local Inference with
  controls for all 6 stacks, including a segmented "Auto (TurboQuant)
  / Off / Affine / TurboQuant" picker and conditional bit steppers.
- Disk cache usage readout + Clear button.

**Hot-reload split** (important for anyone rewiring the Settings save
path): stacks 1 and 5 flow through `GenerateParameters` per request
and take effect on the next generation with no model reload; stacks
2, 3, 4, 6 flow through the immutable `CacheCoordinatorConfig` and
still require a model reload.

### 6.1 Keep as-is

Recommended.

### 6.2 Hide the Settings UI, keep the config model

If the team wants the `ServerCacheConfig` field to exist (for JSON
editing and future UI work) but NOT show the Settings subsection yet:

**File**: `Packages/OsaurusCore/Views/Settings/ConfigurationView.swift`

Find the call site near line 509 inside the "Local Inference" section:

```swift
SettingsDivider()

cacheEngineSubsection
```

Comment out or delete these two lines. The `cacheEngineSubsection` view
function can stay — Swift won't complain about a `@ViewBuilder` property
that's never read.

The enum helpers (`CacheTriState`, `CachePagedBlockSizeChoice`) and all
`@State` vars at the top of the struct can also stay. This keeps the
plumbing in place for a future re-enable.

### 6.3 Remove the UI entirely

Delete:
1. The two lines from 6.2 above
2. The `cacheEngineSubsection` view property
3. The `CacheTriState` and `CachePagedBlockSizeChoice` enums
4. The cache-related `@State` vars (tempCacheUsePaged, tempCacheMaxBlocks,
   tempCachePagedBlockSize, tempCacheEnableDisk, tempCacheDiskMaxGB,
   tempCacheSSMMaxEntries, diskCacheUsageBytes)
5. The hydration lines in `loadConfiguration`
6. The reset lines in `resetToDefaults`
7. The save lines that build `configuration.cacheConfig`

Keep `ServerCacheConfig` on the model side so JSON editing still works.

### 6.4 Remove everything including the config model

```bash
git revert f0d7fb56 80baca9a
```

Revert order matters — E.3 extends E.1, so revert E.3 first. Drops
the cache knob surface entirely (all 6 stacks, the TurboQuant default
substitution, and the Settings subsection). **Not recommended** —
this is the main reason the branch exists.

---

## 7. Feature matrix — what the team controls and how

| Feature | Default | Code-level flag | User-level flag | Runtime effect |
|---------|---------|-----------------|-----------------|----------------|
| `resolveTools` hard-short-circuit fix (Phase A M-01) | on | n/a — pure fix | n/a | `toolsDisabled=true` no longer strips manual-mode tools |
| `allActiveSessionIds()` accessor (Phase A M-02) | on | n/a — additive | n/a | none until called |
| Batch preflight invalidation (Phase A M-03) | on | n/a — additive | n/a | none until called |
| `Agent.memoryEnabled` field (Phase B M-04) | nil | n/a — dormant field | n/a (no editor UI yet) | none |
| `effectiveMemoryEnabled` resolver (Phase B M-05) | on | n/a — inert without M-04 usage | n/a | none |
| `appendMemory` gating (Phase B M-06) | on | n/a | via global `MemoryConfiguration.enabled` | empty memory section when disabled |
| `.memoryConfigurationChanged` notification (Phase B M-07) | on | n/a | n/a | observer fires on save |
| `MemoryContextAssembler.invalidateAll()` (Phase B M-08) | on | n/a | Settings save path | TTL cache wiped on memory config change |
| Chat-bar Tools chip (Phase C) | visible | `showChatBarToolsChip` init default | Settings → Chat → Tools toggle | chip hidden when flag false |
| Memory default flip (Phase D M-14) | off | `MemoryConfiguration.enabled` init default | Settings → Chat → Memory toggle | no memory section when off |
| Tools default flip (Phase D M-15) | disabled | `ChatConfiguration.disableTools` init default | Settings → Chat → Tools toggle **and** chip | no tool specs when disabled |
| Settings-save preflight invalidation (Phase D M-16) | on | n/a | n/a | preflight caches wiped when flag flips |
| Cache engine stacks 2/3/4/6 UI (Phase E.1) | visible, all auto | `cacheEngineSubsection` render | Settings → Local Inference → Cache Engine | all fields nil = vmlx auto-tune; **model reload required** |
| Tools chip opt-out (Phase E.2) | opt-in | `showChatBarToolsChip` init default | Settings → Chat → Tools → "Show Tools chip in chat bar" | chip visibility |
| Prefill step size — stack 1 (Phase E.3) | nil = 512 | `ServerCacheConfig.prefillStepSize` | Settings → Local Inference → Cache Engine → "Prefill Step Size" | per-request via `GenerateParameters`; **next generation** |
| KV quantization mode — stack 5 (Phase E.3) | **nil = TurboQuant (3/3)** (osaurus default, diverges from vmlx package `.none`) | `ServerCacheConfig.kvQuantMode` + `ModelRuntime.makeGenerateParameters` substitution | Settings → Local Inference → Cache Engine → "KV Quantization Mode" (Auto / Off / Affine / TurboQuant) | per-request via `GenerateParameters`; **next generation** |
| Affine KV bits + group size (Phase E.3) | nil = 4 / 64 (when mode == affine) | `ServerCacheConfig.affineKVBits`, `affineKVGroupSize` | conditional steppers when mode == affine | per-request; **next generation** |
| TurboQuant key/value bits (Phase E.3) | nil = 3 / 3 (when mode == turboQuant or auto) | `ServerCacheConfig.turboKeyBits`, `turboValueBits` | conditional steppers when mode == turboQuant or auto | per-request; **next generation** |
| Quantize after N tokens (Phase E.3) | nil = 0 | `ServerCacheConfig.quantizedKVStart` | conditional stepper when mode != off | per-request; **next generation** |

---

## 8. Summary of recommended options for each sub-decision

| Decision | Recommendation |
|----------|---------------|
| Keep cache engine work | **Yes** — this is the point of the branch |
| Keep Phase A fixes | **Yes** — pure bug fixes with no downside |
| Keep Phase B memory safety nets | **Yes** — correctness fixes + dormant field |
| Keep Phase C chip code | **Yes, but soft-hide via §2.1** — preserves the feature for users who want it while letting tpae and anyone else turn it off |
| Keep Phase D default flip | **Team decision** — if the team wants off-by-default UX, keep it; if not, partial-revert per §3.3 |
| Keep Phase E.1 cache UI | **Yes** — this is the deliverable |
| Keep Phase E.2 chip opt-out | **Yes, paired with §2.1** — gives both the default and the user choice |

**One-line recommendation if the team wants minimum UX noise**:
Keep everything, apply §2.1 (flip `showChatBarToolsChip` init default
to `false`). That gives the cache engine, the correctness fixes, and
the per-agent memory override, while hiding the Tools chip by default
and letting users opt in. No commits reverted; one file edit.

---

## 9. Things that are NOT reverted by any option

These stay on the branch regardless of which commits you drop:

- The **rebase onto `1327e479`** — already merged with upstream main.
- The team review docs in `docs/internal/memory-tools-defaults/` —
  delete the folder if the team doesn't want internal notes landing
  in the repo.
- The user-facing `docs/CONFIGURATION_KNOBS.md` guide — delete the file
  if the team doesn't want it.

---

## 10. Questions for the team

1. **Does the team want Phase D (default flip) at all?** If "we want
   tools/memory on by default", revert `dab594f7` entirely. If "we
   want one flipped but not the other", §3.3.

2. **Does the team want the chip code to ship at all?** If "never, not
   even hidden", use §2.2 hard-remove. If "ship it, default hidden",
   use §2.1 soft-hide. If "ship it, default visible", do nothing.

3. **Does the team want the per-agent `memoryEnabled` field?** If "not
   without editor UI", wait for gap 1.1 from `05-CONFIGURABILITY-AUDIT.md`
   before merging. If "fine as dormant code", ship Phase B as-is.

4. **Does the team want the audit docs in the repo?** `docs/internal/`
   is intentionally gitignored-adjacent — the folder is checked in but
   users don't see it. Team can keep for historical record or delete
   after merge.

5. **Should `docs/CONFIGURATION_KNOBS.md` ship publicly?** It's written
   for end users and is accurate as of `f0d7fb56` — the "Cache Engine
   (6-stack)" section under `server.json` documents every field
   introduced by Phase E.1 and E.3, including the TurboQuant-as-default
   behavior.

---

**Document status**: ready for team review alongside
`05-CONFIGURABILITY-AUDIT.md`.

**Branch**: `feat/memory-tools-defaults`.
**Doc captured at**: Phase E.3 (`f0d7fb56`). Still valid at Phase E.10
(`da4d0f48`) — the revert/opt-out options below all still apply.
Phases E.4 through E.10 added `Agent.memoryEnabled` editor UI, unit
tests, hazard fixes, and documentation. None of those change the
cherry-pick math in this guide; add the newer commits to whichever
group you're cherry-picking. See `04-CHANGE-AUDIT.md` for the full
per-phase commit map.
