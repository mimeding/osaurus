# Evidence Report Registry

The evidence report registry is the shared projection layer for report
artifacts produced by eval, benchmark, runtime, live-proof, run-trace, and
provider validation flows. It does not create a new report destination or move
artifact files; callers register local artifact descriptors and receive typed
summaries that can be listed, filtered, serialized, and rendered by future
surfaces.

## Model

`EvidenceReportDescriptor` is the input from a local producer:

- `kind`: one of `eval`, `benchmark`, `runtime`, `live_proof`, `run_trace`,
  `provider`, or `custom`.
- `source`: the producing flow, such as `evals-pr-evidence` or
  `provider-connectivity`.
- `artifactPath`: the local artifact path. Relative paths can be resolved
  against a caller-provided base URL.
- `status` and `counts`: summary outcome fields from the producer.
- `startedAt`, `completedAt`, and registration time.
- `metadata`: string metadata, redacted at registration before storage.

`EvidenceReportSummary` is the canonical output. Missing artifact paths are
kept as explicit rows with `status = unavailable` and
`artifact.availability = unavailable`. Descriptors that already know they
failed to parse or validate can pass `artifactError`, which produces an
explicit `error` row.

## Behavior

`EvidenceReportRegistryService` stores summaries in memory, dedupes repeated
descriptors by explicit `id` or by `(kind, source, artifactPath)`, and supports
filters for kind, source, status, and artifact availability. Stable JSON output
uses the package canonical encoder with sorted keys and ISO-8601 dates.

Metadata is redacted before it reaches the registry. Sensitive keys such as API
keys, authorization headers, passwords, private keys, credentials, and token
fields are replaced with `<redacted>`. Values that look like common bearer,
OpenAI, GitHub, or Slack-style secrets are also replaced.

## Provider and Runtime Producers

Provider and runtime evidence should enter new surfaces through the registry,
not through a separate report store or dashboard. The narrow adapter for the
existing evidence shapes is `ProviderRuntimeEvidenceDescriptorProducer`:

- `providerDiagnosticsDescriptor(from:artifactPath:)` accepts the existing
  `ProviderDiagnosticReport` used by remote-provider and MCP diagnostics. It
  maps row severities into registry counts: `ok` rows are passed, `warning`
  rows are warnings, and `blocked` rows are blocked.
- `runtimeProofDescriptor(from:artifactPath:)` accepts an existing
  `RuntimeProofClassificationReport` from the live-proof classifier. It uses
  `RuntimeProofMatrixReporter.matrixRows(from:)` so schema-only required rows
  that have no live artifact remain visible as unproven/blocked registry rows.

Both adapters are read-only projections over existing artifacts. They register
the artifact path supplied by the producer, preserve missing artifacts as
`unavailable` rows through `EvidenceReportRegistryService`, and rely on the
registry metadata redactor before summaries are stored or serialized.

Migration path for provider/runtime evidence:

1. Keep producing the existing diagnostic or runtime classification artifact.
2. Convert the typed report to an `EvidenceReportDescriptor` with the adapter.
3. Register the descriptor with the shared `EvidenceReportRegistryService`.
4. Render or export the registry snapshot for any future evidence view.

This keeps provider connectivity, runtime proof, and benchmark/runtime artifacts
on the same descriptor/summary contract while leaving artifact ownership with
their existing producers.
