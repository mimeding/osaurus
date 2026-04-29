# Osaurus PR Recovery Brief

Last refreshed: 2026-04-29

This brief is the editable recovery map for the current PR stack and issue queue. It intentionally tracks maintainer disposition, not full implementation detail.

## Live State

- Open PRs: 16.
- Open issues: 33 total, with 14 bugs and 19 enhancements. Three enhancement issues also carry `good first issue`.
- Recently resolved reliability item: #969, GPU saturation on app open, was closed by #970. Keep it on the watchlist for the next release because regressions here are user-visible and expensive.
- Execution checkout: use `/Users/mmeding/Documents/Claude/Projects/osaurus-exec` and worktrees under `/Users/mmeding/Documents/Claude/Projects/osaurus-worktrees/`.
- Do not execute from `/Users/mmeding/Documents/Claude/Projects/osaurus`; keep that checkout as read-only reference material.

## PR Dispositions

| PR | Lane | Disposition |
| --- | --- | --- |
| #955 | Baseline/capability | Internal merge candidate after fresh CI. Rebased onto current `main`; local focused tests and full CI-style Xcode workspace test passed. A workflow cache fix was added because the previous GitHub failure restored non-exact DerivedData and broke EventSource module resolution before tests started. |
| #927 | Document lower stack | Internal merge candidate after #955. Rebased onto current `main`; local adapter/parser tests passed; fresh CI pending. |
| #929 | Document lower stack | Stack candidate after #927. Restacked onto the rebased #927 tip; local XLSX reader tests passed; fresh CI pending. |
| #936 | Document lower stack | Stack candidate after #929. Restacked onto the rebased #929 tip; local XLSX emitter round-trip tests passed; fresh CI pending. Previous failure should be rechecked after the DerivedData cache fix. |
| #937 | Document upper stack | Inspect only until #936 lands. Rebase and retest workbook agent tools after the lower document stack is on `main`. |
| #939 | Document upper stack | Inspect only until #936 lands. Rebase and retest CSV/TSV streaming after #937. |
| #940 | Document upper stack | Inspect only until #936 lands. Prior failure matches the EventSource module-resolution class; recheck after the cache fix and lower-stack merge. |
| #941 | Document upper stack | Inspect only until #936 lands. Rebase after #940 and retest plugin document registry surfaces. |
| #942 | Document upper stack | Inspect only until #936 lands. Rebase last and retest structured attachment bridging. |
| #957 | Provider | Preferred Azure Foundry candidate. Local clean merge into current `main` and `RemoteChatRequestEncodingTests` passed. Needs CI or maintainer-run validation before merge because the fork branch currently reports no checks. |
| #835 | Provider | Superseded by #957. Keep only as comparison material for classic Azure deployment URL/API-version behavior; close once #957 lands or the unique behavior is harvested. |
| #913 | Overflow | Do not debug as one rewrite PR. Ask author to split into reviewable macOS/Windows portability slices, or close. |
| #967 | External/overlap | Green and non-draft. Review after #955 because it touches model/config/storage surfaces and claims #964. |
| #958 | External/security | Green but draft. Hold for author readiness and a focused HPKE/security review. |
| #962 | External/TTS | Draft with failing `test-core`. Require targeted TTS/model-manager repro or author acceptance of maintainer fixes before deeper debugging. |
| #963 | External/localization | Draft with no checks. Require ready state, rebase, and CI. Decide after #873 localization baseline. |
| #873 | External/localization | Old green CI but now conflicts. Keep as zh-Hans localization baseline; rebase or close before accepting overlapping localization PRs. |

## Issue Priority Map

### P0 Reliability

| Issue | Type | Next action |
| --- | --- | --- |
| #903 System prompts not injected at runtime | bug | Reproduce against current chat dispatch path after #955 because capability dispatch touches prompt/runtime behavior. |
| #823 Tools unusable despite permissions | bug | Reproduce with sandbox/tool-resolution suites; verify permission state and tool registry indexing. |
| #647 No results whatsoever | bug | Reproduce on current model/runtime stack; check model selection, inference dispatch, and failure surfacing. |
| #852 Models stopped responding as expected | bug | Cluster with #647 and #959; capture provider/local runtime logs before code changes. |
| #959 DeepSeek tool calls fail with HTTP 400 | bug | Add provider-specific request fixture for missing `reasoning_content`; verify request-shaping logic. |
| #969 GPU goes to 100% when opening app | closed bug | Monitor after #970; keep launch-time inference, polling, animation, and Metal work out of app open. |

### P1 Product Reliability

| Issue | Type | Next action |
| --- | --- | --- |
| #964 Wrong report of storage space | bug | Covered by #967; verify after #955/#967 review. |
| #952 Access-Control-Allow-Origin CORS error | bug | Add HTTP origin regression coverage for configured allowed origins. |
| #789 Search tool never found by any model | bug | Reproduce with capability/tool search suites after #955. |
| #689 Transcription mode is very unreliable | bug | Isolate VAD/transcription failure mode before UI fixes. |
| #662 Invalid request format | bug | Reproduce with OpenAI-compatible request fixtures and provider fallback behavior. |
| #416 Command-based MCP providers do not work despite documentation | bug | Verify stdio provider launch, docs, and sandbox boundaries. |
| #615 Local Lemonade/OpenAI-compatible server connection | bug | Fold into remote-provider compatibility matrix. |
| #828 Minimax 2.7 not connecting | bug | Add provider-specific connection fixture once credentials/repro details are clear. |

### P2 Enhancements

| Issue | Type | Next action |
| --- | --- | --- |
| #555 Support for Azure Foundry | enhancement, good first issue | Covered by #957; close after validated merge. |
| #587 Add support for local MCP Server | enhancement | Triage against current MCP server/client feature set and docs. |
| #546 Multi-agent support/access through the API | enhancement | Needs API contract design after agent/session source stabilization. |
| #443 Support pre-downloaded Hugging Face models from local cache folder | enhancement | Fit into model manager storage/cache roadmap. |
| #417 Add speech output for full voice conversations | enhancement | Pair with TTS work after #962 is split or fixed. |
| #430 Folders and Spaces | enhancement | Product design item; align with agent loop and shared artifacts. |
| #793 Community Plugin Browser | enhancement | Depends on plugin registry and trust model. |
| #869 Custom access keys and revoked-key UI cleanup | enhancement | Small security/product polish candidate after key-store tests. |
| #642 Local access without an access token | enhancement | Needs security decision before implementation. |
| #605 Function-key hot key for voice transcription | enhancement, good first issue | Good isolated settings/hotkey task. |
| #232 HTTP/SOCKS5 proxy support | enhancement, good first issue | Good isolated networking/config task if model-download and provider clients share proxy config. |

### P3 Backlog

| Issue | Type | Next action |
| --- | --- | --- |
| #948 macOS 26+ icon styling compatibility | enhancement | Cosmetic platform polish; schedule after release stability. |
| #886 Longcat model support | enhancement | Add once model registry/profile path is stable. |
| #833 Tensor parallelism | enhancement | Long-range runtime capability; requires architecture design. |
| #654 Default agent configuration and agent team functions | enhancement | Larger agent-product design item. |
| #445 Voice mode input from everywhere | enhancement | Fold into voice roadmap after transcription reliability. |
| #358 Unsupported model type: hunyuan_v1_dense | enhancement | Track as model registry/runtime support request. |
| #332 Auto screenshot feature | enhancement | Needs privacy and permission design. |
| #676 Dock icon is too large | bug | Cosmetic; fix opportunistically with icon styling work. |
| #22 Benchmarks for current models, more sizes | enhancement | Useful after runtime churn settles. |

## Merge Guardrails

- Do not merge stack PRs out of order. For documents: #927, #929, #936, #937, #939, #940, #941, then #942.
- No external PR gets a merge recommendation without green CI or a precise failure root cause.
- Treat non-diagnostic `test-core` failures as infrastructure until a specific failing test, compile error, or hang point is identified.
- Preserve user/private project folders. Only mutate the clean clone and worktrees named in this brief.
