# Development Plan

This plan treats PR #893 as the architectural baseline: Osaurus is a single Chat / Agent Loop product, not a split Chat Mode plus Work Mode product.

The development path starts by making the Agent Loop contract reliable, then moves the remaining planned work onto that chat-native foundation.

---

## 1. Stabilize the Agent Loop Contract

**Goal:** Make every chat capable of reliable autonomous work when tools are enabled.

The loop controls are `todo(markdown)`, `clarify(question)`, and `complete(summary)`. They are real model-visible tools in both auto and manual tool modes. They are omitted only when tools are explicitly disabled.

Implementation requirements:

- `todo` writes or replaces the visible session checklist and then lets the model continue.
- `complete` ends the loop only after summary validation passes.
- invalid `complete` calls return a tool error/result and do not end the loop.
- `clarify` pauses visible chat only after a non-empty question is supplied.
- invalid `clarify` calls return a tool error/result and do not pause.

Business rationale: this makes the new single Chat / Agent architecture reliable enough to replace Work Mode without teaching local models a second execution protocol.

---

## 2. Harden Chat Artifacts

**Goal:** Preserve user trust as Work artifacts move into chat.

Artifacts must be safe by default:

- sanitize filenames;
- reject path traversal and sibling-prefix attacks;
- keep host-folder sources inside the selected folder;
- keep sandbox sources inside the expected sandbox workspace or agent directory;
- persist surfaced artifacts under the chat artifact directory.

Business rationale: once chat becomes the execution surface, generated files and copied files must obey the same trust boundary every time.

---

## 3. Build the Import/Export Capability Registry

**Goal:** Make file import/export extensible instead of hard-coded.

Document and artifact support should be registry-backed. The registry should describe supported extensions, trust level, active-content risk, prompt-ingestion behavior, icon metadata, and scaffold-only capabilities.

Business rationale: Osaurus can add formats and exporters without scattering file-extension logic through parser and UI code.

---

## 4. Adopt Typed Inference Events

**Goal:** Replace fragile sentinel-string handling with typed streaming events.

Typed events should represent text deltas, single tool requests, batched tool requests, metadata/stats, and completion. Tool execution remains authoritative only on tool-request events; display-only argument deltas are not execution triggers.

Business rationale: this improves API compatibility, local model tool calling, and streaming correctness.

---

## 5. Merge MLX Runtime Tuning

**Goal:** Improve local model reliability without regressing lower-memory Macs.

Runtime tuning should be RAM-aware, deterministic under test, conservative on low-memory systems, and compatible with JANG tool-call format resolution.

Business rationale: the harness compounds only if local inference remains fast and stable across common Apple Silicon machines.

---

## 6. Add Durable State Only Where It Is Justified

**Goal:** Cover real product gaps without rebuilding Work Mode.

Persist state only when it is needed after restart, required by an API caller, needed for audit/undo/security, or impossible to reconstruct from the chat transcript.

First target: persist only the latest Agent Loop control state in chat-session metadata: `todo(markdown)`, accepted `complete(summary)`, and accepted `clarify(question)`. Legacy sessions should derive the same state from transcript tool calls where possible. Artifact index metadata, file-operation review history, and machine-readable background task events remain candidates for later PRs only when a concrete restart/API/audit gap requires them.

Business rationale: this keeps the product simpler while preserving the specific durability users and integrations actually need.
