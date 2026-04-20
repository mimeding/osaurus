# Development Plan

This plan treats PR #893 as the architectural baseline: Osaurus is a single Chat / Agent Loop product, not a split Chat Mode plus Work Mode product.

The development path is incremental. Each increment should be small enough to review, carry a business rationale, include targeted tests, and reinforce the same product direction:

- Chat is the product surface.
- Tools are the capability surface.
- The Agent Loop is the behavior contract.
- Durable state is added only when restart, API, audit, or security requirements justify it.

## Current Branch Focus

Branch: `codex/pr893-import-export-next-steps`

Immediate objective: make the first practical import/export capabilities work through the registry, starting with Markdown, CSV/TSV, and PDF. Markdown, CSV, and PDF import already existed through `DocumentParser`; this branch adds registry-driven Markdown, CSV/TSV, and PDF export so the capability registry is no longer export metadata only.

## Increment Policy

Every development increment should include:

- one focused capability or contract change;
- registry, model, or runtime code changes only where needed;
- tests for the exact behavior being introduced;
- documentation explaining the user impact and maintainer rationale;
- no Work Mode revival and no parallel durable workflow store.

## Maintainer Philosophy Guardrails

The maintainer direction after PR #893 is simple: Osaurus should become easier to reason about, not broader through duplicate surfaces. Development should therefore favor:

- explicit capability registration over hidden extension switches;
- chat-first user workflows over a revived Work Mode;
- narrow, reviewable feature slices over large multi-format rewrites;
- source-preserving file behavior before richer semantic conversion;
- scaffold-only metadata when intent is clear but production behavior is not ready.

## 1. Agent Loop Contract Baseline

Status: implemented in the PR #893 follow-up stack.

The loop controls are `todo(markdown)`, `clarify(question)`, and `complete(summary)`. They are model-visible tools in auto and manual tool modes, and they are omitted only when tools are explicitly disabled.

This remains the dependency for all later work because autonomous import/export, artifact generation, and API-visible execution all need a reliable loop contract.

## 2. Chat Artifact Hardening

Goal: preserve user trust as Work artifacts move into Chat.

### Strategic Rationale

Chat becomes the place where users ask for work and receive files. That means generated artifacts must obey the same trust boundary every time. The product cannot rely on users noticing unsafe paths, hidden traversal, or ambiguous filenames.

### Tactical Plan

1. Keep filename sanitization strict.
2. Reject invalid destination names instead of trying to repair unsafe paths silently.
3. Keep host-folder sources inside the selected root.
4. Keep sandbox sources inside the expected sandbox workspace or agent directory.
5. Make artifact metadata safe enough to display, persist in transcript-derived state, and hand to artifact handlers.
6. Add tests before broadening artifact types or export behavior.

### Operational Requirements

- Run `SharedArtifactSecurityTests` for every artifact change.
- Add a traversal test for every new artifact source type.
- Keep artifact files under the chat artifact directory.
- Do not allow artifact export code to bypass `SharedArtifact` path checks.

### Next Increments

- Add export validation for `SharedArtifact` destinations when a UI save/export path is wired.
- Add artifact preview smoke tests for CSV and PDF cards after UI integration.
- Add a transcript replay test proving enriched artifact metadata is enough to reconstruct the artifact card after restart.

## 3. Import/Export Capability Registry

Goal: make file import/export extensible instead of hard-coded.

### Strategic Rationale

The registry is the long-term product surface for file capability truth. It lets Osaurus describe what it supports, how safe it is, what runtime it needs, and whether support is complete or scaffold-only. This reduces maintainer risk because new formats become isolated capabilities instead of scattered extension checks.

### Tactical Plan

1. Make real capabilities for the formats users need first.
2. Keep import and export source types explicit.
3. Use registry metadata for icons, supported extensions, trust level, runtime requirements, and scaffold-only status.
4. Keep unsupported formats explicit.
5. Add tests for import, export, round trip, and invalid destinations.

### Implemented First Increment

Markdown:

- `md` and `markdown` import remain lightweight prompt-safe text ingestion.
- `md` and `markdown` export now write document, text, or text-artifact sources through the registry.
- export preserves Markdown source text and normalizes line endings without rendering to HTML or rich document formats.

CSV/TSV:

- `csv` and `tsv` import remain lightweight prompt-safe text ingestion.
- `csv` and `tsv` export now write document, text, or text-artifact sources through the registry.
- export normalizes line endings and final newline without pretending to preserve workbook semantics.

PDF:

- `pdf` import continues to extract text through PDFKit and render page images when no text is available.
- `pdf` export now writes text/document sources to a simple paginated PDF.
- existing PDF artifacts can be exported by copying the original PDF file.

Chat UI:

- shared artifact cards now show an Export action only when the registry reports a real exporter.
- scaffold-only export metadata is still documented, but is not presented as a finished export option.

### Next Increments

1. Add attachment-chip export affordances for imported user documents.
2. Add a small user-facing export picker when a source supports more than one registry-backed real exporter.
3. Add validation results to the UI so scaffold-only capabilities are visible but not presented as finished exports.
4. Add JSON export once the source model can distinguish raw text from structured records.
5. Add richer CSV support only after there is a table model; until then, avoid claiming workbook or typed-cell fidelity.
6. Add PDF layout improvements only after the simple text PDF export is stable.

### Operational Requirements

- Run `ImportExportCapabilityRegistryTests`.
- Run `DocumentParserSecurityTests` for import-size and parsing boundaries.
- Add format-specific tests before adding a format to registry metadata.
- Do not add UI extension switches; UI should ask the registry.

## 4. Typed Inference Events

Goal: replace fragile sentinel-string handling with typed streaming events.

### Strategic Rationale

Tool execution and artifact creation are too important to depend on accidental text markers. Typed events make the harness safer, improve OpenAI-compatible streaming, and keep tool-card display behavior separate from execution triggers.

### Tactical Plan

1. Treat text deltas, tool-call argument deltas, single tool requests, batched tool requests, metadata, and completion as separate event types.
2. Execute tools only from authoritative tool-request events.
3. Preserve existing chat UI tool-card behavior while removing execution reliance on display-only strings.
4. Add provider fixtures for malformed and interleaved streaming.
5. Keep artifact markers display-compatible until all call sites consume typed artifact events.

### Next Increments

- Add integration tests that combine text, tool calls, and artifact output in one stream.
- Add OpenAI-compatible streaming fixtures for batched tool calls.
- Add negative tests proving plain text that looks like a tool or artifact marker is not executed.
- Add a migration path from artifact marker strings to typed artifact-created events.

### Operational Requirements

- Run `InferenceEventAdapterTests`.
- Add at least one streaming fixture for every provider-specific bug fixed.
- Keep API compatibility tests close to the streaming adapter rather than only in UI tests.

## 5. MLX Runtime Tuning

Goal: improve local model reliability without regressing lower-memory Macs.

### Strategic Rationale

Osaurus adoption depends on local inference feeling stable on real Apple Silicon machines. Runtime tuning should adapt to available RAM and model characteristics while preserving tool-call correctness.

### Tactical Plan

1. Keep RAM-aware context and cache policy deterministic.
2. Preserve JANG tool-call format behavior.
3. Prefer conservative defaults on lower-memory systems.
4. Add benchmark data before raising thresholds.
5. Keep runtime warnings actionable, not noisy.

### Next Increments

- Add a benchmark note for low, medium, and high RAM profiles.
- Add startup/runtime diagnostics explaining selected context and cache limits.
- Add regression tests for threshold boundaries and advisory messages.
- Add a manual smoke test using a local model that performs a simple tool call.

### Operational Requirements

- Run `MLXRuntimeTuningTests`.
- Run at least one local inference smoke test before changing default thresholds.
- Never tune performance in a way that changes tool-call format semantics.

## 6. Durable State Decision Pass

Goal: cover real product gaps without rebuilding Work Mode.

### Strategic Rationale

The product needs enough state for restart, API callers, audit, and user trust. It does not need a second durable workflow system. The safest default is transcript-derived state plus minimal chat-session metadata.

### Tactical Plan

1. Persist the latest accepted Agent Loop state: todo, complete summary, and clarification question.
2. Derive legacy state from transcript tool calls where possible.
3. Add new durable state only when it cannot be reconstructed from the transcript.
4. Keep state scoped to chat sessions and user-visible behavior.
5. Avoid durable state that recreates hidden Work Mode lifecycle.

### Next Increments

- Add transcript replay tests for imported/exported artifacts once export UI is wired.
- Add API-visible state only when external callers need it to recover after restart.
- Add file-operation audit state only if destructive or permission-sensitive operations are introduced.
- Add background-task event state only when tasks outlive a chat turn.

### Operational Requirements

- Run `AgentLoopSessionStateTests`.
- Prove restart behavior with a session load test before adding state.
- Document every new durable field with the reason it cannot be derived.

## Review Order

Recommended review order for upcoming increments:

1. Registry export contract plus Markdown, CSV/TSV, and PDF exporters.
2. Chat UI export wiring for imported document attachment chips.
3. Artifact export validation and preview smoke tests.
4. Typed artifact-created event migration.
5. Runtime diagnostics and benchmark documentation.
6. Minimal durable state additions only if UI/API integration exposes a concrete restart gap.

This order keeps the fast user-visible win, CSV and PDF import/export, while preserving the architecture that PR #893 established.
