# Osaurus Development Plan

Updated: 2026-04-30

This plan turns the current repository state, public documentation, private planning notes, CI workflow, and contribution guidelines into a prioritized development roadmap. It is intentionally practical: work is grouped by risk, sequence, and the tests or documentation needed before it can be called done.

## North Star

Osaurus should be the local-first AI harness for macOS: agents, memory, tools, identity, voice, automation, and model access that remain useful across local and cloud providers while keeping user data under user control.

Near-term development should favor reliability, compatibility, contributor speed, and trustworthy extension points before expanding the feature surface.

## Current Assessment

The repo is already feature-rich:

- Core product: agents, memory, chat sessions, local MLX inference, remote providers, OpenAI/Anthropic/Ollama/Open Responses-compatible endpoints, MCP server/client support, schedules, watchers, voice input, storage encryption, sandbox execution, skills, methods, and plugins.
- Architecture: `OsaurusCore` follows a clear Models / Services / Managers / Views / Networking / Storage / Tools / Identity split, with a large SwiftUI surface and heavy runtime dependencies.
- Test posture: `OsaurusCore` has broad unit and integration coverage, CLI tests run separately, behavior evals live in `Packages/OsaurusEvals`, and CI gates core tests, CLI tests, SwiftLint, and shell script linting.
- Main development pressure: `OsaurusCore` is large and dependency-heavy, so small changes can pay the cost of MLX, FluidAudio, SQLCipher, VecturaKit, Sparkle, Containerization, and UI dependencies.
- Product pressure: the public docs present many features as stable, so the next releases need stronger compatibility suites, fewer edge-case regressions, and clearer completion criteria.
- Private planning pressure: high-fidelity document I/O is valuable, but it should follow shared foundations, fixture-based verification, and render checks rather than landing as a broad one-shot feature.

## Priority Framework

Use this order when choosing what to do next:

| Priority | Meaning | Default Action |
| --- | --- | --- |
| P0 | Blocks safe release or contributor trust | Fix before feature expansion |
| P1 | Improves reliability, compatibility, or development speed | Schedule in the next 1-2 milestones |
| P2 | Expands core product value on proven foundations | Start after P0/P1 risk is bounded |
| P3 | Ecosystem, polish, and growth work | Keep moving, but do not preempt P0/P1 |

## Phase 0: Documentation And Contributor Contract

Target: immediate

Goal: make the repo's written contract match how the repo actually builds, tests, and accepts changes.

Deliverables:

- Keep `docs/CONTRIBUTING.md`, `docs/DEVELOPER_TOOLS.md`, the PR template, and private development notes aligned with CI.
- Make `docs/DEVELOPMENT_PLAN.md` the public roadmap and link it from the documentation index.
- Keep private feature plans scoped to implementation details, not competing project direction.
- Add a consistent Definition of Done for code, docs, tests, security, and compatibility changes.
- Maintain a concise local verification matrix for core, CLI, evals, formatting, and env-gated integration suites.

Acceptance criteria:

- A new contributor can identify the right build/test command without reading CI YAML first.
- Docs do not reference stale cache salts, stale timeouts, wrong paths, or missing root files.
- PR template checklist matches `docs/CONTRIBUTING.md`.

## Phase 1: Release Hardening And Compatibility

Target: weeks 1-4

Goal: protect the existing surface area before expanding it.

P0/P1 work:

| ID | Priority | Work | Deliverables | Acceptance Criteria |
| --- | --- | --- | --- | --- |
| R1 | P0 | API compatibility guardrail | Scripted streaming/non-streaming checks for OpenAI Chat Completions, Open Responses, Anthropic Messages, Ollama chat, tool calls, and error envelopes | Results are reproducible locally and artifacts land under `results/` or `build/compat/` |
| R2 | P0 | Remote provider request parity | Golden request encoding tests for OpenAI-compatible, Anthropic, Open Responses, Ollama, and custom providers | Provider changes require fixture updates and test approval |
| R3 | P0 | Local runtime cancellation and cache safety | Tests around model lease lifetime, cancelled streams, disk cache restore, reasoning sentinel handling, and local/remote model switches | No known crash class can regress without a focused test failing |
| R4 | P0 | Storage and recovery clarity | Verify encrypted DB migration, plaintext backup, key rotation, vector-index rebuild, and mismatch UX | Storage docs and tests cover recovery and failure cases |
| R5 | P1 | CI stability dashboard | Document recurring CI failure modes and keep artifact summaries actionable | Failed CI runs identify build failure, launch hang, test hang, or assertion failure quickly |
| R6 | P1 | Accessibility enforcement | Add theme contrast warnings and at least one high-contrast preset path | Theme editor surfaces contrast risk before export |

Recommended sequence:

1. Stabilize request/response compatibility first, because API behavior is the integration contract.
2. Harden local runtime and storage next, because crashes or unrecoverable data loss are higher risk than UI polish.
3. Add accessibility guardrails before broad theme or onboarding iteration.

## Phase 2: Developer Velocity And Architecture Split

Target: weeks 4-8

Goal: reduce build/test drag and make ownership boundaries easier to preserve.

P1 work:

| ID | Priority | Work | Deliverables | Acceptance Criteria |
| --- | --- | --- | --- | --- |
| A1 | P1 | Split pure foundations | Extract low-dependency models, utilities, schemas, and protocol types into a lightweight package/target | Foundation-only tests do not import MLX, FluidAudio, Sparkle, Containerization, or SwiftUI |
| A2 | P1 | Fix boundary leaks | Move `VLMDetection` or isolate MLX/VLM imports out of otherwise pure model code | Pure targets compile without MLX/VLM products |
| A3 | P1 | Targeted test buckets | Group tests by dependency profile: foundation, networking, storage, inference, UI-adjacent, sandbox | CI can run fast buckets without rebuilding the full heavy graph for every change |
| A4 | P1 | Fixture discipline | Create stable fixture directories for API, storage migration, document parsing, plugins, and evals | New regression tests reuse fixtures instead of inventing ad hoc setup |
| A5 | P1 | Contributor labels and issue templates | Align issue labels with roadmap workstreams and "good first issue" scope | New contributors can find safe starter work without deep architecture context |

Notes:

- Keep `OsaurusCore` behavior unchanged during the split; treat this as build-system and dependency-risk reduction first.
- Start with pure code and tests. Do not split UI until the lower-level boundary is stable.

## Phase 3: Agent Capability Quality

Target: weeks 6-12

Goal: improve agent behavior with measurable evals and tighter tool contracts.

P1/P2 work:

| ID | Priority | Work | Deliverables | Acceptance Criteria |
| --- | --- | --- | --- | --- |
| G1 | P1 | Expand OsaurusEvals | Add suites for agent loop, tool calling, skill injection, method recall, and memory retrieval | Each suite has representative cases and machine-readable reports |
| G2 | P1 | Preflight selection tuning | Track selected tools/skills/methods, false positives, missed matches, and token overhead | Changes to preflight behavior can be compared across models |
| G3 | P1 | Tool error taxonomy | Normalize retryable, permission, validation, timeout, and provider errors across built-in, MCP, sandbox, and plugin tools | Agents receive actionable errors; UI shows user-safe summaries |
| G4 | P2 | Method lifecycle | Improve method creation, scoring, review, and retirement flows | Low-quality or stale methods decay without manual cleanup |
| G5 | P2 | Watcher/schedule observability | Add run history details, convergence diagnostics, and failure summaries | Users can explain why automation did or did not run |

Recommended sequence:

1. Add eval coverage before changing agent prompts or capability search weights.
2. Improve error envelopes and retries before increasing automation autonomy.
3. Expand watcher/schedule visibility after tool errors are understandable.

## Phase 4: High-Fidelity File I/O

Target: weeks 8-16

Goal: build reliable import, edit, render, verify, and export workflows for high-value document formats without slowing normal attachment parsing.

P2 work:

| ID | Priority | Work | Deliverables | Acceptance Criteria |
| --- | --- | --- | --- | --- |
| F1 | P2 | File I/O foundation | Shared adapter contract, artifact store, document graph, edit plan, fixture layout, render verifier interface | Two toy adapters can import, edit, export, and verify through the same contract |
| F2 | P2 | DOCX adapter MVP | Preserve paragraphs, runs, styles, tables, images, comments, headers/footers where supported | Five fixtures pass import/export/render verification and unsupported constructs are explicit |
| F3 | P2 | XLSX adapter MVP | Preserve sheets, formulas, styles, tables, charts, images, merged cells, and validation metadata where supported | Five fixtures pass recalculation-aware and rendered verification |
| F4 | P2 | PPTX adapter MVP | Preserve slide masters, layouts, shapes, text runs, images, charts, tables, notes, and media refs where supported | Five fixtures pass slide-image verification and package integrity checks |
| F5 | P2 | PDF intake and export | Extract text with coordinates, render pages, support OCR fallback, annotations, page assembly, and redaction-aware export | Generated PDFs have page count, dimensions, text coverage, annotation, and visual-diff checks |
| F6 | P2 | HTML adapter | Preserve DOM, CSS, links, assets, tables, headings, and accessibility attributes | Browser-backed verification checks DOM validity, assets, links, text, and screenshots |
| F7 | P2 | User-facing UI | Add artifact previews, limitations, diff/verification summaries, and export affordances | Users can inspect what changed before accepting an exported file |

Non-goals for the first File I/O milestone:

- Lossless editing of arbitrary PDFs as if they were semantic source files.
- Legacy binary Office editing for `.doc`, `.xls`, or `.ppt`.
- Treating Markdown, CSV, source code, or plain text as high-fidelity formats.
- Pixel-perfect replication of every vendor-specific Office rendering quirk.

## Phase 5: Plugin Ecosystem, Sandbox, And Trust

Target: ongoing, after Phase 1 guardrails

P2/P3 work:

| ID | Priority | Work | Deliverables | Acceptance Criteria |
| --- | --- | --- | --- | --- |
| E1 | P2 | Plugin registry trust path | Improve package signing, verification, rollback, outdated checks, and registry metadata | Installs fail closed on signature or version mismatch |
| E2 | P2 | Plugin developer loop | Tighten `tools create`, `tools dev`, frontend proxy, docs, and generated examples | A new plugin can be created, hot-reloaded, packaged, verified, and documented in one flow |
| E3 | P2 | Sandbox smoke suite | Env-gated sandbox integration tests for provisioning, built-ins, bridge auth, secrets, plugin registration, and artifact integrity | Sandbox changes have a reproducible local test path without running in normal CI |
| E4 | P3 | Marketplace polish | Better plugin discovery, screenshots/docs surfacing, compatibility badges, and good-first plugin examples | Users can choose trustworthy plugins without reading source first |
| E5 | P3 | Remote agent maturity | Pairing UX, tunnel observability, revocation flows, and cross-instance communication design | Remote access remains understandable and revocable |

## Security And Privacy Backlog

These items should be pulled forward whenever related code is touched:

- Encrypt or wrap VecturaKit vector index storage, or document a stronger mitigation if pluggable encryption remains blocked.
- Add threat-model checklists for sandbox bridge routes, remote pairing, plugin HTTP routes, and relay tunnels.
- Keep redaction tests current for access keys, bearer tokens, provider keys, sandbox bridge tokens, and plugin secrets.
- Require explicit user-visible failure modes for unsupported file I/O features, plugin install risks, and storage recovery gaps.
- Audit long-lived plugin databases and WAL checkpoint behavior.

## Documentation Backlog

- Add a short architecture decision record template for dependency pins, storage migrations, API compatibility changes, and sandbox security changes.
- Keep `docs/FEATURES.md` as the feature inventory, but use this plan for forward-looking priority.
- Add release checklists that connect docs, compatibility artifacts, appcast generation, acknowledgements, and signing.
- Add "known limitations" sections to major docs that do not currently state them.

## Definition Of Done

Code changes are done when:

- The change follows the layer rules in `docs/CONTRIBUTING.md`.
- Unit or integration tests cover the changed behavior, or the PR explains why tests are not reasonable.
- Public API, tool, storage, plugin, or file format changes update docs and fixtures.
- Security-sensitive changes include redaction, permission, failure-mode, and rollback thinking.
- UI changes include screenshots or recordings and check accessibility basics.
- Local verification commands are listed in the PR test plan.

Feature milestones are done when:

- The feature has a clear owner-facing doc page or an explicit entry in an existing doc.
- Unsupported cases fail loudly and usefully.
- Observability exists for common failure modes.
- Evals or compatibility scripts cover behavior that depends on model/provider output.
- Rollback or migration behavior is documented when data or compatibility is affected.

## Near-Term Sprint Breakdown

### Sprint 1

- Land this development plan and documentation cleanup.
- Fix stale development instructions and broken contribution links.
- Create or refresh API compatibility scripts around the current `results/openai_compat_report.md` workflow.
- Add missing golden tests for recent provider request encoding and tool serialization regressions.

### Sprint 2

- Add Open Responses and Anthropic compatibility fixtures alongside OpenAI Chat Completions.
- Expand `Packages/OsaurusEvals/Suites/Preflight` and create first `AgentLoop` smoke cases.
- Document storage recovery and vector-index limitations in release notes/checklists.

### Sprint 3

- Begin the architecture split with a pure foundation target proposal.
- Move or wrap MLX/VLM imports that leak into pure model code.
- Add target-specific CI or Makefile commands once the first split compiles.

### Sprint 4

- Start File I/O foundation work behind an internal feature flag.
- Build fixture layout and render verifier scaffolding before format-specific features.
- Implement DOCX as the first rich editable adapter only after the shared contract survives fixture tests.

## Planning Rules

- Prefer reliability and testability over adding a new surface area.
- Treat docs as part of the product contract.
- Add feature flags for large risky changes, especially inference, storage, sandbox, and File I/O.
- Keep PRs small enough to review against one workstream.
- Update this plan when a milestone completes or when priority changes.
