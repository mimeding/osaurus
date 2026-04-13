# Osaurus Configuration Knobs

This guide explains how to configure Osaurus directly through its JSON
config files — the "power-user knobs" that aren't exposed in the
Settings UI, plus a reference for everything that **is** exposed so you
can understand what each file contains.

- **Audience**: Users who want fine-grained control over Osaurus —
  memory budgets, retrieval tuning, manual tool lists, per-agent
  overrides.
- **Prerequisites**: A text editor. `jq` is nice to have for
  pretty-printing but not required.

---

## Where config lives

All Osaurus config lives under `~/.osaurus/`. The two paths that matter
for this guide:

```
~/.osaurus/config/
  ├── chat.json         # Chat behavior + generation settings
  ├── memory.json       # Memory system tuning
  ├── server.json       # Server port, network, eviction policy
  ├── sandbox.json      # Sandbox defaults
  ├── tools.json        # Tool registry prefs
  ├── toast.json        # Toast notification position
  └── voice/            # Voice input config
      ├── speech.json
      ├── vad.json
      └── transcription.json

~/.osaurus/agents/
  └── <uuid>.json       # One file per agent
```

Older installs may still have config in
`~/Library/Application Support/com.dinoki.osaurus/`. Osaurus migrates
to `~/.osaurus/` on first launch — edit the new location.

---

## Edit safely

1. **Quit Osaurus first.** The in-memory config cache is written back
   on save; edits made while Osaurus is running can be overwritten.
2. **Back up the file** before you touch it:
   `cp ~/.osaurus/config/memory.json ~/.osaurus/config/memory.json.bak`
3. **Validate JSON** before restarting:
   `cat ~/.osaurus/config/memory.json | jq .` — if `jq` errors, you
   have a syntax bug and Osaurus will fall back to defaults.
4. **Restart Osaurus.** Settings are read on launch; a few are
   hot-reloadable (listed below), but most need a restart to take
   effect.

If Osaurus fails to parse a config file on launch, it logs the error
and falls back to built-in defaults — your file is left alone on disk
so you can fix it and restart.

---

## `chat.json` — Chat configuration

Controls chat behavior, generation parameters, and tool discovery.

### Fields exposed in Settings UI

These are editable through **Settings → Chat** and **Settings → Agents**
— you usually don't need to touch the JSON for them.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `hotkey` | object | `⌘;` | Global hotkey to open a chat window |
| `systemPrompt` | string | `""` | Prepended to every chat with the default agent |
| `temperature` | float\|null | `null` | Sampling temperature (0.0–2.0). `null` = use model default |
| `maxTokens` | int | `16384` | Max output tokens per response |
| `contextLength` | int | `128000` | Max context window |
| `topPOverride` | float\|null | `null` | Nucleus sampling top-p (0.0–1.0) |
| `maxToolAttempts` | int | `15` | Max tool calls per turn before giving up |
| `coreModelProvider` | string\|null | `null` | Provider for memory/summary work (e.g. `"mlx"`) |
| `coreModelName` | string\|null | `null` | Model ID used for background memory/summary work |
| `workTemperature` | float\|null | `null` | Work mode temperature override |
| `workMaxTokens` | int\|null | `null` | Work mode max tokens override |
| `workTopPOverride` | float\|null | `null` | Work mode top-p override |
| `workMaxIterations` | int\|null | `null` | Max agent iterations per work task |
| `preflightSearchMode` | string | `"balanced"` | Tool discovery aggressiveness: `"off"`, `"fast"`, `"balanced"`, `"thorough"` |
| `disableTools` | bool | `true` | Master switch for tool calling. See note below. |
| `enableClipboardMonitoring` | bool | `true` | Clipboard monitoring for chat |

### Fields you can only edit via JSON

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `defaultModel` | string\|null | `null` | Model ID the default agent uses when you haven't picked one from the model picker. Per-agent `defaultModel` lives on each agent file and takes precedence. |
| `defaultAutonomousExec` | object\|null | `null` | Global default for the sandbox autonomous-exec config. See "Autonomous exec config" below. |

### About `disableTools`

Starting with the memory/tools defaults update, `disableTools` is
`true` by default. This means:

- Tool auto-discovery is **off** — prompts are shorter and TTFT is
  faster.
- Agents configured in **manual** tool mode (with an explicit
  `manualToolNames` list) still get their tools. This is an
  intentional escape hatch for power users.
- The chat window has a **Tools chip** in the input bar that lets you
  override the global flag per conversation without touching settings.

To re-enable tool auto-discovery globally, flip `"disableTools": false`
in `chat.json`, or toggle it in Settings → Chat.

---

## `memory.json` — Memory system

This is the file most power users will want to edit. The Settings UI
only exposes `enabled` and `summaryRetentionDays`; everything else —
budgets, retrieval tuning, verification thresholds — is JSON-only by
design. Exposing 17 sliders in Settings would bloat the UI for
everyone to serve a few.

### UI-exposed fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | bool | `false` | Master switch for memory injection |
| `summaryRetentionDays` | int | `180` | Days to keep conversation summaries |

**Starting with the memory/tools defaults update, `enabled` is `false`
by default.** Flip it to `true` (or toggle in Settings → Memory) to
turn memory on globally, or set `memoryEnabled: true` on a specific
agent (see "Per-agent overrides" below).

### Embedding backend

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `embeddingBackend` | string | `"mlx"` | Embedding provider. Valid: `"mlx"`, `"none"`. `"none"` disables vector search — memory falls back to text-only. |
| `embeddingModel` | string | `"nomic-embed-text-v1.5"` | MLX embedding model ID |

### Context budgets (tokens)

These control how many tokens each section of the memory context can
consume when injected into the system prompt. Default totals to
roughly 12,300 tokens across all budget fields, which is sized for a
128k-context model. **Lower these if you're hitting context limits
on smaller models.**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `profileMaxTokens` | int | `2000` | User profile section (never trimmed) |
| `workingMemoryBudgetTokens` | int | `3000` | Active recent entries |
| `summaryBudgetTokens` | int | `3000` | Rolling conversation summaries |
| `chunkBudgetTokens` | int | `3000` | Relevant conversation chunks |
| `graphBudgetTokens` | int | `300` | Knowledge graph relationships |

### Profile regeneration

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `profileRegenerateThreshold` | int | `10` | Number of new contributions before the user profile is regenerated. Lower = more frequent updates (higher cost). |

### Summary generation

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `summaryDebounceSeconds` | int | `60` | Seconds of inactivity before a conversation summary is generated. Lower = more frequent summaries. |

### Retrieval tuning

Controls how memory search (used for query-relevant retrieval) ranks
and diversifies results. Defaults are tuned for "useful but not
repetitive".

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `recallTopK` | int | `30` | Results returned from VecturaKit before reranking |
| `temporalDecayHalfLifeDays` | int | `30` | Half-life for temporal decay. Older entries score lower; at `N` days old they score 50% of fresh. Raise to weight history more, lower to prefer recency. |
| `mmrLambda` | float | `0.7` | Relevance vs. diversity tradeoff. `1.0` = pure relevance (may repeat similar facts); `0.0` = pure diversity (may drift off-topic). |
| `mmrFetchMultiplier` | float | `2.0` | Over-fetch multiplier before MMR reranking. Higher = more diversity candidates at higher cost. |
| `maxEntriesPerAgent` | int | `500` | Max active entries per agent before oldest are archived. `0` = unlimited. |

### Verification pipeline

Controls semantic/near-duplicate detection during memory extraction.
Raise thresholds to be stricter about what counts as a duplicate
(more entries stored); lower to be more aggressive about dedup (fewer
entries stored).

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `verificationEnabled` | bool | `true` | Run the extraction verification pipeline |
| `verificationSemanticDedupThreshold` | float | `0.85` | VecturaKit similarity score above which a candidate is marked as a semantic duplicate and skipped |
| `verificationJaccardDedupThreshold` | float | `0.6` | Jaccard similarity above which a candidate is marked as a near-text duplicate and skipped |

### Example: shrink memory for a 32k-context model

```json
{
  "enabled": true,
  "workingMemoryBudgetTokens": 800,
  "summaryBudgetTokens": 800,
  "chunkBudgetTokens": 800,
  "graphBudgetTokens": 100,
  "profileMaxTokens": 500,
  "recallTopK": 10
}
```

This caps memory at ~3000 tokens total, leaving headroom for the chat
itself.

### Example: prioritize very recent context

```json
{
  "enabled": true,
  "temporalDecayHalfLifeDays": 7,
  "mmrLambda": 0.9,
  "recallTopK": 15
}
```

Entries older than a week score half as high; MMR strongly favors
direct relevance over diversity; fewer candidates fetched.

---

## Agent files — `~/.osaurus/agents/<uuid>.json`

Each agent lives in its own JSON file. Most fields are editable through
Settings → Agents, but a few are only configurable via JSON.

### UI-exposed fields (reference)

`name`, `description`, `systemPrompt`, `themeId`, `defaultModel`,
`temperature`, `maxTokens`, `chatQuickActions`, `workQuickActions`,
`bonjourEnabled`, `toolSelectionMode`, `manualToolNames`,
`manualSkillNames`, `pluginInstructions`.

### JSON-only fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `memoryEnabled` | bool\|null | `null` | **Per-agent memory override.** `null` = follow the global `memory.json` setting. `true` = force memory on for this agent even when global is off. `false` = force memory off for this agent even when global is on. |

### Per-agent memory override: the use case

Starting with the memory/tools defaults update, memory is **off by
default globally**. If you have a specific agent that was trained up
with working memory, user profile, and summaries, you can keep it
working without flipping the global switch:

```json
{
  "name": "My Research Agent",
  "systemPrompt": "You are a research assistant that remembers prior conversations.",
  "toolSelectionMode": "manual",
  "manualToolNames": ["web_search", "fetch_url"],
  "memoryEnabled": true
}
```

Global memory stays off for every other agent; this one gets full
memory injection.

### Read-only fields (don't edit)

Osaurus manages these automatically. Editing them will break things.

- `id`, `createdAt`, `updatedAt` — identity + timestamps
- `agentIndex`, `agentAddress` — cryptographic identity derived from
  your master key
- `isBuiltIn` — set by Osaurus when the agent is created

---

## `server.json` — Server + network

### UI-exposed fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `port` | int | `1337` | HTTP server port |
| `exposeToNetwork` | bool | `false` | Bind to `0.0.0.0` (LAN) vs `127.0.0.1` (local only) |
| `startAtLogin` | bool | `false` | Launch Osaurus at login |
| `hideDockIcon` | bool | `false` | Menu bar only (no dock icon) |
| `modelEvictionPolicy` | string | varies | When to unload models from memory |
| `genTopP` | float | `1.0` | Server-wide top-p default |
| `genMaxKVSize` | int\|null | `null` | Max KV cache size |
| `allowedOrigins` | array<string> | `[]` | CORS allowed origins, comma-separated in the UI |

### JSON-only fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `appearanceMode` | string | `"system"` | App appearance mode. Valid: `"system"`, `"light"`, `"dark"`. There's a separate Themes tab for theme colors; this controls whether Osaurus follows macOS dark/light mode. |

### Read-only fields (don't edit)

- `numberOfThreads` — auto-set from `ProcessInfo.activeProcessorCount`
- `backlog` — system constant (256)

---

## Autonomous exec config

Used for sandbox command execution. Lives in two places:

1. **Global default** → `chat.json` → `defaultAutonomousExec` (JSON-only)
2. **Per-agent override** → agent file → `autonomousExec` (editable
   through Sandbox Settings for the `enabled` + `pluginCreate` fields;
   the other two are JSON-only)

Shape:

```json
{
  "enabled": false,
  "maxCommandsPerTurn": 10,
  "commandTimeout": 30,
  "pluginCreate": true
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | bool | `false` | Master switch for autonomous command execution |
| `maxCommandsPerTurn` | int | `10` | Max commands the agent can run in a single turn (JSON-only) |
| `commandTimeout` | int | `30` | Timeout in seconds per command (JSON-only) |
| `pluginCreate` | bool | `true` | Allow the agent to create new sandbox plugins |

### Example: a cautious research agent

Edit the agent file directly:

```json
{
  "name": "Careful Researcher",
  "autonomousExec": {
    "enabled": true,
    "maxCommandsPerTurn": 3,
    "commandTimeout": 15,
    "pluginCreate": false
  }
}
```

This agent can run up to 3 commands per turn, each capped at 15
seconds, and cannot create new plugins.

---

## Hot-reload vs. restart

Most config changes require a **full Osaurus restart**. A handful of
settings re-read on the next save in Settings UI but not on JSON edit:

| Setting | Picks up on |
|---------|-------------|
| `chat.json` → `disableTools` | Settings save OR next request (cache invalidated on save) |
| `memory.json` → `enabled` | Settings save OR next request (cache invalidated on save) |
| `memory.json` → budgets/thresholds | **Next app restart** |
| `server.json` → `port`, `exposeToNetwork` | Settings save (triggers server restart) |
| `server.json` → `genTopP`, `genMaxKVSize` | Next model request |
| Agent file edits | **Next app restart** |

If you're editing a JSON file directly, always restart Osaurus to
be safe.

---

## Troubleshooting

**"I edited memory.json but nothing changed."**
Did you restart Osaurus? Did you check the file with `jq .` to
confirm it's valid JSON? If the file is invalid, Osaurus falls back
to defaults silently.

**"My per-agent `memoryEnabled` isn't being respected."**
Check that the agent file is a custom agent, not the built-in default.
The Default agent always follows the global `memory.json` setting
because it represents "use the global chat settings". Custom agents
override.

**"I set `disableTools` to false but tools still aren't loading."**
Three things to check: (1) is the agent in `.auto` tool selection
mode? (2) Is `preflightSearchMode` not `"off"`? (3) Try the Tools chip
in the chat bar — that's now the recommended per-conversation override.

**"Osaurus deleted my edits."**
Osaurus doesn't delete config files, but it does rewrite them on
Settings save. If you edit JSON while Osaurus is running and then
save in Settings, your JSON edits will be overwritten by whatever the
UI had in its `temp*` state fields. **Always quit Osaurus before
editing JSON.**

**"I broke memory.json and Osaurus won't start."**
It starts — but with defaults, and your file is untouched. Check
the Osaurus log for the parse error, fix the JSON, restart.

---

## Quick reference: "I want to…"

| Goal | File | Field |
|------|------|-------|
| Turn memory on globally | `memory.json` | `enabled: true` |
| Turn tools on globally | `chat.json` | `disableTools: false` |
| Keep memory for one specific agent only | `agents/<uuid>.json` | `memoryEnabled: true` |
| Shrink memory for a 32k-context model | `memory.json` | Lower budget fields (see example above) |
| Force dark mode | `server.json` | `appearanceMode: "dark"` |
| Tighter tool auto-discovery | `chat.json` | `preflightSearchMode: "fast"` |
| More frequent summary generation | `memory.json` | Lower `summaryDebounceSeconds` |
| Less aggressive dedup in memory | `memory.json` | Raise `verificationSemanticDedupThreshold` toward `0.95` |
| Prioritize recent entries heavily | `memory.json` | Lower `temporalDecayHalfLifeDays` to ~7 |
| Cap an autonomous agent to 3 commands/turn | `agents/<uuid>.json` | `autonomousExec.maxCommandsPerTurn: 3` |

---

## Appendix: what `coreModelProvider` / `coreModelName` do

These two fields on `chat.json` control which model Osaurus uses for
**background memory work** — profile generation, conversation
summaries, the extraction pipeline. This is separate from the model
you're chatting with. Defaults to the same model; you can set it to
a smaller/cheaper model for faster background processing:

```json
{
  "coreModelProvider": "mlx",
  "coreModelName": "mlx-community/Llama-3.2-3B-Instruct-4bit"
}
```

The Memory tab in Settings exposes these as a dropdown, but you can
also edit them directly.
