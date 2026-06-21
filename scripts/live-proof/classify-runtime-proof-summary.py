#!/usr/bin/env python3
"""Classify live runtime proof summaries against Osaurus proof rules.

The family runtime matrix already records model responses, token rates, cache
telemetry, and failed checks. This script converts those artifacts into the
project proof vocabulary: proven, partial, failed, or unproven. It is designed
to run after ``run-family-runtime-chat-matrix.sh`` and to keep live runtime
issue closure honest when a row lacks token/s, topology-specific cache proof,
media-path proof, or other required evidence.
"""

from __future__ import annotations

import argparse
import json
import pathlib
from collections import Counter
from datetime import datetime, timezone
from typing import Any


PROTOCOL_MARKERS = (
    "<|tool",
    "</|",
    "<tool_call",
    "</tool_call",
    "<think>",
    "</think>",
    "DSML",
    "xml_function",
    "\ufffetool:",
    "\ufffeargs:",
    "\ufffereasoning:",
)

REQUIRED_PRIORITIES = {"required", "required-local"}

RESILIENCE_SIGNALS = (
    "tokens_per_second",
    "cache",
    "marker_leak",
    "cancellation",
    "crash_proof",
)

CANCELLATION_CHECKS = (
    "cancellation_cleaned_up",
    "cancelled_load_unloaded",
    "cancelled_generation_finished",
    "no_zombie_load",
    "stop_status_cancelled",
)

CANCELLATION_CLEANUP_CHECKS = (
    "cancellation_cleaned_up",
    "cancelled_load_unloaded",
    "cancelled_generation_finished",
    "no_zombie_load",
)

CANCELLATION_OBSERVATION_CHECKS = (
    "stop_status_cancelled",
)


def load_json(path: pathlib.Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def save_json(path: pathlib.Path, value: Any) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def manifest_by_id(manifest_path: pathlib.Path) -> dict[str, dict[str, Any]]:
    rows = load_json(manifest_path)
    if not isinstance(rows, list):
        raise ValueError(f"manifest must be a list: {manifest_path}")
    out: dict[str, dict[str, Any]] = {}
    for row in rows:
        if isinstance(row, dict) and row.get("id"):
            out[str(row["id"])] = row
    return out


def first_summary_payload(row: dict[str, Any]) -> tuple[dict[str, Any] | None, str | None]:
    for raw_path in row.get("summary_files") or []:
        path = pathlib.Path(str(raw_path))
        if not path.exists():
            continue
        try:
            payload = load_json(path)
        except Exception as exc:  # noqa: BLE001 - artifact parser should preserve error text
            return None, f"summary parse error for {path}: {exc!r}"
        if isinstance(payload, dict):
            return payload, str(path)
    return None, None


def existing_artifacts(payload_path: str | None, patterns: tuple[str, ...]) -> list[str]:
    if not payload_path:
        return []
    root = pathlib.Path(payload_path).parent
    paths: list[str] = []
    for pattern in patterns:
        paths.extend(str(path) for path in sorted(root.glob(pattern)) if path.exists())
    return list(dict.fromkeys(paths))


def explicit_artifact_paths(value: Any) -> list[str]:
    if isinstance(value, str):
        return [value] if value else []
    if isinstance(value, list):
        return [str(item) for item in value if item]
    if isinstance(value, dict):
        out: list[str] = []
        for key in ("artifact_path", "artifact_paths", "path", "paths", "summary_path"):
            out.extend(explicit_artifact_paths(value.get(key)))
        return out
    return []


def row_requirements(manifest_row: dict[str, Any]) -> list[str]:
    requirements = [
        "visible_output",
        "tokens_per_second",
        "no_parser_marker_leak",
        "multi_turn_coherency",
    ]
    if manifest_row.get("required_cache_evidence"):
        requirements.append("cache_hit")
    topology = str(manifest_row.get("topology", "")).lower()
    model = str(manifest_row.get("model", "")).lower()
    row_id = str(manifest_row.get("id", "")).lower()
    if "vl" in topology or "-vl" in model or "-vl" in row_id or row_id.endswith("-vl"):
        requirements.append("media_payload")
    if manifest_row.get("required_cancellation_evidence"):
        requirements.append("cancellation")
    return requirements


def positive_token_rates(payload: dict[str, Any]) -> dict[str, dict[str, Any]]:
    token_rates = payload.get("token_rates")
    if not isinstance(token_rates, dict):
        return {}
    out: dict[str, dict[str, Any]] = {}
    for turn, value in token_rates.items():
        if not isinstance(value, dict):
            continue
        tokens = value.get("completion_tokens")
        rate = value.get("tokens_per_second")
        if isinstance(tokens, int) and tokens > 0 and isinstance(rate, (int, float)) and rate > 0:
            out[str(turn)] = value
    return out


def has_token_rate(payload: dict[str, Any]) -> bool:
    return bool(positive_token_rates(payload))


def numeric_metrics(prefix: str, value: Any) -> dict[str, float]:
    metrics: dict[str, float] = {}
    if isinstance(value, dict):
        for key, nested in value.items():
            metrics.update(numeric_metrics(f"{prefix}_{key}" if prefix else str(key), nested))
    elif isinstance(value, (int, float)) and not isinstance(value, bool):
        metrics[prefix] = float(value)
    return metrics


def blockers_for_requirement(blockers: list[dict[str, str]], requirement: str) -> list[str]:
    return [
        str(blocker.get("message", ""))
        for blocker in blockers
        if blocker.get("requirement") == requirement and blocker.get("message")
    ]


def signal_record(
    verdict: str,
    summary: str,
    evidence_paths: list[str],
    metrics: dict[str, float] | None = None,
) -> dict[str, Any]:
    return {
        "verdict": verdict,
        "summary": summary,
        "evidence_paths": list(dict.fromkeys(path for path in evidence_paths if path)),
        "metrics": metrics or {},
    }


def parser_leaks(payload: dict[str, Any]) -> list[str]:
    text = json.dumps(payload, ensure_ascii=False)
    return sorted(marker for marker in PROTOCOL_MARKERS if marker.lower() in text.lower())


def checks(payload: dict[str, Any]) -> dict[str, bool]:
    raw = payload.get("checks")
    if not isinstance(raw, dict):
        return {}
    return {str(key): bool(value) for key, value in raw.items()}


def failed_checks(payload: dict[str, Any]) -> list[str]:
    raw = payload.get("failed_checks")
    if not isinstance(raw, list):
        return []
    return [str(value) for value in raw]


def visible_output_present(payload: dict[str, Any]) -> bool:
    turns = payload.get("turns")
    if isinstance(turns, dict):
        text = turns.get("turn2_content")
        if isinstance(text, str) and text.strip():
            return True
    for key in ("first", "repeat"):
        value = payload.get(key)
        if isinstance(value, dict):
            text = value.get("text") or value.get("answer")
            if isinstance(text, str) and text.strip():
                return True
    return False


def multi_turn_coherent(payload: dict[str, Any]) -> bool:
    row_checks = checks(payload)
    required = [
        "history_valid_after_turn1",
        "turn2_no_tool_calls",
        "turn2_visible_mentions_3",
        "turn2_not_length_stop",
        "turn3_finish_tool_calls",
        "turn3_has_one_tool_call",
        "turn3_name_line_count",
        "turn3_args_exact",
    ]
    return all(row_checks.get(name) is True for name in required)


def cache_hit_proven(payload: dict[str, Any], manifest_row: dict[str, Any]) -> bool:
    required = manifest_row.get("required_cache_evidence") or []
    if not required:
        return True
    row_checks = checks(payload)
    failures = set(failed_checks(payload))
    for name in required:
        check_name = f"cache_evidence_{name}"
        if check_name in failures or row_checks.get(check_name) is not True:
            return False
    return True


def media_payload_proven(payload: dict[str, Any]) -> bool:
    row_checks = checks(payload)
    media_checks = [
        "first_mentions_red",
        "repeat_mentions_red",
        "stable_prefix_hash",
        "repeat_disk_l2_hit",
    ]
    has_real_payload = bool(payload.get("image") or payload.get("media") or payload.get("payload"))
    if has_real_payload and all(row_checks.get(name) is True for name in media_checks):
        return True
    return False


def cancellation_cleanup_failures(payload: dict[str, Any]) -> list[str]:
    row_checks = checks(payload)
    return [name for name in CANCELLATION_CLEANUP_CHECKS if row_checks.get(name) is False]


def cancellation_cleanup_passes(payload: dict[str, Any]) -> list[str]:
    row_checks = checks(payload)
    return [name for name in CANCELLATION_CLEANUP_CHECKS if row_checks.get(name) is True]


def cancellation_requirement_blocker(payload: dict[str, Any]) -> str | None:
    failures = cancellation_cleanup_failures(payload)
    if failures:
        return "row cancellation cleanup checks failed: " + ", ".join(failures)
    if cancellation_cleanup_passes(payload):
        return None
    row_checks = checks(payload)
    observed = [name for name in CANCELLATION_OBSERVATION_CHECKS if row_checks.get(name) is True]
    if observed:
        return "cancellation was observed but cleanup proof is missing: " + ", ".join(observed)
    explicit = payload.get("cancellation_evidence") or payload.get("cancellation")
    if explicit or any(name in row_checks for name in CANCELLATION_CHECKS):
        return "row cancellation cleanup evidence is incomplete"
    return "row lacks required cancellation cleanup evidence"


def token_rate_signal(
    payload: dict[str, Any],
    payload_path: str | None,
    blockers: list[dict[str, str]],
    row_failed: bool,
) -> dict[str, Any]:
    rates = positive_token_rates(payload)
    if rates:
        best_turn, best = max(
            rates.items(),
            key=lambda item: float(item[1].get("tokens_per_second", 0)),
        )
        rate = float(best.get("tokens_per_second", 0))
        tokens = int(best.get("completion_tokens", 0))
        return signal_record(
            "proven",
            f"{best_turn}: {rate:.2f} token/s over {tokens} completion tokens",
            [payload_path] if payload_path else [],
            numeric_metrics("token_rates", rates),
        )
    messages = blockers_for_requirement(blockers, "tokens_per_second")
    return signal_record(
        "failed" if row_failed else "partial",
        messages[0] if messages else "no positive token/s was recorded",
        [payload_path] if payload_path else [],
    )


def cache_signal(
    payload: dict[str, Any],
    manifest_row: dict[str, Any],
    payload_path: str | None,
    blockers: list[dict[str, str]],
    row_failed: bool,
) -> dict[str, Any]:
    required = bool(manifest_row.get("required_cache_evidence"))
    cache_delta = payload.get("cache_delta")
    cache_paths = existing_artifacts(payload_path, ("*cache_before.json", "*cache_after.json"))
    if payload_path:
        cache_paths.insert(0, payload_path)
    if required and cache_hit_proven(payload, manifest_row):
        return signal_record(
            "proven",
            "topology-specific cache evidence passed",
            cache_paths,
            numeric_metrics("cache_delta", cache_delta),
        )
    if required:
        messages = blockers_for_requirement(blockers, "cache_hit")
        return signal_record(
            "failed" if row_failed else "partial",
            messages[0] if messages else "required topology-specific cache evidence is incomplete",
            cache_paths,
            numeric_metrics("cache_delta", cache_delta),
        )
    if isinstance(cache_delta, dict) and cache_delta:
        return signal_record(
            "partial",
            "cache counters were recorded, but this row does not require cache-hit proof",
            cache_paths,
            numeric_metrics("cache_delta", cache_delta),
        )
    return signal_record("unproven", "no cache evidence was recorded for this row", cache_paths)


def marker_leak_signal(
    payload: dict[str, Any],
    payload_path: str | None,
    blockers: list[dict[str, str]],
    row_failed: bool,
) -> dict[str, Any]:
    leak_paths = existing_artifacts(payload_path, ("*.response.json",))
    if payload_path:
        leak_paths.insert(0, payload_path)
    leaks = parser_leaks(payload)
    if leaks:
        return signal_record(
            "failed",
            "parser/runtime markers present: " + ", ".join(leaks),
            leak_paths,
        )
    messages = blockers_for_requirement(blockers, "no_parser_marker_leak")
    if messages:
        return signal_record("failed" if row_failed else "partial", messages[0], leak_paths)
    return signal_record("proven", "no parser/runtime marker leak detected in recorded output", leak_paths)


def cancellation_signal(
    payload: dict[str, Any],
    manifest_row: dict[str, Any],
    payload_path: str | None,
    blockers: list[dict[str, str]],
    row_failed: bool,
) -> dict[str, Any]:
    row_checks = checks(payload)
    required = bool(manifest_row.get("required_cancellation_evidence"))
    explicit = payload.get("cancellation_evidence") or payload.get("cancellation")
    paths = existing_artifacts(
        payload_path,
        ("*health_before.json", "*health_after.json", "process-*.txt", "vm-*.txt"),
    )
    paths.extend(explicit_artifact_paths(explicit))
    if payload_path:
        paths.insert(0, payload_path)
    present = required or bool(explicit) or any(name in row_checks for name in CANCELLATION_CHECKS)
    if not present:
        return signal_record("unproven", "no cancellation cleanup proof was recorded for this row", paths)
    failures = cancellation_cleanup_failures(payload)
    if failures:
        return signal_record(
            "failed" if row_failed else "partial",
            "cancellation cleanup checks failed: " + ", ".join(failures),
            paths,
        )
    passed = cancellation_cleanup_passes(payload)
    if passed:
        return signal_record(
            "proven",
            "cancellation cleanup checks passed: " + ", ".join(passed),
            paths,
        )
    observed = [name for name in CANCELLATION_OBSERVATION_CHECKS if row_checks.get(name) is True]
    if observed:
        return signal_record(
            "failed" if row_failed else "partial",
            "cancellation was observed but cleanup proof is missing: " + ", ".join(observed),
            paths,
        )
    messages = blockers_for_requirement(blockers, "cancellation")
    return signal_record(
        "failed" if row_failed else "partial",
        messages[0] if messages else "cancellation evidence is present but incomplete",
        paths,
    )


def crash_proof_signal(
    payload: dict[str, Any],
    payload_path: str | None,
    row_failed: bool,
) -> dict[str, Any]:
    row_checks = checks(payload)
    paths = existing_artifacts(
        payload_path,
        (
            "*health_after.json",
            "*health_before.json",
            "process-*.txt",
            "vm-*.txt",
            "*error.json",
            "*crash*.json",
            "*crash*.log",
            "*crash*.txt",
        ),
    )
    paths.extend(explicit_artifact_paths(payload.get("crash_evidence") or payload.get("crash_proof")))
    if payload_path:
        paths.insert(0, payload_path)
    error = payload.get("error")
    if isinstance(error, dict):
        message = str(error.get("message") or error.get("type") or "runtime error recorded")
        return signal_record("failed", "runtime error artifact recorded: " + message, paths)
    if row_checks.get("server_healthy_after") is True and row_checks.get("no_inflight_after") is True:
        return signal_record(
            "proven",
            "server stayed healthy with no in-flight work after the row",
            paths,
        )
    if row_checks.get("server_healthy_after") is False or row_failed:
        return signal_record("failed", "row failed or server health did not survive the proof run", paths)
    if paths:
        return signal_record("partial", "crash/health artifacts exist but do not prove post-run health", paths)
    return signal_record("unproven", "no crash/health evidence was recorded for this row", paths)


def resilience_evidence(
    payload: dict[str, Any],
    manifest_row: dict[str, Any],
    payload_path: str | None,
    blockers: list[dict[str, str]],
    row_failed: bool,
) -> dict[str, Any]:
    return {
        "tokens_per_second": token_rate_signal(payload, payload_path, blockers, row_failed),
        "cache": cache_signal(payload, manifest_row, payload_path, blockers, row_failed),
        "marker_leak": marker_leak_signal(payload, payload_path, blockers, row_failed),
        "cancellation": cancellation_signal(payload, manifest_row, payload_path, blockers, row_failed),
        "crash_proof": crash_proof_signal(payload, payload_path, row_failed),
    }


def requirement_blockers(payload: dict[str, Any], manifest_row: dict[str, Any]) -> list[dict[str, str]]:
    blockers: list[dict[str, str]] = []
    requirements = row_requirements(manifest_row)

    if "visible_output" in requirements and not visible_output_present(payload):
        blockers.append(
            {
                "requirement": "visible_output",
                "message": "row lacks non-empty visible assistant output",
            }
        )
    if "tokens_per_second" in requirements and not has_token_rate(payload):
        blockers.append(
            {
                "requirement": "tokens_per_second",
                "message": "row lacks token/s for a generation turn",
            }
        )
    if "no_parser_marker_leak" in requirements:
        leaks = parser_leaks(payload)
        if leaks:
            blockers.append(
                {
                    "requirement": "no_parser_marker_leak",
                    "message": "row contains parser marker leaks: " + ", ".join(leaks),
                }
            )
    if "multi_turn_coherency" in requirements and not multi_turn_coherent(payload):
        blockers.append(
            {
                "requirement": "multi_turn_coherency",
                "message": "row lacks complete multi-turn tool/follow-up coherence",
            }
        )
    if "cache_hit" in requirements and not cache_hit_proven(payload, manifest_row):
        blockers.append(
            {
                "requirement": "cache_hit",
                "message": "row lacks required topology-specific cache evidence",
            }
        )
    if "media_payload" in requirements and not media_payload_proven(payload):
        blockers.append(
            {
                "requirement": "media_payload",
                "message": "VL/media row lacks real media payload, media routing, or media cache-hit proof",
            }
        )
    if "cancellation" in requirements:
        message = cancellation_requirement_blocker(payload)
        if message:
            blockers.append(
                {
                    "requirement": "cancellation",
                    "message": message,
                }
            )
    return blockers


def classify_row(row: dict[str, Any], manifest_rows: dict[str, dict[str, Any]]) -> dict[str, Any]:
    row_id = str(row.get("id", ""))
    manifest_row = manifest_rows.get(row_id, {"id": row_id})
    payload, payload_path = first_summary_payload(row)
    artifact_paths = [str(path) for path in row.get("summary_files") or []]

    result: dict[str, Any] = {
        "id": row_id,
        "model": manifest_row.get("model") or row.get("model"),
        "family": manifest_row.get("family"),
        "priority": manifest_row.get("priority"),
        "requirements": row_requirements(manifest_row),
        "artifact_paths": artifact_paths,
        "summary_path": payload_path,
    }

    if payload is None:
        result.update(
            {
                "verdict": "unproven",
                "acceptable_for_proven_claim": False,
                "blockers": [
                    {
                        "requirement": "artifact",
                        "message": "row has no readable summary payload",
                    }
                ],
                "warnings": [],
                "resilience_evidence": {
                    signal: signal_record(
                        "unproven",
                        "row has no readable summary payload",
                        artifact_paths,
                    )
                    for signal in RESILIENCE_SIGNALS
                },
            }
        )
        return result

    blockers = requirement_blockers(payload, manifest_row)
    failed = failed_checks(payload)
    passed = payload.get("passed") is True and row.get("passed") is True

    if passed and not blockers:
        verdict = "proven"
    elif payload.get("passed") is False or str(row.get("status", "")).startswith("FAIL"):
        verdict = "failed"
    else:
        verdict = "partial"

    if passed and blockers:
        verdict = "partial"

    result.update(
        {
            "verdict": verdict,
            "acceptable_for_proven_claim": verdict == "proven",
            "blockers": blockers,
            "warnings": []
            if artifact_paths
            else [
                {
                    "requirement": "artifact",
                    "message": "row should keep at least one artifact path",
                }
            ],
            "failed_checks": failed,
            "cache_delta": payload.get("cache_delta", {}),
            "token_rates": payload.get("token_rates", {}),
            "resilience_evidence": resilience_evidence(
                payload,
                manifest_row,
                payload_path,
                blockers,
                row_failed=verdict == "failed",
            ),
        }
    )
    return result


def verdict_counts(rows: list[dict[str, Any]]) -> dict[str, int]:
    counts = Counter(str(row.get("verdict", "unproven")) for row in rows)
    return {key: counts.get(key, 0) for key in ("proven", "partial", "failed", "unproven")}


def required_rows(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [row for row in rows if str(row.get("priority")) in REQUIRED_PRIORITIES]


def issue_coverage(rows: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    required = required_rows(rows)
    required_not_proven = [
        row["id"] for row in required if row.get("verdict") != "proven"
    ]
    hy3_rows = [row for row in rows if str(row.get("family")) == "hy3"]
    media_rows = [
        row for row in rows if "media_payload" in row.get("requirements", [])
    ]
    crash_rows = [
        row["id"]
        for row in rows
        if row.get("resilience_evidence", {})
        .get("crash_proof", {})
        .get("verdict")
        in {"proven", "partial", "failed"}
    ]
    cancellation_rows = [
        row["id"]
        for row in rows
        if row.get("resilience_evidence", {})
        .get("cancellation", {})
        .get("verdict")
        in {"proven", "partial", "failed"}
    ]

    runtime_matrix_verdict = "proven" if not required_not_proven and required else "partial"
    if not required:
        runtime_matrix_verdict = "unproven"

    return {
        "#1161": {
            "verdict": runtime_matrix_verdict,
            "note": "local-model corruption closure requires all required family rows to be proven",
            "required_rows_not_proven": required_not_proven,
        },
        "#1162": {
            "verdict": runtime_matrix_verdict,
            "note": "systematic runtime verification tracks the full required matrix",
            "required_rows_not_proven": required_not_proven,
        },
        "#1163": {
            "verdict": "proven"
            if any(row.get("verdict") == "proven" for row in hy3_rows)
            else "unproven",
            "note": "Hy3/harmony parser closure needs a local Hy3 row, not sibling inference",
            "rows": [row["id"] for row in hy3_rows],
        },
        "#903": {
            "verdict": "unproven",
            "note": "this tool/cache matrix does not claim system-prompt injection proof",
        },
        "#1228": {
            "verdict": "partial" if crash_rows or cancellation_rows else "unproven",
            "note": "crash closure needs reporter-aligned crash and cancellation artifacts; dashboard rows only surface existing evidence",
            "rows": sorted(set(crash_rows + cancellation_rows)),
        },
        "#1183": {
            "verdict": "proven"
            if media_rows and all(row.get("verdict") == "proven" for row in media_rows)
            else "unproven",
            "note": "native media closure needs real media-path rows with cache-salt and cache-hit proof",
            "rows": [row["id"] for row in media_rows],
        },
    }


def classify(summary_path: pathlib.Path, manifest_path: pathlib.Path) -> dict[str, Any]:
    summary = load_json(summary_path)
    if not isinstance(summary, dict):
        raise ValueError(f"summary must be an object: {summary_path}")
    manifest_rows = manifest_by_id(manifest_path)
    rows = [
        classify_row(row, manifest_rows)
        for row in summary.get("rows", [])
        if isinstance(row, dict)
    ]
    required_not_proven = [
        row["id"] for row in required_rows(rows) if row.get("verdict") != "proven"
    ]
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "summary_path": str(summary_path),
        "manifest_path": str(manifest_path),
        "artifact_root": summary.get("artifact_root"),
        "verdict_counts": verdict_counts(rows),
        "required_rows_not_proven": required_not_proven,
        "passed": not required_not_proven,
        "rows": rows,
        "issue_coverage": issue_coverage(rows),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("summary", type=pathlib.Path, help="matrix SUMMARY.json")
    parser.add_argument(
        "--manifest",
        type=pathlib.Path,
        default=pathlib.Path(__file__).with_name("family-runtime-chat-matrix.json"),
    )
    parser.add_argument("--output", type=pathlib.Path)
    parser.add_argument(
        "--strict",
        action="store_true",
        help="exit non-zero when any required row is not proven",
    )
    args = parser.parse_args()

    output = args.output or args.summary.with_name("PROOF_CLASSIFICATION.json")
    report = classify(args.summary, args.manifest)
    save_json(output, report)
    print(json.dumps(report, indent=2, sort_keys=True))
    return 2 if args.strict and not report["passed"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
