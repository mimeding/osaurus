# Benchmark Reports

`scripts/benchmark/benchmark_models.py` benchmarks OpenAI-compatible local
servers such as Osaurus, Ollama, and LM Studio. In addition to the raw JSON/CSV
artifacts, it can write deterministic evidence reports for issue #22:

```bash
python3 scripts/benchmark/benchmark_models.py \
  --server "osaurus|http://127.0.0.1:1337|qwen3-coder" \
  --server "ollama|http://127.0.0.1:11434|qwen3-coder" \
  --prompt "Write a short function that parses ISO-8601 timestamps." \
  --iterations 3 \
  --concurrency 1 \
  --max-tokens 512 \
  --report-json results/current-models.benchmark.json \
  --report-markdown results/current-models.benchmark.md
```

The wrapper emits reports by default:

```bash
scripts/benchmark/run_bench.sh
```

Override `REPORT_JSON` and `REPORT_MD` to choose paths. Set `OSA_MODEL`,
`OLLAMA_MODEL`, and `LMSTUDIO_MODEL` to compare current model families.

## Evidence Fields

Each JSON row records:

- `server` and `model_id`
- `case.id`, `case.prompt_id`, and the exact `case.prompt`
- HTTP success/status/error
- `timing.ttft_ms` and `timing.total_ms`
- token counts and `tokens.tokens_per_second`
- output size in chars/bytes
- memory RSS fields when `--memory-pid server|pid` is supplied
- `status` and `status_notes`

Report status values are `pass`, `partial`, `failed`, and `unproven`.
A successful generation row without positive token/s is `failed`; token/s is
never silently omitted. Memory evidence is optional, but if a PID is supplied
and RSS cannot be sampled, the row is `partial`.

## Memory Sampling

RSS sampling is process based and works for any local server when you know its
PID:

```bash
python3 scripts/benchmark/benchmark_models.py \
  --server "osaurus|http://127.0.0.1:1337|qwen3-coder" \
  --memory-pid "osaurus|12345" \
  --report-json results/osaurus.benchmark.json \
  --report-markdown results/osaurus.benchmark.md
```

The sample is taken before and after each request. It is evidence, not a peak
profiler; use Activity Monitor or a dedicated sampler when validating hard RAM
ceilings.
