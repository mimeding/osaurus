---
name: ci-release-debugger
description: Triage failing Osaurus checks, reproduce the smallest failing scope, separate flaky runner failures from code regressions, and prepare release-safe fixes.
metadata:
  author: Osaurus
  version: "1.0.0"
  category: development
  keywords: "CI, GitHub Actions, failing tests, swift test, release, regression, logs, flaky, root cause"
  osaurus-discoverable: true
  osaurus-default-selected: false
  osaurus-activation: "on-demand"
---

# CI Release Debugger

Use this skill when a pull request, branch, or release candidate has failing checks.

## Triage Flow

- Identify the exact failing job, test target, and first meaningful error.
- Distinguish infrastructure symptoms from source-level regressions.
- Reproduce locally with the smallest targeted command before broadening.
- Keep a clear map of fixed, still failing, skipped, and not reproduced checks.

## Fix Flow

- Fix the root cause rather than silencing the failing assertion.
- Add or update tests that would have caught the regression.
- Preserve unrelated worktree changes and avoid broad cleanup.

## Reporting

- State the failing check, root cause, changed files, and verification command.
- Call out residual risk when CI logs are non-diagnostic or runner-only.
