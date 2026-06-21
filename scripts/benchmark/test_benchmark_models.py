#!/usr/bin/env python3

import json
import unittest

import benchmark_models as bench


def make_result(
    server: str,
    model: str,
    prompt_id: int,
    iteration: int,
    status: str,
    tokens_per_second=None,
    status_notes=None,
):
    return bench.SingleResult(
        server=server,
        model=model,
        prompt_id=prompt_id,
        case_id=bench.case_id_for_prompt(prompt_id),
        prompt=f"Prompt {prompt_id}",
        iteration=iteration,
        success=status != bench.STATUS_FAILED,
        status_code=200 if status != bench.STATUS_FAILED else 500,
        ttft_ms=25.0,
        total_ms=100.0,
        output_chars=20,
        output_bytes=20,
        prompt_tokens=10,
        completion_tokens=5 if tokens_per_second else None,
        total_tokens=15 if tokens_per_second else None,
        tokens_per_second=tokens_per_second,
        token_source="usage.tokens_per_second" if tokens_per_second else None,
        memory_rss_before_bytes=None,
        memory_rss_after_bytes=None,
        memory_rss_delta_bytes=None,
        memory_sample_source=None,
        status=status,
        status_notes=status_notes or [],
        error=None if status != bench.STATUS_FAILED else "boom",
    )


class BenchmarkReportTests(unittest.TestCase):
    def test_missing_token_rate_is_unproven(self):
        status, notes = bench.classify_result(
            success=True,
            status_code=200,
            total_ms=123.0,
            tokens_per_second=None,
            error=None,
            memory_requested=False,
            memory_before=None,
            memory_after=None,
        )

        self.assertEqual(status, bench.STATUS_UNPROVEN)
        self.assertIn("no-metrics: missing positive token/s", notes)

    def test_unproven_metrics_keep_success_rate_but_not_pass_status(self):
        result = make_result(
            "osaurus",
            "qwen3-coder",
            0,
            1,
            bench.STATUS_UNPROVEN,
            status_notes=["no-metrics: missing positive token/s"],
        )
        summary = bench.aggregate([result])
        stats = summary[("osaurus", "qwen3-coder")]

        self.assertEqual(stats["status"], bench.STATUS_UNPROVEN)
        self.assertEqual(stats["success_rate"], 1.0)
        self.assertEqual(stats["status_counts"][bench.STATUS_UNPROVEN], 1)

    def test_mixed_pass_and_unproven_metrics_are_partial(self):
        results = [
            make_result("osaurus", "qwen3-coder", 0, 1, bench.STATUS_PASS, tokens_per_second=11.0),
            make_result(
                "osaurus",
                "qwen3-coder",
                1,
                1,
                bench.STATUS_UNPROVEN,
                status_notes=["no-metrics: missing positive token/s"],
            ),
        ]
        summary = bench.aggregate(results)
        stats = summary[("osaurus", "qwen3-coder")]

        self.assertEqual(stats["status"], bench.STATUS_PARTIAL)
        self.assertEqual(stats["success_rate"], 1.0)

    def test_resolves_token_rate_from_completion_tokens(self):
        rate, source = bench.resolve_tokens_per_second(
            usage_tokens_per_second=None,
            completion_tokens=20,
            total_ms=500.0,
        )

        self.assertEqual(rate, 40.0)
        self.assertEqual(source, "usage.completion_tokens/total_ms")

    def test_report_rows_are_sorted_and_strict_json(self):
        results = [
            make_result("z-server", "model-b", 1, 2, bench.STATUS_PASS, tokens_per_second=11.0),
            make_result(
                "a-server",
                "model-a",
                0,
                1,
                bench.STATUS_UNPROVEN,
                status_notes=["no-metrics: missing positive token/s"],
            ),
        ]
        summary = bench.aggregate(results)
        report = bench.build_benchmark_report(
            results=results,
            summary=summary,
            servers=[
                bench.ServerSpec("z-server", "http://z", "model-b"),
                bench.ServerSpec("a-server", "http://a", "model-a"),
            ],
            prompts=["Prompt 0", "Prompt 1"],
            cfg=bench.RequestConfig(stream=False, max_tokens=128, temperature=0.1),
            iterations=2,
            concurrency=1,
            generated_at="2026-06-18T00:00:00Z",
        )

        self.assertEqual(report["rows"][0]["server"], "a-server")
        self.assertEqual(report["rows"][0]["status"], bench.STATUS_UNPROVEN)
        self.assertEqual(report["summary"][0]["status"], bench.STATUS_UNPROVEN)
        json.dumps(report, allow_nan=False)

    def test_markdown_includes_status_and_prompt_case(self):
        result = make_result(
            "osaurus",
            "qwen3-coder",
            0,
            1,
            bench.STATUS_UNPROVEN,
            status_notes=["no-metrics: missing positive token/s"],
        )
        summary = bench.aggregate([result])
        report = bench.build_benchmark_report(
            results=[result],
            summary=summary,
            servers=[bench.ServerSpec("osaurus", "http://localhost:1337", "qwen3-coder")],
            prompts=["Prompt 0"],
            cfg=bench.RequestConfig(stream=True),
            iterations=1,
            concurrency=1,
            generated_at="2026-06-18T00:00:00Z",
        )
        markdown = bench.format_benchmark_markdown(report)

        self.assertIn("prompt-0", markdown)
        self.assertIn("unproven", markdown)
        self.assertIn("no-metrics: missing positive token/s", markdown)


if __name__ == "__main__":
    unittest.main()
