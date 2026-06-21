#!/usr/bin/env python3
"""
Benchmark local LLM servers (e.g., Ollama, LM Studio) via OpenAI-compatible
Chat Completions API. Measures TTFT (time-to-first-token), total latency,
token/s when usage metadata is available, optional process RSS, and
throughput (chars/sec, bytes/sec) under configurable concurrency.

Examples:
  python3 scripts/benchmark_models.py \
    --server "ollama|http://localhost:11434|llama3.1" \
    --server "lmstudio|http://localhost:1234|Meta-Llama-3.1-8B-Instruct" \
    --prompt "Explain the significance of the Turing Test in AI." \
    --prompt "Write a Python function for Fibonacci with memoization." \
    --iterations 5 --concurrency 4 --max-tokens 512 \
    --output-prefix ./results/llm-bench --export json csv \
    --report-json ./results/llm-bench.benchmark.json \
    --report-markdown ./results/llm-bench.benchmark.md

Requires: httpx>=0.27.0
Install deps: pip install -r scripts/benchmark/requirements-bench.txt
"""

from __future__ import annotations

import argparse
import asyncio
import csv
import json
import math
import os
import subprocess
import sys
import time
from dataclasses import dataclass, asdict
from typing import Any, Dict, List, Optional, Tuple

try:
    import httpx  # type: ignore
except Exception:  # pragma: no cover
    httpx = None  # type: ignore


STATUS_PASS = "pass"
STATUS_PARTIAL = "partial"
STATUS_FAILED = "failed"
STATUS_UNPROVEN = "unproven"


@dataclass
class ServerSpec:
    name: str
    base_url: str
    model: str

    def endpoint(self) -> str:
        # Normalize to ensure we always hit /v1/chat/completions
        base = self.base_url.rstrip("/")
        if base.endswith("/v1"):
            return f"{base}/chat/completions"
        if base.endswith("/v1/"):
            return f"{base}chat/completions"
        return f"{base}/v1/chat/completions"


@dataclass
class RequestConfig:
    temperature: float = 0.2
    max_tokens: int = 512
    stream: bool = True
    timeout_seconds: float = 60.0
    extra_json: Dict[str, Any] = None  # for vendor-specific options
    system_prompt: Optional[str] = None


@dataclass
class MemoryProbe:
    server: str
    pid: int


@dataclass
class SingleResult:
    server: str
    model: str
    prompt_id: int
    case_id: str
    prompt: str
    iteration: int
    success: bool
    status_code: Optional[int]
    ttft_ms: Optional[float]
    total_ms: Optional[float]
    output_chars: int
    output_bytes: int
    prompt_tokens: Optional[int]
    completion_tokens: Optional[int]
    total_tokens: Optional[int]
    tokens_per_second: Optional[float]
    token_source: Optional[str]
    memory_rss_before_bytes: Optional[int]
    memory_rss_after_bytes: Optional[int]
    memory_rss_delta_bytes: Optional[int]
    memory_sample_source: Optional[str]
    status: str
    status_notes: List[str]
    error: Optional[str]


def parse_server_arg(arg: str) -> ServerSpec:
    try:
        name, base_url, model = arg.split("|", 2)
        return ServerSpec(name=name.strip(), base_url=base_url.strip(), model=model.strip())
    except ValueError as exc:
        raise argparse.ArgumentTypeError(
            "--server must be of the form 'name|base_url|model'"
        ) from exc


def parse_memory_pid_arg(arg: str) -> MemoryProbe:
    try:
        server, raw_pid = arg.split("|", 1)
        pid = int(raw_pid)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(
            "--memory-pid must be of the form 'server|pid'"
        ) from exc
    if pid <= 0:
        raise argparse.ArgumentTypeError("--memory-pid pid must be positive")
    return MemoryProbe(server=server.strip(), pid=pid)


def percentile(values: List[float], p: float) -> float:
    if not values:
        return float("nan")
    values_sorted = sorted(values)
    k = (len(values_sorted) - 1) * p
    f = int(k)
    c = min(f + 1, len(values_sorted) - 1)
    if f == c:
        return values_sorted[int(k)]
    d0 = values_sorted[f] * (c - k)
    d1 = values_sorted[c] * (k - f)
    return d0 + d1


def finite_or_none(value: Optional[float]) -> Optional[float]:
    if value is None:
        return None
    if not math.isfinite(value):
        return None
    return value


def round_float(value: Optional[float], digits: int = 3) -> Optional[float]:
    value = finite_or_none(value)
    return None if value is None else round(value, digits)


def case_id_for_prompt(prompt_id: int) -> str:
    return f"prompt-{prompt_id}"


def extract_usage_tokens(
    usage: Any,
) -> Tuple[Optional[int], Optional[int], Optional[int], Optional[float]]:
    if not isinstance(usage, dict):
        return None, None, None, None

    def int_value(key: str) -> Optional[int]:
        value = usage.get(key)
        if isinstance(value, bool):
            return None
        if isinstance(value, int):
            return value
        if isinstance(value, float) and value.is_integer():
            return int(value)
        return None

    prompt_tokens = int_value("prompt_tokens")
    completion_tokens = int_value("completion_tokens")
    total_tokens = int_value("total_tokens")
    raw_tps = usage.get("tokens_per_second")
    tokens_per_second = raw_tps if isinstance(raw_tps, (int, float)) else None
    return prompt_tokens, completion_tokens, total_tokens, finite_or_none(tokens_per_second)


def resolve_tokens_per_second(
    usage_tokens_per_second: Optional[float],
    completion_tokens: Optional[int],
    total_ms: Optional[float],
) -> Tuple[Optional[float], Optional[str]]:
    if usage_tokens_per_second is not None and usage_tokens_per_second > 0:
        return usage_tokens_per_second, "usage.tokens_per_second"
    if (
        completion_tokens is not None
        and completion_tokens > 0
        and total_ms is not None
        and total_ms > 0
    ):
        return completion_tokens / (total_ms / 1000.0), "usage.completion_tokens/total_ms"
    return None, None


def sample_process_rss_bytes(pid: int) -> Optional[int]:
    try:
        completed = subprocess.run(
            ["ps", "-o", "rss=", "-p", str(pid)],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except OSError:
        return None
    if completed.returncode != 0:
        return None
    raw = completed.stdout.strip().splitlines()
    if not raw:
        return None
    try:
        rss_kb = int(raw[-1].strip())
    except ValueError:
        return None
    return max(0, rss_kb) * 1024


def classify_result(
    success: bool,
    status_code: Optional[int],
    total_ms: Optional[float],
    tokens_per_second: Optional[float],
    error: Optional[str],
    memory_requested: bool,
    memory_before: Optional[int],
    memory_after: Optional[int],
) -> Tuple[str, List[str]]:
    notes: List[str] = []
    if not success:
        if status_code is None:
            notes.append("request did not return an HTTP status")
        else:
            notes.append(f"HTTP status {status_code}")
        if error:
            notes.append(error)
        return STATUS_FAILED, notes

    if total_ms is None or total_ms <= 0:
        notes.append("missing or invalid total latency")
        return STATUS_FAILED, notes

    if tokens_per_second is None or tokens_per_second <= 0:
        notes.append("no-metrics: missing positive token/s")
        return STATUS_UNPROVEN, notes

    if memory_requested and (memory_before is None or memory_after is None):
        notes.append("memory RSS sample unavailable")
        return STATUS_PARTIAL, notes

    return STATUS_PASS, notes


async def run_single_chat(
    client: httpx.AsyncClient,
    server: ServerSpec,
    prompt_id: int,
    iteration: int,
    prompt_text: str,
    cfg: RequestConfig,
    memory_pid: Optional[int] = None,
) -> SingleResult:
    url = server.endpoint()

    payload: Dict[str, Any] = {
        "model": server.model,
        "messages": ([{"role": "system", "content": cfg.system_prompt}] if cfg.system_prompt else []) + [
            {"role": "user", "content": prompt_text},
        ],
        "temperature": cfg.temperature,
        "max_tokens": cfg.max_tokens,
        "stream": bool(cfg.stream),
    }

    if cfg.stream:
        payload["stream_options"] = {"include_usage": True}

    if cfg.extra_json:
        payload.update(cfg.extra_json)

    headers = {
        "Content-Type": "application/json",
        # Prefer SSE for streaming; JSON otherwise
        "Accept": "text/event-stream" if cfg.stream else "application/json",
        # Most local servers do not require auth; support env var if provided
    }
    api_key = os.environ.get("OPENAI_API_KEY")
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    ttft_ms: Optional[float] = None
    total_ms: Optional[float] = None
    output_chars: int = 0
    output_bytes: int = 0
    status_code: Optional[int] = None
    prompt_tokens: Optional[int] = None
    completion_tokens: Optional[int] = None
    total_tokens: Optional[int] = None
    usage_tokens_per_second: Optional[float] = None
    tokens_per_second: Optional[float] = None
    token_source: Optional[str] = None
    memory_before: Optional[int] = (
        sample_process_rss_bytes(memory_pid) if memory_pid else None
    )
    memory_after: Optional[int] = None

    t0 = time.perf_counter()

    try:
        if cfg.stream:
            async with client.stream("POST", url, json=payload, headers=headers, timeout=cfg.timeout_seconds) as resp:
                status_code = resp.status_code
                # Iterate Server-Sent Events style lines
                first_token_emitted = False
                async for line in resp.aiter_lines():
                    if not line:
                        continue
                    if line.startswith("data: "):
                        data = line[6:].strip()
                    else:
                        # Some servers may not prefix with 'data: '
                        data = line.strip()

                    if data == "[DONE]":
                        break

                    try:
                        obj = json.loads(data)
                    except json.JSONDecodeError:
                        # Treat as raw content chunk
                        chunk_text = data
                    else:
                        usage = obj.get("usage") if isinstance(obj, dict) else None
                        pt, ct, tt, tps = extract_usage_tokens(usage)
                        prompt_tokens = pt if pt is not None else prompt_tokens
                        completion_tokens = ct if ct is not None else completion_tokens
                        total_tokens = tt if tt is not None else total_tokens
                        usage_tokens_per_second = tps if tps is not None else usage_tokens_per_second

                        # OpenAI-style delta path
                        choices = (obj.get("choices") or []) if isinstance(obj, dict) else []
                        if choices:
                            delta = choices[0].get("delta") or {}
                            chunk_text = delta.get("content", "") or ""
                        else:
                            # Fallback if vendor uses non-standard field
                            chunk_text = (obj.get("content", "") or "") if isinstance(obj, dict) else ""

                    if chunk_text:
                        if not first_token_emitted:
                            ttft_ms = (time.perf_counter() - t0) * 1000.0
                            first_token_emitted = True
                        output_chars += len(chunk_text)
                        output_bytes += len(chunk_text.encode("utf-8", errors="ignore"))

                total_ms = (time.perf_counter() - t0) * 1000.0
        else:
            resp = await client.post(url, json=payload, headers=headers, timeout=cfg.timeout_seconds)
            status_code = resp.status_code
            text = resp.text
            # Non-stream: TTFT ~ total
            total_ms = (time.perf_counter() - t0) * 1000.0
            ttft_ms = total_ms
            try:
                data = resp.json()
                if isinstance(data, dict):
                    pt, ct, tt, tps = extract_usage_tokens(data.get("usage"))
                    prompt_tokens = pt if pt is not None else prompt_tokens
                    completion_tokens = ct if ct is not None else completion_tokens
                    total_tokens = tt if tt is not None else total_tokens
                    usage_tokens_per_second = tps if tps is not None else usage_tokens_per_second

                    choices = data.get("choices") or []
                    if choices:
                        msg = choices[0].get("message") or {}
                        content = msg.get("content", "") or ""
                        output_chars = len(content)
                        output_bytes = len(content.encode("utf-8", errors="ignore"))
                    else:
                        text = json.dumps(data)
                        output_chars = len(text)
                        output_bytes = len(text.encode("utf-8", errors="ignore"))
                else:
                    output_chars = len(text)
                    output_bytes = len(text.encode("utf-8", errors="ignore"))
            except Exception:
                output_chars = len(text)
                output_bytes = len(text.encode("utf-8", errors="ignore"))

        memory_after = sample_process_rss_bytes(memory_pid) if memory_pid else None
        tokens_per_second, token_source = resolve_tokens_per_second(
            usage_tokens_per_second,
            completion_tokens,
            total_ms,
        )
        success = status_code is not None and 200 <= status_code < 300
        status, status_notes = classify_result(
            success=success,
            status_code=status_code,
            total_ms=total_ms,
            tokens_per_second=tokens_per_second,
            error=None,
            memory_requested=memory_pid is not None,
            memory_before=memory_before,
            memory_after=memory_after,
        )
        return SingleResult(
            server=server.name,
            model=server.model,
            prompt_id=prompt_id,
            case_id=case_id_for_prompt(prompt_id),
            prompt=prompt_text,
            iteration=iteration,
            success=success,
            status_code=status_code,
            ttft_ms=ttft_ms,
            total_ms=total_ms,
            output_chars=output_chars,
            output_bytes=output_bytes,
            prompt_tokens=prompt_tokens,
            completion_tokens=completion_tokens,
            total_tokens=total_tokens,
            tokens_per_second=tokens_per_second,
            token_source=token_source,
            memory_rss_before_bytes=memory_before,
            memory_rss_after_bytes=memory_after,
            memory_rss_delta_bytes=(
                memory_after - memory_before
                if memory_before is not None and memory_after is not None
                else None
            ),
            memory_sample_source=f"pid:{memory_pid}" if memory_pid else None,
            status=status,
            status_notes=status_notes,
            error=None,
        )
    except Exception as exc:  # pragma: no cover
        total_ms = (time.perf_counter() - t0) * 1000.0
        memory_after = sample_process_rss_bytes(memory_pid) if memory_pid else None
        status, status_notes = classify_result(
            success=False,
            status_code=status_code,
            total_ms=total_ms,
            tokens_per_second=None,
            error=str(exc),
            memory_requested=memory_pid is not None,
            memory_before=memory_before,
            memory_after=memory_after,
        )
        return SingleResult(
            server=server.name,
            model=server.model,
            prompt_id=prompt_id,
            case_id=case_id_for_prompt(prompt_id),
            prompt=prompt_text,
            iteration=iteration,
            success=False,
            status_code=status_code,
            ttft_ms=ttft_ms,
            total_ms=total_ms,
            output_chars=output_chars,
            output_bytes=output_bytes,
            prompt_tokens=prompt_tokens,
            completion_tokens=completion_tokens,
            total_tokens=total_tokens,
            tokens_per_second=None,
            token_source=None,
            memory_rss_before_bytes=memory_before,
            memory_rss_after_bytes=memory_after,
            memory_rss_delta_bytes=(
                memory_after - memory_before
                if memory_before is not None and memory_after is not None
                else None
            ),
            memory_sample_source=f"pid:{memory_pid}" if memory_pid else None,
            status=status,
            status_notes=status_notes,
            error=str(exc),
        )


async def run_benchmark(
    servers: List[ServerSpec],
    prompts: List[str],
    iterations: int,
    concurrency: int,
    cfg: RequestConfig,
    memory_pids: Optional[Dict[str, int]] = None,
) -> List[SingleResult]:
    if httpx is None:  # pragma: no cover
        raise RuntimeError(
            "This script requires the 'httpx' package. Install with:\n"
            "  pip install -r scripts/benchmark/requirements-bench.txt"
        )

    semaphore = asyncio.Semaphore(concurrency)
    memory_pids = memory_pids or {}

    async with httpx.AsyncClient(http2=False) as client:
        tasks: List[asyncio.Task[SingleResult]] = []

        async def bound_request(srv: ServerSpec, pidx: int, it: int, prompt: str) -> SingleResult:
            async with semaphore:
                return await run_single_chat(
                    client,
                    srv,
                    pidx,
                    it,
                    prompt,
                    cfg,
                    memory_pid=memory_pids.get(srv.name),
                )

        for srv in servers:
            for pidx, prompt in enumerate(prompts):
                for it in range(1, iterations + 1):
                    tasks.append(asyncio.create_task(bound_request(srv, pidx, it, prompt)))

        results: List[SingleResult] = []
        for coro in asyncio.as_completed(tasks):
            res = await coro
            results.append(res)

        return results


def aggregate(results: List[SingleResult]) -> Dict[Tuple[str, str], Dict[str, Any]]:
    groups: Dict[Tuple[str, str], List[SingleResult]] = {}
    for r in results:
        key = (r.server, r.model)
        groups.setdefault(key, []).append(r)

    summary: Dict[Tuple[str, str], Dict[str, Any]] = {}
    for key, items in groups.items():
        latencies = [i.total_ms for i in items if i.success and i.total_ms is not None]
        ttfts = [i.ttft_ms for i in items if i.success and i.ttft_ms is not None]
        token_rates = [i.tokens_per_second for i in items if i.tokens_per_second is not None]
        out_chars = [i.output_chars for i in items if i.success]
        out_bytes = [i.output_bytes for i in items if i.success]
        rss_after = [i.memory_rss_after_bytes for i in items if i.memory_rss_after_bytes is not None]
        status_counts = {
            STATUS_PASS: sum(1 for i in items if i.status == STATUS_PASS),
            STATUS_PARTIAL: sum(1 for i in items if i.status == STATUS_PARTIAL),
            STATUS_FAILED: sum(1 for i in items if i.status == STATUS_FAILED),
            STATUS_UNPROVEN: sum(1 for i in items if i.status == STATUS_UNPROVEN),
        }
        success_rate = sum(1 for i in items if i.success) / max(1, len(items))

        total_ms_avg = sum(latencies) / len(latencies) if latencies else float("nan")
        ttft_ms_avg = sum(ttfts) / len(ttfts) if ttfts else float("nan")
        token_rate_avg = sum(token_rates) / len(token_rates) if token_rates else float("nan")
        chars_avg = sum(out_chars) / len(out_chars) if out_chars else float("nan")
        bytes_avg = sum(out_bytes) / len(out_bytes) if out_bytes else float("nan")
        if not items:
            aggregate_status = STATUS_UNPROVEN
        elif status_counts[STATUS_PASS] == len(items):
            aggregate_status = STATUS_PASS
        elif status_counts[STATUS_FAILED] == len(items):
            aggregate_status = STATUS_FAILED
        elif status_counts[STATUS_UNPROVEN] == len(items):
            aggregate_status = STATUS_UNPROVEN
        else:
            aggregate_status = STATUS_PARTIAL

        summary[key] = {
            "runs": len(items),
            "status": aggregate_status,
            "status_counts": status_counts,
            "success_rate": success_rate,
            "ttft_ms_avg": ttft_ms_avg,
            "ttft_ms_p50": percentile(ttfts, 0.5) if ttfts else float("nan"),
            "ttft_ms_p95": percentile(ttfts, 0.95) if ttfts else float("nan"),
            "total_ms_avg": total_ms_avg,
            "total_ms_p50": percentile(latencies, 0.5) if latencies else float("nan"),
            "total_ms_p95": percentile(latencies, 0.95) if latencies else float("nan"),
            "tokens_per_second_avg": token_rate_avg,
            "tokens_per_second_p50": percentile(token_rates, 0.5) if token_rates else float("nan"),
            "tokens_per_second_p95": percentile(token_rates, 0.95) if token_rates else float("nan"),
            "output_chars_avg": chars_avg,
            "output_bytes_avg": bytes_avg,
            "memory_rss_after_bytes_max": max(rss_after) if rss_after else None,
            # Throughput estimates (average length divided by average latency)
            "chars_per_sec_avg": (chars_avg / (total_ms_avg / 1000.0)) if latencies else float("nan"),
            "bytes_per_sec_avg": (bytes_avg / (total_ms_avg / 1000.0)) if latencies else float("nan"),
        }

    return summary


def export_json(path_prefix: str, results: List[SingleResult], summary: Dict[Tuple[str, str], Dict[str, Any]]) -> str:
    results_path = f"{path_prefix}.results.json"
    summary_path = f"{path_prefix}.summary.json"

    with open(results_path, "w", encoding="utf-8") as f:
        json.dump([asdict(r) for r in results], f, ensure_ascii=False, indent=2)
    with open(summary_path, "w", encoding="utf-8") as f:
        # Convert tuple keys to strings
        friendly_summary = {f"{k[0]}|{k[1]}": v for k, v in summary.items()}
        json.dump(friendly_summary, f, ensure_ascii=False, indent=2)

    return summary_path


def export_csv(path_prefix: str, results: List[SingleResult]) -> str:
    csv_path = f"{path_prefix}.results.csv"
    fieldnames = list(asdict(results[0]).keys()) if results else [
        "server",
        "model",
        "prompt_id",
        "case_id",
        "prompt",
        "iteration",
        "success",
        "status_code",
        "ttft_ms",
        "total_ms",
        "output_chars",
        "output_bytes",
        "prompt_tokens",
        "completion_tokens",
        "total_tokens",
        "tokens_per_second",
        "token_source",
        "memory_rss_before_bytes",
        "memory_rss_after_bytes",
        "memory_rss_delta_bytes",
        "memory_sample_source",
        "status",
        "status_notes",
        "error",
    ]
    with open(csv_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for r in results:
            writer.writerow(asdict(r))
    return csv_path


def build_benchmark_report(
    results: List[SingleResult],
    summary: Dict[Tuple[str, str], Dict[str, Any]],
    servers: List[ServerSpec],
    prompts: List[str],
    cfg: RequestConfig,
    iterations: int,
    concurrency: int,
    generated_at: Optional[str] = None,
) -> Dict[str, Any]:
    rows = [report_row(r) for r in sorted_results(results)]
    return {
        "schema_version": 1,
        "generated_at": generated_at
        or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "covers_issues": [22],
        "config": {
            "concurrency": concurrency,
            "iterations": iterations,
            "max_tokens": cfg.max_tokens,
            "stream": cfg.stream,
            "temperature": cfg.temperature,
            "timeout_seconds": cfg.timeout_seconds,
            "system_prompt": cfg.system_prompt,
        },
        "servers": [
            {"name": s.name, "base_url": s.base_url, "model_id": s.model}
            for s in sorted(servers, key=lambda item: (item.name, item.model))
        ],
        "prompts": [
            {"case_id": case_id_for_prompt(i), "prompt_id": i, "prompt": prompt}
            for i, prompt in enumerate(prompts)
        ],
        "summary": report_summary_rows(summary),
        "rows": rows,
    }


def sorted_results(results: List[SingleResult]) -> List[SingleResult]:
    return sorted(results, key=lambda r: (r.server, r.model, r.prompt_id, r.iteration))


def report_row(result: SingleResult) -> Dict[str, Any]:
    return {
        "server": result.server,
        "model_id": result.model,
        "case": {
            "id": result.case_id,
            "prompt_id": result.prompt_id,
            "prompt": result.prompt,
        },
        "iteration": result.iteration,
        "status": result.status,
        "status_notes": result.status_notes,
        "http": {
            "success": result.success,
            "status_code": result.status_code,
            "error": result.error,
        },
        "timing": {
            "ttft_ms": round_float(result.ttft_ms),
            "total_ms": round_float(result.total_ms),
        },
        "tokens": {
            "prompt_tokens": result.prompt_tokens,
            "completion_tokens": result.completion_tokens,
            "total_tokens": result.total_tokens,
            "tokens_per_second": round_float(result.tokens_per_second),
            "source": result.token_source,
        },
        "output": {
            "chars": result.output_chars,
            "bytes": result.output_bytes,
        },
        "memory": {
            "available": result.memory_rss_after_bytes is not None,
            "rss_before_bytes": result.memory_rss_before_bytes,
            "rss_after_bytes": result.memory_rss_after_bytes,
            "rss_delta_bytes": result.memory_rss_delta_bytes,
            "source": result.memory_sample_source,
        },
    }


def report_summary_rows(summary: Dict[Tuple[str, str], Dict[str, Any]]) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    for (server, model), stats in sorted(summary.items(), key=lambda item: item[0]):
        rows.append(
            {
                "server": server,
                "model_id": model,
                "status": stats["status"],
                "runs": stats["runs"],
                "status_counts": stats["status_counts"],
                "success_rate": round_float(stats["success_rate"]),
                "ttft_ms_avg": round_float(stats["ttft_ms_avg"]),
                "ttft_ms_p50": round_float(stats["ttft_ms_p50"]),
                "ttft_ms_p95": round_float(stats["ttft_ms_p95"]),
                "total_ms_avg": round_float(stats["total_ms_avg"]),
                "total_ms_p50": round_float(stats["total_ms_p50"]),
                "total_ms_p95": round_float(stats["total_ms_p95"]),
                "tokens_per_second_avg": round_float(stats["tokens_per_second_avg"]),
                "tokens_per_second_p50": round_float(stats["tokens_per_second_p50"]),
                "tokens_per_second_p95": round_float(stats["tokens_per_second_p95"]),
                "memory_rss_after_bytes_max": stats["memory_rss_after_bytes_max"],
            }
        )
    return rows


def write_report_json(path: str, report: Dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=2, sort_keys=True, allow_nan=False)
        f.write("\n")


def write_report_markdown(path: str, report: Dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(format_benchmark_markdown(report))


def format_benchmark_markdown(report: Dict[str, Any]) -> str:
    lines: List[str] = []
    lines.append("# Model Benchmark Report")
    lines.append("")
    lines.append(f"- Generated: {md_escape(str(report.get('generated_at', 'unknown')))}")
    lines.append("- Covers: #22")
    lines.append("")
    lines.append("## Summary")
    lines.append("")
    lines.append(
        "| Server | Model | Status | Runs | Pass | Partial | Failed | Unproven | Avg latency | P50 token/s | P95 token/s | Max RSS |"
    )
    lines.append("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for row in report.get("summary", []):
        counts = row.get("status_counts", {})
        lines.append(
            "| "
            + " | ".join(
                [
                    md_escape(row.get("server", "")),
                    md_escape(row.get("model_id", "")),
                    md_escape(row.get("status", "")),
                    format_int(row.get("runs")),
                    format_int(counts.get(STATUS_PASS)),
                    format_int(counts.get(STATUS_PARTIAL)),
                    format_int(counts.get(STATUS_FAILED)),
                    format_int(counts.get(STATUS_UNPROVEN)),
                    format_ms(row.get("total_ms_avg")),
                    format_rate(row.get("tokens_per_second_p50")),
                    format_rate(row.get("tokens_per_second_p95")),
                    format_bytes(row.get("memory_rss_after_bytes_max")),
                ]
            )
            + " |"
        )

    lines.append("")
    lines.append("## Prompts")
    lines.append("")
    lines.append("| Case | Prompt |")
    lines.append("|---|---|")
    for prompt in report.get("prompts", []):
        lines.append(
            f"| {md_escape(prompt.get('case_id', ''))} | "
            f"{md_escape(truncate(str(prompt.get('prompt', '')), 180))} |"
        )

    lines.append("")
    lines.append("## Rows")
    lines.append("")
    lines.append(
        "| Status | Server | Model | Case | Iter | Total | TTFT | Token/s | Completion tokens | RSS after | Notes |"
    )
    lines.append("|---:|---|---|---|---:|---:|---:|---:|---:|---:|---|")
    for row in report.get("rows", []):
        timing = row.get("timing", {})
        tokens = row.get("tokens", {})
        memory = row.get("memory", {})
        case = row.get("case", {})
        notes = "; ".join(row.get("status_notes", []))
        lines.append(
            "| "
            + " | ".join(
                [
                    md_escape(row.get("status", "")),
                    md_escape(row.get("server", "")),
                    md_escape(row.get("model_id", "")),
                    md_escape(case.get("id", "")),
                    format_int(row.get("iteration")),
                    format_ms(timing.get("total_ms")),
                    format_ms(timing.get("ttft_ms")),
                    format_rate(tokens.get("tokens_per_second")),
                    format_int(tokens.get("completion_tokens")),
                    format_bytes(memory.get("rss_after_bytes")),
                    md_escape(notes if notes else "none"),
                ]
            )
            + " |"
        )

    return "\n".join(lines) + "\n"


def md_escape(value: Any) -> str:
    return str(value).replace("\n", " ").replace("|", "\\|")


def truncate(value: str, limit: int) -> str:
    return value if len(value) <= limit else value[: max(0, limit - 3)] + "..."


def format_int(value: Any) -> str:
    return "-" if value is None else str(value)


def format_ms(value: Any) -> str:
    value = finite_or_none(value if isinstance(value, (int, float)) else None)
    return "-" if value is None else f"{value:.1f} ms"


def format_rate(value: Any) -> str:
    value = finite_or_none(value if isinstance(value, (int, float)) else None)
    return "-" if value is None else f"{value:.2f}"


def format_bytes(value: Any) -> str:
    if value is None:
        return "-"
    try:
        raw = int(value)
    except (TypeError, ValueError):
        return "-"
    if raw < 1024:
        return f"{raw} B"
    mib = raw / (1024 * 1024)
    if mib < 1024:
        return f"{mib:.1f} MiB"
    return f"{mib / 1024:.2f} GiB"


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Benchmark OpenAI-compatible local LLM servers")
    parser.add_argument(
        "--server",
        action="append",
        type=parse_server_arg,
        required=True,
        help="Server spec 'name|base_url|model'. Example: ollama|http://localhost:11434|llama3.1",
    )
    parser.add_argument(
        "--prompt",
        action="append",
        default=[],
        help="Prompt text. Can be repeated. If omitted, uses built-in samples.",
    )
    parser.add_argument(
        "--system-prompt",
        default=None,
        help="System prompt text to prepend as a system message.",
    )
    parser.add_argument(
        "--prompts-file",
        default=None,
        help="Path to a text file with one prompt per line.",
    )
    parser.add_argument("--iterations", type=int, default=3, help="Iterations per prompt per server")
    parser.add_argument("--concurrency", type=int, default=2, help="Max concurrent requests")
    parser.add_argument("--temperature", type=float, default=0.2, help="Sampling temperature")
    parser.add_argument("--max-tokens", type=int, default=512, help="Max tokens for completion (server-enforced)")
    parser.add_argument("--timeout", type=float, default=60.0, help="Request timeout in seconds")
    parser.add_argument("--no-stream", action="store_true", help="Disable streaming; TTFT ~= total")
    parser.add_argument(
        "--warmup-iterations",
        type=int,
        default=0,
        help="Warm-up iterations per prompt per server (excluded from results)",
    )
    parser.add_argument(
        "--output-prefix",
        default="./llm-bench",
        help="Prefix path for outputs (without extension). Files: .results.json/.summary.json/.results.csv",
    )
    parser.add_argument(
        "--report-json",
        default=None,
        help="Write a deterministic benchmark evidence report JSON to this path.",
    )
    parser.add_argument(
        "--report-markdown",
        default=None,
        help="Write a deterministic benchmark evidence report Markdown file to this path.",
    )
    parser.add_argument(
        "--memory-pid",
        action="append",
        type=parse_memory_pid_arg,
        default=[],
        help="Sample RSS around each request for a server: 'server|pid'. Can be repeated.",
    )
    parser.add_argument(
        "--export",
        nargs="+",
        choices=["json", "csv"],
        default=["json", "csv"],
        help="Export formats",
    )
    parser.add_argument(
        "--extra-json",
        default=None,
        help="Extra JSON to include in requests (e.g., '{\"frequency_penalty\":0.0}')",
    )
    return parser.parse_args(argv)


def load_prompts(args: argparse.Namespace) -> List[str]:
    prompts: List[str] = []
    if args.prompts_file:
        with open(args.prompts_file, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    prompts.append(line)
    if args.prompt:
        prompts.extend(args.prompt)
    if not prompts:
        prompts = [
            "Explain the significance of the Turing Test in AI in 2-3 sentences.",
            "Write a Python function for Fibonacci using memoization.",
            "Summarize the benefits and drawbacks of static typing vs dynamic typing.",
        ]
    return prompts


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)
    servers: List[ServerSpec] = args.server
    prompts = load_prompts(args)

    if httpx is None:  # pragma: no cover
        print(
            "This script requires the 'httpx' package. Install with:\n"
            "  pip install -r scripts/benchmark/requirements-bench.txt",
            file=sys.stderr,
        )
        return 2

    memory_pids: Dict[str, int] = {probe.server: probe.pid for probe in args.memory_pid}

    if args.extra_json:
        try:
            extra_json = json.loads(args.extra_json)
            if not isinstance(extra_json, dict):
                raise ValueError("--extra-json must be a JSON object")
        except Exception as exc:
            print(f"Failed to parse --extra-json: {exc}", file=sys.stderr)
            return 2
    else:
        extra_json = None

    cfg = RequestConfig(
        temperature=args.temperature,
        max_tokens=args.max_tokens,
        stream=not args.no_stream,
        timeout_seconds=args.timeout,
        extra_json=extra_json,
        system_prompt=getattr(args, "system_prompt", None),
    )

    # Optional warm-up to avoid counting cold starts/connection setup
    if getattr(args, "warmup_iterations", 0) > 0:
        print(
            f"Running warm-up: {len(servers)} server(s), {len(prompts)} prompt(s), "
            f"{args.warmup_iterations} iteration(s) each, concurrency={args.concurrency} (excluded from results)..."
        )
        _ = asyncio.run(
            run_benchmark(
                servers,
                prompts,
                args.warmup_iterations,
                args.concurrency,
                cfg,
                memory_pids=memory_pids,
            )
        )

    sys_prompt_flag = "ON" if cfg.system_prompt else "OFF"
    print(f"Running benchmark against {len(servers)} server(s), {len(prompts)} prompt(s), {args.iterations} iteration(s) each, concurrency={args.concurrency}, system_prompt={sys_prompt_flag}...")

    results: List[SingleResult] = asyncio.run(
        run_benchmark(
            servers,
            prompts,
            args.iterations,
            args.concurrency,
            cfg,
            memory_pids=memory_pids,
        )
    )

    # Aggregate
    summary = aggregate(results)

    # Console summary
    print("\nSummary:")
    for (srv, model), stats in summary.items():
        print(f"- {srv} | {model}:")
        print(
            f"  status={stats['status']}  success_rate={stats['success_rate']*100:.1f}%  "
            f"ttft_avg={stats['ttft_ms_avg']:.1f}ms  ttft_p50={stats['ttft_ms_p50']:.1f}ms  ttft_p95={stats['ttft_ms_p95']:.1f}ms  "
            f"total_avg={stats['total_ms_avg']:.1f}ms  p50={stats['total_ms_p50']:.1f}ms  p95={stats['total_ms_p95']:.1f}ms  "
            f"tok/s_avg={stats['tokens_per_second_avg']:.1f}  "
            f"chars/s={stats['chars_per_sec_avg']:.1f}  bytes/s={stats['bytes_per_sec_avg']:.1f}"
        )

    # Exports
    os.makedirs(os.path.dirname(os.path.abspath(args.output_prefix)) or ".", exist_ok=True)
    if "json" in args.export:
        export_json(args.output_prefix, results, summary)
    if "csv" in args.export:
        export_csv(args.output_prefix, results)

    report = None
    if args.report_json or args.report_markdown:
        report = build_benchmark_report(
            results=results,
            summary=summary,
            servers=servers,
            prompts=prompts,
            cfg=cfg,
            iterations=args.iterations,
            concurrency=args.concurrency,
        )
    if args.report_json:
        write_report_json(args.report_json, report)
        print(f"Saved benchmark report JSON: {args.report_json}")
    if args.report_markdown:
        write_report_markdown(args.report_markdown, report)
        print(f"Saved benchmark report Markdown: {args.report_markdown}")

    print(f"\nSaved artifacts with prefix: {args.output_prefix}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
