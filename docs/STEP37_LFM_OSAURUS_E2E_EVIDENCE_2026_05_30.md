# Step 3.7 / LFM Osaurus E2E Evidence - 2026-05-30

This document records the current no-sign Osaurus app proof for the Step/LFM
vMLX pin. It deliberately separates proven rows from partial rows.

## Code State

- vMLX pin: `0e5b8289bda477fa284d6c81f01e2c0a198021da`.
- vMLX fixes:
  - Step tool-call parser support for Step XML and narrow schema-gated bare
    `name({"arg": ...})` calls on reasoning/content rails.
  - Step required-tool fallback closes the native thinking rail before the
    explicit function-call contract so `tool_choice: required` does not remain
    trapped in hidden reasoning.
- Osaurus fix: local JANGTQ sidecar preflight accepts bundles that declare
  `format: "jangtq"` with `jangtq_runtime.safetensors` even when
  `weight_format` is absent.
- Osaurus fix: SwiftTransformers local-tokenizer loading routes Step sentinel
  templates through the Step fallback, disables Step thinking only for explicit
  required tool choice, and preserves normal optional-tool behavior otherwise.
- Osaurus cache policy: engine-selected TurboQuant KV remains topology-gated.
  Full simple-KV models can use TurboQuant KV. Step 3.7 is the explicit mixed
  full-attention + SWA exception: vMLX converts only `KVCacheSimple`
  full-attention layers to TurboQuant KV and preserves `RotatingKVCache`
  sliding layers for disk-backed restore. LFM SSM/Mamba hybrid cache still uses
  native KV plus disk-backed restore and SSM companion state.

## No-Sign / No-Keychain Boundary

- App build:
  `/tmp/osaurus-step37-pr/build/DerivedData-step37-nosign-623fffc3-258d207/Build/Products/Release/osaurus.app`.
- Build path used `scripts/live-proof/build-keychain-free-osaurus.sh`.
- Xcode build settings included `CODE_SIGNING_ALLOWED=NO`,
  `CODE_SIGNING_REQUIRED=NO`, empty `CODE_SIGN_IDENTITY`, and
  `AD_HOC_CODE_SIGNING_ALLOWED=NO`.
- The only seal was the script's local ad-hoc seal with no signing identity,
  no notary, no `security` command, and no password/keychain prompt.
- Live app launches used `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`, isolated
  `OSAURUS_TEST_ROOT`, and explicit `OSU_MODELS_DIR`.

## Proven Live Row: LFM2.5 MXFP4

- Model id: `lfm2.5-8b-a1b-mxfp4`.
- Model root: `/tmp/osaurus-e2e-lfm-one`.
- Final warm artifact:
  `/tmp/osaurus-lfm-finalapp-warm-2048-20260530-145426`.
- Harness:
  `scripts/live-proof/run-local-family-multiturn-tool-cache-proof.py`.
- Required evidence: `cache_topology`, `requires_disk_backed_restore`,
  `ssm_companion_cache`, `companion_cache`, and `disk_l2_hits`.
- Result: `passed: true`, `failed_checks: []`.

Behavior proven:

- Turn 1 required tool call finished as `tool_calls`.
- Turn 1 exact tool args: `{"text":"red\ngreen\nblue"}`.
- Turn 2 produced visible answer: `Three lines were counted.`
- Turn 2 had no tool call, no protocol leak, and no length-stop fake pass.
- Turn 3 required tool call after history finished as `tool_calls`.
- Turn 3 exact tool args: `{"text":"one\ntwo"}`.
- No visible content leaked on tool-call turns.
- App `/health` after the row was healthy with no in-flight request.
- Visible generation throughput was recorded: 118 completion tokens in
  1.598719583 seconds, about 73.81 tok/s.

Cache/topology proven:

- 24 total layers.
- 6 KV layers.
- 18 Mamba/SSM companion layers.
- `companion=ssm`.
- `requires_disk_backed_restore=true`.
- `requires_ssm_companion_state=true`.
- Paged cache incompatible for this hybrid row.
- `turbo_quant_kv_layer_count=0`.
- Warm row delta: `disk_l2_hits +1`, `ssm_companion_hits +1`,
  `companion_hits +1`, and `block_disk_stores +4`.

Boundary:

- The same LFM row can fail with too-small explicit max-token caps. A cold
  run using `--max-tokens 256` failed with `finish=length` before a tool call.
  The green row used explicit `--max-tokens 2048`; this is recorded as a
  request budget requirement, not hidden runtime behavior.
- This row proves LFM2.5 MXFP4. It does not prove LFM MXFP8 or LFM JANG_2L.

## Proven Live Row: Step 3.7 JANGTQ_K

- Model id: `step-3.7-flash-jangtq_k`.
- Model root: `/tmp/osaurus-step37-jangtqk-final-modelroot`.
- Final artifact:
  `/tmp/osaurus-step37-jangtqk-final-proof-20260530-154948`.
- Summary:
  `/tmp/osaurus-step37-jangtqk-final-proof-20260530-154948/step-3.7-flash-jangtq_k_summary.json`.
- Harness:
  `scripts/live-proof/run-local-family-multiturn-tool-cache-proof.py`.
- Required evidence: `cache_topology`, `requires_disk_backed_restore`, and
  `rotating_kv_layer_count`.
- Result: `passed: true`, `failed_checks: []`.

Behavior proven:

- Turn 1 required tool call finished as `tool_calls`.
- Turn 1 exact tool args: `{"text":"red\ngreen\nblue"}`.
- Turn 1 had `content=null`, no reasoning leak, and no visible protocol leak.
- Turn 2 produced visible answer: `The line count tool counted 3 lines.`
- Turn 2 had no tool call, no reasoning leak, no protocol leak, and no
  length-stop fake pass.
- Turn 3 required tool call after assistant/tool history finished as
  `tool_calls`.
- Turn 3 exact tool args: `{"text":"one\ntwo"}`.
- Turn 3 had no visible content leak and no protocol leak.
- App `/health` after the row was healthy, resident on
  `step-3.7-flash-jangtq_k`, and had no in-flight request.
- Token/s was recorded. This row is extremely slow on the current machine under
  the concurrent Step CRACK load: visible turn 2 produced 10 completion tokens
  in 326.031645042 seconds, about 0.0307 tok/s. Required tool-call turns emitted
  zero completion tokens by design.

Cache/topology proven:

- 45 total layers.
- 12 full KV layers.
- 33 rotating/sliding KV layers.
- `requires_disk_backed_restore=true`.
- Paged cache incompatible for this rotating hybrid row.
- `turbo_quant_kv_layer_count=0`.
- Cold row delta: `block_disk_misses +2`, `block_disk_stores +4`,
  `block_disk_hits +0`.

Boundary:

- This row proves Step JANGTQ_K required-tool parsing, reasoning separation,
  multi-turn tool-result history, no visible loop, no length-stop fake pass,
  and rotating/topology detection through the real no-sign Osaurus app.
- This row does not prove warm disk-L2 hit reuse for Step JANGTQ_K. The cache
  topology and disk-backed store path are proven, but `block_disk_hits` stayed
  `0`. Do not claim Step JANGTQ_K warm cache-hit readiness until a repeat row
  records `disk_l2_hits > 0` or `block_disk_hits > 0`.
- This historical row predated the current Step engine-selected policy update
  and therefore recorded `turbo_quant_kv_layer_count=0`. The current source
  policy now defaults Step's full-attention KV layers to TurboQuant while
  preserving rotating/SWA layers as native rotating cache. Treat this row as
  the Step JANGTQ_K tool/reasoning/topology proof, not as the final live
  TurboQuant-default proof.

## Current Step TurboQuant KV Policy Proof

- vMLX commit `0e5b8289bda477fa284d6c81f01e2c0a198021da` adds a focused source
  and topology test for the Step contract:
  `Step37ParserDispatchTests/stepTurboQuantKVContractCoversOnlyFullAttentionLayers`.
- That test proves the vMLX TurboQuant hook is constrained to `KVCacheSimple`
  full-attention layers and explicitly preserves `RotatingKVCache`,
  `DeepseekV4Cache`, `MambaCache`, and `CacheList` paths.
- Osaurus `ModelRuntime.shouldUseTurboQuantByDefault` now enables
  engine-selected TurboQuant only for Step topologies with KV layers and no
  Mamba/arrays/hybrid-pool/rotating-wrapper/ZAYA-CCA companion state. The guard
  still keeps DSV4, ZAYA/ZAYA-VL, Gemma, SSM/CCA/hybrid-pool families, and
  unknown path-dependent topologies native by default.
- Focused Osaurus tests now expect `turbo(3,3)` for known Step JANG_2L and
  Step JANGTQ_K topology tags, and source guards pin the Step exception text.
- Boundary: this is a source/topology and focused-test proof. A fresh no-sign
  app row from the final PR head should still be used before claiming measured
  live Step TurboQuant KV compression, token/s, and warm L2 hit behavior.

## Partial / Blocked Rows

Step JANG_2L:

- Earlier app attempts under current machine load did not produce a clean live
  Osaurus pass. The app entered generation and timed out before returning
  output. Sampling showed real generation work, not keychain/signing.
- A separate Step CRACK process was consuming about 82 GB RSS and high CPU/GPU
  during these attempts, so this row remains blocked/partial until rerun on a
  less contended machine.

Step JANGTQ_K:

- The earlier red row
  `/tmp/osaurus-step37-jangtqk-open-proof-20260530-151428` failed because the
  native Step template kept the required-tool contract inside hidden thinking.
- The final row above supersedes that red artifact for required-tool behavior.
- Warm disk-L2 hit reuse remains partial as described above.

Step JANGTQ2:

- No local Step JANGTQ2 bundle was found. Do not claim Step JANGTQ2 proof.

VL/media:

- No fresh real media row was run for this PR evidence. Do not claim VL proof
  from the Step/LFM rows.

## Source And Guard Verification

Focused Swift tests passed:

- `ModelRuntimeFindDirectoryTests/jangtq_formatStampWithSidecar_passes`
- `RuntimePolicySourceTests/vmlxPinIncludesRuntimeHardening`
- `SwiftTransformersTokenizerLoaderTests/step37LocalTokenizerUsesRequiredToolFallbackAndClosesThinkingRail`
- `MLXBatchAdapterTests/additionalContext_threadsRequiredToolChoiceToLocalTemplates`
- `MLXBatchAdapterTests/cacheKVModeTagTracksEffectiveCoordinatorPolicy`

Guard scripts passed:

- `scripts/live-proof/assert-tool-choice-required-routing.sh`
- `scripts/live-proof/assert-keychain-free-proof-path.sh`
- `scripts/live-proof/assert-server-settings-runtime-wiring.sh`
- `scripts/live-proof/assert-osaurus-no-forced-behavior-pr.sh`
- `scripts/live-proof/assert-osaurus-vmlx-pr-readiness.sh`
- `scripts/live-proof/assert-osaurus-pr-hygiene.sh`
- `scripts/live-proof/assert-chat-reasoning-delta-routing.sh`
- `scripts/live-proof/assert-chat-ui-reasoning-routing.sh`
- `scripts/live-proof/assert-http-channel-load-cancellation.sh`
- `scripts/live-proof/assert-model-tool-capability-surfaces.sh`

No fake-fix boundary:

- No hidden sampler defaults, forced repetition penalty, close-token bias,
  forced thinking/reasoning behavior, or broad parser repair was used for the
  live proof.
