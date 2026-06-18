#!/usr/bin/env python3
"""Render PROOF_CLASSIFICATION.json into a maintainer-readable proof matrix.

This script is deliberately a renderer only. It does not classify artifacts or
promote proof rows; ``classify-runtime-proof-summary.py`` remains the source of
verdicts.
"""

from __future__ import annotations

import argparse
import json
import pathlib
from collections import Counter
from typing import Any


BEGIN = "<!-- BEGIN RUNTIME PROOF MATRIX -->"
END = "<!-- END RUNTIME PROOF MATRIX -->"
DASHBOARD_BEGIN = "<!-- BEGIN RUNTIME RESILIENCE DASHBOARD -->"
DASHBOARD_END = "<!-- END RUNTIME RESILIENCE DASHBOARD -->"

RESILIENCE_SIGNALS = (
    "tokens_per_second",
    "cache",
    "marker_leak",
    "cancellation",
    "crash_proof",
)

SIGNAL_LABELS = {
    "tokens_per_second": "Token/s",
    "cache": "Cache",
    "marker_leak": "Marker leak",
    "cancellation": "Cancellation",
    "crash_proof": "Crash proof",
}

SCHEMA_ROWS = [
    {
        "id": "issue-903-system-prompt-injection-schema",
        "model": "all local chat runtimes",
        "family": "cross-family",
        "priority": "schema-required",
        "verdict": "unproven",
        "requirements": [
            "visible_output",
            "tokens_per_second",
            "no_parser_marker_leak",
            "multi_turn_coherency",
            "system_prompt_injection",
        ],
        "artifact_paths": [],
        "blockers": [
            {
                "message": (
                    "requires a live artifact with an explicit system-prompt injection probe, "
                    "visible output, token/s, multi-turn coherency, and no parser marker leakage"
                )
            }
        ],
        "schema_only": True,
    },
    {
        "id": "issue-1163-hy3-harmony-retro-validation-schema",
        "model": "Hy3/harmony local rows",
        "family": "hy3",
        "priority": "schema-required",
        "verdict": "unproven",
        "requirements": [
            "visible_output",
            "tokens_per_second",
            "no_parser_marker_leak",
            "multi_turn_coherency",
        ],
        "artifact_paths": [],
        "blockers": [
            {
                "message": (
                    "requires a Hy3/harmony live artifact; sibling model rows or source-only "
                    "parser checks do not prove this issue"
                )
            }
        ],
        "schema_only": True,
    },
]


def load_json(path: pathlib.Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"classification must be a JSON object: {path}")
    return value


def escape_markdown(value: object) -> str:
    return str(value).replace("\n", "<br>").replace("|", "\\|")


def blocker_messages(row: dict[str, Any]) -> list[str]:
    messages = []
    for blocker in row.get("blockers") or []:
        if not isinstance(blocker, dict):
            continue
        message = str(blocker.get("message") or "")
        requirement = blocker.get("requirement")
        if requirement:
            messages.append(f"{requirement}: {message}")
        elif message:
            messages.append(message)
    return messages


def normalized_row(row: dict[str, Any]) -> dict[str, Any]:
    evidence = []
    summary_path = row.get("summary_path")
    if summary_path:
        evidence.append(str(summary_path))
    evidence.extend(str(path) for path in row.get("artifact_paths") or [] if path)
    evidence = list(dict.fromkeys(path for path in evidence if path))
    return {
        "id": str(row.get("id") or ""),
        "model": str(row.get("model") or row.get("id") or ""),
        "family": str(row.get("family") or "unknown"),
        "priority": str(row.get("priority") or "unspecified"),
        "verdict": str(row.get("verdict") or "unproven"),
        "requirements": sorted(str(value) for value in row.get("requirements") or [] if value),
        "evidence": evidence,
        "blockers": blocker_messages(row),
        "schema_only": bool(row.get("schema_only")),
        "failed_checks": [str(value) for value in row.get("failed_checks") or []],
        "resilience_evidence": normalized_resilience_evidence(row),
    }


def matrix_rows(report: dict[str, Any]) -> list[dict[str, Any]]:
    rows = [normalized_row(row) for row in report.get("rows") or [] if isinstance(row, dict)]
    existing_ids = {row["id"] for row in rows}
    for schema in SCHEMA_ROWS:
        if schema["id"] not in existing_ids:
            rows.append(normalized_row(schema))
    return sorted(rows, key=lambda row: (row["family"], row["model"], row["id"]))


def verdict_counts(rows: list[dict[str, Any]]) -> dict[str, int]:
    counts = Counter(row["verdict"] for row in rows)
    return {key: counts.get(key, 0) for key in ("proven", "partial", "failed", "unproven")}


def normalized_resilience_signal(raw: Any, fallback_summary: str, fallback_paths: list[str]) -> dict[str, Any]:
    if isinstance(raw, dict):
        return {
            "verdict": str(raw.get("verdict") or "unproven"),
            "summary": str(raw.get("summary") or fallback_summary),
            "evidence_paths": [
                str(path)
                for path in raw.get("evidence_paths") or fallback_paths
                if path
            ],
            "metrics": raw.get("metrics") if isinstance(raw.get("metrics"), dict) else {},
        }
    return {
        "verdict": "unproven",
        "summary": fallback_summary,
        "evidence_paths": fallback_paths,
        "metrics": {},
    }


def normalized_resilience_evidence(row: dict[str, Any]) -> dict[str, dict[str, Any]]:
    raw = row.get("resilience_evidence") if isinstance(row.get("resilience_evidence"), dict) else {}
    fallback_paths = []
    if row.get("summary_path"):
        fallback_paths.append(str(row["summary_path"]))
    fallback_paths.extend(str(path) for path in row.get("artifact_paths") or [] if path)
    evidence: dict[str, dict[str, Any]] = {}
    for signal in RESILIENCE_SIGNALS:
        evidence[signal] = normalized_resilience_signal(
            raw.get(signal),
            f"{SIGNAL_LABELS[signal].lower()} evidence was not recorded",
            fallback_paths,
        )
    return evidence


def signal_counts(rows: list[dict[str, Any]]) -> dict[str, dict[str, int]]:
    counts: dict[str, dict[str, int]] = {}
    for signal in RESILIENCE_SIGNALS:
        verdicts = Counter(
            row["resilience_evidence"].get(signal, {}).get("verdict", "unproven")
            for row in rows
        )
        counts[signal] = {
            key: verdicts.get(key, 0)
            for key in ("proven", "partial", "failed", "unproven")
        }
    return counts


def evidence_links(paths: list[str], limit: int = 3) -> str:
    unique = list(dict.fromkeys(path for path in paths if path))
    if not unique:
        return "no links"
    links = [f"[{index}]({path})" for index, path in enumerate(unique[:limit], start=1)]
    if len(unique) > limit:
        links.append(f"+{len(unique) - limit} more")
    return ", ".join(links)


def signal_cell(row: dict[str, Any], signal: str) -> str:
    evidence = row["resilience_evidence"].get(signal, {})
    verdict = evidence.get("verdict", "unproven")
    summary = evidence.get("summary", "")
    paths = evidence.get("evidence_paths") or []
    return f"{verdict}: {summary}<br>{evidence_links(paths)}"


def render_dashboard_markdown(report: dict[str, Any], source: pathlib.Path, generated_at: str | None = None) -> str:
    rows = matrix_rows(report)
    counts = verdict_counts(rows)
    per_signal = signal_counts(rows)
    issue_1228 = (report.get("issue_coverage") or {}).get("#1228") or {}
    lines = [
        DASHBOARD_BEGIN,
        "",
        f"Generated from {escape_markdown(source)} at {escape_markdown(generated_at or report.get('generated_at') or 'unknown')}.",
        "",
        "Verdicts: "
        + ", ".join(f"{name}={counts[name]}" for name in ("proven", "partial", "failed", "unproven")),
        "",
        "Signals: "
        + "; ".join(
            f"{SIGNAL_LABELS[signal]} "
            + ", ".join(f"{name}={per_signal[signal][name]}" for name in ("proven", "partial", "failed", "unproven"))
            for signal in RESILIENCE_SIGNALS
        ),
        "",
        "Crash/cancellation issue coverage: "
        + escape_markdown(issue_1228.get("verdict", "unproven"))
        + " - "
        + escape_markdown(issue_1228.get("note", "not recorded")),
        "",
        "| Row | Model | Verdict | Token/s | Cache | Marker leak | Cancellation | Crash proof | Blockers |",
        "|---|---|---|---|---|---|---|---|---|",
    ]
    for row in rows:
        values = [
            row["id"],
            row["model"],
            row["verdict"],
            signal_cell(row, "tokens_per_second"),
            signal_cell(row, "cache"),
            signal_cell(row, "marker_leak"),
            signal_cell(row, "cancellation"),
            signal_cell(row, "crash_proof"),
            "<br>".join(row["blockers"]) if row["blockers"] else "none",
        ]
        lines.append("| " + " | ".join(escape_markdown(value) for value in values) + " |")
    lines.extend(["", DASHBOARD_END, ""])
    return "\n".join(lines)


def render_markdown(report: dict[str, Any], source: pathlib.Path, generated_at: str | None = None) -> str:
    rows = matrix_rows(report)
    lines = [
        BEGIN,
        "",
        f"Generated from {escape_markdown(source)} at {escape_markdown(generated_at or report.get('generated_at') or 'unknown')}.",
        "",
        "| Row | Model | Family | Verdict | Requirements | Evidence | Blockers |",
        "|---|---|---|---|---|---|---|",
    ]
    for row in rows:
        values = [
            row["id"],
            row["model"],
            row["family"],
            row["verdict"],
            ", ".join(row["requirements"]),
            "<br>".join(row["evidence"]) if row["evidence"] else "none",
            "<br>".join(row["blockers"]) if row["blockers"] else "none",
        ]
        lines.append("| " + " | ".join(escape_markdown(value) for value in values) + " |")
    lines.extend(["", END, ""])
    return "\n".join(lines)


def replace_marked_matrix(document: str, matrix: str) -> str:
    begin = document.find(BEGIN)
    if begin == -1:
        separator = "\n" if document.endswith("\n") else "\n\n"
        return document + separator + matrix
    end = document.find(END, begin)
    if end == -1:
        raise ValueError(f"found {BEGIN} without {END}")
    return document[:begin] + matrix + document[end + len(END) :]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("classification", type=pathlib.Path, help="PROOF_CLASSIFICATION.json")
    parser.add_argument("--output", type=pathlib.Path, help="write matrix markdown to this file")
    parser.add_argument("--dashboard-output", type=pathlib.Path, help="write resilience dashboard markdown to this file")
    parser.add_argument("--update-doc", type=pathlib.Path, help="replace or append the marked matrix in this doc")
    parser.add_argument("--generated-at", help="override generated timestamp for deterministic tests")
    parser.add_argument("--json-surface", type=pathlib.Path, help="write the read-only row surface as JSON")
    parser.add_argument("--dashboard-json-surface", type=pathlib.Path, help="write the resilience dashboard as JSON")
    args = parser.parse_args()

    report = load_json(args.classification)
    matrix = render_markdown(report, args.classification, generated_at=args.generated_at)
    rows = matrix_rows(report)

    if args.json_surface:
        args.json_surface.write_text(
            json.dumps(
                {
                    "generated_at": args.generated_at or report.get("generated_at") or "unknown",
                    "source_classification_path": str(args.classification),
                    "artifact_root": report.get("artifact_root"),
                    "verdict_counts": verdict_counts(rows),
                    "rows": rows,
                    "issue_coverage": report.get("issue_coverage") or {},
                },
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )

    if args.dashboard_json_surface:
        args.dashboard_json_surface.write_text(
            json.dumps(
                {
                    "generated_at": args.generated_at or report.get("generated_at") or "unknown",
                    "source_classification_path": str(args.classification),
                    "artifact_root": report.get("artifact_root"),
                    "verdict_counts": verdict_counts(rows),
                    "signal_counts": signal_counts(rows),
                    "rows": rows,
                    "issue_coverage": report.get("issue_coverage") or {},
                },
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )

    if args.dashboard_output:
        args.dashboard_output.write_text(
            render_dashboard_markdown(report, args.classification, generated_at=args.generated_at),
            encoding="utf-8",
        )

    if args.update_doc:
        document = args.update_doc.read_text(encoding="utf-8")
        args.update_doc.write_text(replace_marked_matrix(document, matrix), encoding="utf-8")
    elif args.output:
        args.output.write_text(matrix, encoding="utf-8")
    else:
        print(matrix, end="")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
