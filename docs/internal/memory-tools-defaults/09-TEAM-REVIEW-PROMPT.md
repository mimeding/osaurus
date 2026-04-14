# Team Review Prompt — `feat/memory-tools-defaults`

> **Purpose**: a copy-pasteable instruction set the team can use to
> audit this branch locally, run the automated test suite, verify
> behavior against their own models, and report findings in a
> structured way.
>
> **Branch**: `feat/memory-tools-defaults`
> **Head**: `da4d0f48` (Phase E.10)
> **Base**: `origin/main` at `1327e479`
> **Reviewer effort**: ~30–45 minutes for the full pass,
> ~10 minutes for a shallow smoke test.

---

## Copy-paste prompt for reviewers

The block below is the actual instruction set to hand to a reviewer.
Copy it into a DM, Slack message, or PR comment. Everything needed
to do a complete review is included — no reading other docs required
unless the reviewer hits a failure.

---

```
Hi — please review the `feat/memory-tools-defaults` branch when you
have ~30 minutes. It's 22 commits ahead of main, rebased cleanly onto
`1327e479`. Scope is: flip memory + tools defaults to off-by-default,
add chat-bar Tools chip, expose the full 6-stack vmlx cache engine in
Settings with TurboQuant as the osaurus default, plus a bundle of
correctness fixes. Full change list in
`docs/internal/memory-tools-defaults/01-README.md`.

## 1. Local checkout + build

```bash
# From your osaurus worktree
git fetch origin feat/memory-tools-defaults
git checkout feat/memory-tools-defaults
git log --oneline origin/main..HEAD   # should show ~22 commits, Phase A through E.10

# Build
swift build --package-path Packages/OsaurusCore
```

If the build fails on a symbol you don't recognize, it's probably
because the branch reaches into vmlx-swift-lm's `CacheCoordinatorConfig`
and `GenerateParameters` shadow types. Make sure your package
checkout is fresh. Zero compile errors expected.

## 2. Run the automated test suite

```bash
swift test --package-path Packages/OsaurusCore --filter Configuration
```

Expected: **39 tests passing** across five suites:
- Configuration migration compat (13) — old JSON files decode as expected
- Tools chip cycle state machine (8) — the chat-bar chip three-state logic
- makeGenerateParameters TurboQuant substitution (14) — Stack 5 quant
  substitution + defensive clamping of hand-edited JSON
- AgentManager.effectiveMemoryEnabled precedence (2) — per-agent override
- ServerConfiguration decoder isolation (2) — JSON-typo resilience

Any failure is a blocker; file details and I'll triage.

## 3. Manual smoke test with your own model

This is the bit that matters — run the branch against a model you
actually use and verify the behaviors below. Pick any model from your
Osaurus library (MLX local, Foundation, or a remote provider — each
covers different code paths).

### 3.1 Defaults on first launch

After checkout, delete or move these files so you see the fresh-install
experience:

```bash
mv ~/.osaurus/config/chat.json   ~/.osaurus/config/chat.json.bak
mv ~/.osaurus/config/memory.json ~/.osaurus/config/memory.json.bak
mv ~/.osaurus/config/server.json ~/.osaurus/config/server.json.bak
```

Launch Osaurus. Open Settings → Chat.

- [ ] **Tools** toggle is **off** by default (was on before this branch)
- [ ] **Memory** toggle is **off** by default (was on before this branch)
- [ ] **Show Tools chip in chat bar** is **on** by default
- [ ] Help text under the Tools toggle says "Tools are off by default
      — enable them here or via the chat bar"

Open Settings → Local Inference. Scroll to the **Cache Engine**
subsection (new in this branch).

- [ ] Section header reads "Cache Engine"
- [ ] Disk cache usage readout + **Clear** button are visible
- [ ] All control pickers default to "Auto"
- [ ] Numeric fields (Cache Block Pool, Prefill Step Size, Disk
      Cache Budget, SSM Companion Cache) are empty (meaning "Auto")
- [ ] KV Quantization Mode picker shows four options:
      **Auto (TurboQuant)** / Off / Affine / TurboQuant
- [ ] The help blurb at the top mentions the hot-reload split:
      "Stacks 1 and 5 take effect on next generation; stacks 2, 3,
      4, 6 take effect on next model load"

Restore your configs afterward:

```bash
mv ~/.osaurus/config/chat.json.bak   ~/.osaurus/config/chat.json
mv ~/.osaurus/config/memory.json.bak ~/.osaurus/config/memory.json
mv ~/.osaurus/config/server.json.bak ~/.osaurus/config/server.json
```

### 3.2 Tools chip in chat bar

Open a new chat window. Pick an MLX local model you usually use.

- [ ] Small chip labeled "Tools" is visible in the chat input bar
      selector row (next to the existing thinking/sandbox/clipboard chips)
- [ ] Chip is rendered in the "off" visual state (tools are off globally
      by default post-flip)
- [ ] Tap the chip once → it cycles to show a per-conversation override
      badge ("on" or whichever is opposite of the global state)
- [ ] Send a simple message ("what's 2+2?") → no tool specs appear in
      the prompt (verify via a print/log if you have one wired, or
      just verify the model responds as a plain LLM)
- [ ] Tap the chip a second time → cycles to match global
- [ ] Tap a third time → cycles back to "follow global" (badge disappears)
- [ ] Right-click the chip → context menu offers "Open Tools Settings"

Test the Settings ↔ chip sync:

- [ ] Open Settings → Chat → Tools → turn off "Show Tools chip in chat
      bar" → the chip disappears from the chat bar immediately
- [ ] Turn it back on → chip reappears
- [ ] If you had an explicit override set before hiding, it should
      now be cleared (cycle-to-follow-global state — this is Phase E.7's
      override-persistence fix)

### 3.3 Cache Engine settings — TurboQuant default

This tests the flagship Phase E.3 decision: TurboQuant is osaurus's
preferred default. Pick any MLX local model.

- [ ] Settings → Local Inference → Cache Engine → KV Quantization
      Mode is set to **Auto (TurboQuant)** on a fresh config
- [ ] Load a model and send a message. If your model produces
      reasonable output with the default TurboQuant(3,3) quant, the
      substitution is working. If the output looks broken, let me
      know which model and I'll triage — the substitution may need
      an exception for models that predate Turbo support.
- [ ] Explicitly switch the mode picker to **Off** → save → generate →
      output should still be reasonable (full-precision KV path)
- [ ] Switch to **TurboQuant** with custom key bits (e.g. 4) and
      value bits (e.g. 4) → save → generate → should still be
      reasonable
- [ ] Switch to **Affine** with bits=4, groupSize=64 → save →
      generate → legacy affine path, still reasonable output

Failure mode to watch for: the osaurus default substitution kicks in
when `kvQuantMode` is nil. If you ever see TurboQuant active when the
picker says "Off", or Off active when it says "Auto (TurboQuant)",
that's the flagship behavior broken.

### 3.4 Disk L2 cache — rotation + downsize

- [ ] Send a few messages to warm up the disk cache. Note the usage
      number in Settings → Local Inference → Cache Engine.
- [ ] Tap Clear → usage drops to 0, button becomes disabled
- [ ] Send more messages → usage grows
- [ ] Set Disk Cache Budget to 1.0 GB → save. **If your current
      usage exceeds 1 GB, you should see a toast: "Disk cache
      cleared — Lowered budget to 1.0 GB; cleared existing cache
      to match."** This is Phase E.10 Hazard 3 fix.
- [ ] Confirm usage on disk is actually gone: `du -sh ~/.osaurus/cache/kv_v2/`

### 3.5 Stop button during generation

- [ ] Send a prompt that will generate a long response (ask for a
      500-word essay or similar)
- [ ] Tap the Stop button mid-stream → generation should halt within
      ~1 token (not run to completion)
- [ ] The partial response stays visible; the input field reactivates
- [ ] Send another message → new generation works normally

This is confirming Phase E.10's audit trace that `Task.cancel()`
propagates through vmlx's token loop via `Task.isCancelled` checks.

### 3.6 TTFT and stats display

- [ ] Send a fresh message → note the TTFT shown after generation
      completes (hover or check the message footer)
- [ ] With Phase D defaults (tools off, memory off), TTFT should be
      **noticeably faster** than main because the system prompt is
      much shorter
- [ ] Tokens/sec display matches what you expect from your hardware
- [ ] Context size indicator in the input bar shows a reasonable
      token estimate
- [ ] TTFT number stops growing once the first token arrives (not
      counting entire generation time)

### 3.7 Agent memory override

- [ ] Create a new custom agent (Settings → Agents → New)
- [ ] Open the agent's Memory tab — you should see a new "Memory
      Settings" section at the top with a three-state picker:
      Follow Global / Force On / Force Off
- [ ] Set to **Force On** → save. Memory is now enabled for this
      agent even though global is off.
- [ ] Send a message with this agent → memory context should be
      injected (verify via a log or a /memory slash command if you
      have one)
- [ ] Set to **Force Off** → save. Memory is now suppressed for
      this agent.
- [ ] The default agent's Memory tab should NOT show this picker
      (intentional — the default agent always follows global by
      design)

### 3.8 Hand-edited JSON resilience (Hazard 1)

Optional but valuable — tests that a bad hand-edit doesn't nuke
your whole config.

- [ ] Quit Osaurus
- [ ] Edit `~/.osaurus/config/server.json` and add an invalid
      `cacheConfig` entry, e.g.:
      ```json
      "cacheConfig": { "kvQuantMode": "TurboQuant" }
      ```
      (The raw value is `turboQuant` lowercase — this is a deliberate typo)
- [ ] Launch Osaurus
- [ ] Open Settings → verify your **port, hotkey, CORS origins,
      eviction policy** are all still as you set them. They should
      NOT be reset to defaults. Only the cacheConfig falls back to
      its default.
- [ ] Console.app should show a log: "ServerConfiguration.cacheConfig
      decode failed, falling back to defaults"

This is Phase E.10's decoder isolation fix. Without it, one JSON
typo in an obscure knob would have silently reset your whole server
config.

## 4. Report findings

Reply with:

- **✅ All 8 sections pass** → approve and merge
- **🟡 Findings** → list the section number and what you saw.
  Include your model name, osaurus version on the branch, and macOS
  version.
- **🔴 Blocker** → test failed in a way that affects shipping. I'll
  prioritize triage.

If you run the test suite and get a flake, re-run once before
reporting — the migration-compat tests are deterministic, but some
of the higher-level tests touch `MemoryConfigurationStore.load()`
which can be affected by your local config state.

Full reference docs for each deferred item:
- `docs/internal/memory-tools-defaults/07-DEFERRED-FIXES.md`
- `docs/internal/memory-tools-defaults/08-INTERACTION-AUDIT.md`
- `docs/internal/memory-tools-defaults/04-CHANGE-AUDIT.md`
```

---

## Alternative: shallow smoke test (10 minutes)

If the team is short on time and just wants to sanity-check before
merging, this subset covers the high-value paths:

1. `swift test --package-path Packages/OsaurusCore --filter Configuration`
   → expect 39 passing
2. Open Settings → Local Inference → Cache Engine → verify the
   subsection renders cleanly with all the new controls
3. Open a chat window → verify the Tools chip is visible in the
   selector row
4. Send a test message with a model you usually use → verify it
   works (any model, any prompt, just proving the code path isn't
   broken)
5. Tap the Tools chip → verify it cycles without crashing
6. Tap Stop mid-generation on a longer response → verify it actually
   stops

If all six pass, the branch is safe to merge for most workflows.
Anything that touches deep Cache Engine configuration (quant modes,
affine bits, custom block sizes) can be validated in follow-up
after merge if needed.

---

## What reviewers should NOT bother with

These are documented in `07-DEFERRED-FIXES.md` with full fix
designs — please **don't** treat them as blockers:

- Disk cache readout staleness after Settings opens (DF-1)
- Mid-generation cache changes don't apply until model reload (DF-2)
- `SettingsStepperField` silently clamps invalid input (DF-3)

Each has a complete cohesive fix design in 07-DEFERRED-FIXES.md
ready for a follow-up PR. Flagging them again during review won't
change the plan — they're already known and have cost/benefit
analyses.

---

**Last updated**: Phase E.10 commit `da4d0f48`.
