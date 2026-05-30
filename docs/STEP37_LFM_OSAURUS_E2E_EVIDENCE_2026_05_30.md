# Step 3.7 / LFM Osaurus E2E Evidence - 2026-05-30

This document records the current no-sign Osaurus app proof for the Step/LFM
vMLX pin. It deliberately separates proven rows from partial rows.

## Code State

- vMLX pin: `72d97209b37f12646ff4d84d5900a4eec2b9d041`.
- vMLX fix: Step tool-call parser support for Step XML and narrow
  schema-gated bare `name({"arg": ...})` calls on reasoning/content rails.
- Osaurus fix: local JANGTQ sidecar preflight accepts bundles that declare
  `format: "jangtq"` with `jangtq_runtime.safetensors` even when
  `weight_format` is absent.
- Osaurus cache policy: engine-selected TurboQuant KV remains topology-gated.
  Full simple-KV models can use TurboQuant KV; Step hybrid rotating/sliding
  cache and LFM SSM/Mamba hybrid cache use native KV plus disk-backed restore
  and companion state.

## No-Sign / No-Keychain Boundary

- App build:
  `/tmp/osaurus-step37-pr/build/DerivedData-step37-nosign-7c9b14e0-72d9720-formatfix/Build/Products/Release/osaurus.app`.
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

## Partial / Blocked Rows

Step JANG_2L:

- Earlier app attempts under current machine load did not produce a clean live
  Osaurus pass. The app entered generation and timed out before returning
  output. Sampling showed real generation work, not keychain/signing.
- A separate Step CRACK process was consuming about 82 GB RSS and high CPU/GPU
  during these attempts, so this row remains blocked/partial until rerun on a
  less contended machine.

Step JANGTQ_K:

- The Osaurus preflight blocker for `format: "jangtq"` without
  `weight_format` is fixed and has focused test coverage.
- The final no-sign app served `/health`, but `/v1/models` and a direct chat
  request hung for the one-model Step JANGTQ_K root before runtime proof.
- Do not call Step JANGTQ_K live-proven from this PR evidence.

Step JANGTQ2:

- No local Step JANGTQ2 bundle was found. Do not claim Step JANGTQ2 proof.

VL/media:

- No fresh real media row was run for this PR evidence. Do not claim VL proof
  from the Step/LFM rows.

## Source And Guard Verification

Focused Swift tests passed:

- `ModelRuntimeFindDirectoryTests/jangtq_formatStampWithSidecar_passes`
- `RuntimePolicySourceTests/vmlxPinIncludesRuntimeHardening`
- `MLXBatchAdapterTests/cacheKVModeTagTracksEffectiveCoordinatorPolicy`

Guard scripts passed:

- `scripts/live-proof/assert-tool-choice-required-routing.sh`
- `scripts/live-proof/assert-keychain-free-proof-path.sh`
- `scripts/live-proof/assert-server-settings-runtime-wiring.sh`
- `scripts/live-proof/assert-osaurus-no-forced-behavior-pr.sh`
- `scripts/live-proof/assert-osaurus-vmlx-pr-readiness.sh`
- `scripts/live-proof/assert-osaurus-pr-hygiene.sh`

No fake-fix boundary:

- No hidden sampler defaults, forced repetition penalty, close-token bias,
  forced thinking/reasoning behavior, or broad parser repair was used for the
  live proof.
