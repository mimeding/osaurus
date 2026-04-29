#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/ci/check-pr-clean.sh [repo] [pr]

Verifies that a GitHub pull request has attached checks and that every check is
green. Run this before marking a PR ready or asking for merge.

Arguments:
  repo  GitHub repository, default: osaurus-ai/osaurus
  pr    Pull request number or URL. If omitted, gh resolves the current branch.

Environment:
  PR_CLEAN_REQUIRED_CHECKS
        Space-separated required check names. Defaults to:
        "test-core test-cli swiftlint shellcheck pr-clean-gate"
USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

repo="${1:-osaurus-ai/osaurus}"
pr="${2:-}"

if ! command -v gh >/dev/null 2>&1; then
  echo "error: GitHub CLI (gh) is required" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required" >&2
  exit 2
fi

if [ -z "$pr" ]; then
  pr="$(gh pr view --repo "$repo" --json number --jq .number)"
fi

checks_error="$(mktemp)"
trap 'rm -f "$checks_error"' EXIT

if ! checks_json="$(gh pr checks "$pr" \
  --repo "$repo" \
  --json name,state,bucket,workflow,link \
  2>"$checks_error")"; then
  if grep -qi "no checks reported" "$checks_error"; then
    echo "error: PR $pr has no GitHub checks attached" >&2
    echo "Push/rebase the branch or close/reopen the PR so Actions run before review." >&2
    exit 1
  fi

  cat "$checks_error" >&2
  exit 1
fi

check_count="$(jq 'length' <<< "$checks_json")"
if [ "$check_count" -eq 0 ]; then
  echo "error: PR $pr has no GitHub checks attached" >&2
  echo "Push/rebase the branch or close/reopen the PR so Actions run before review." >&2
  exit 1
fi

required_checks="${PR_CLEAN_REQUIRED_CHECKS:-test-core test-cli swiftlint shellcheck pr-clean-gate}"
failed=0

for check in $required_checks; do
  match_count="$(jq --arg name "$check" '[.[] | select(.name == $name)] | length' <<< "$checks_json")"
  if [ "$match_count" -eq 0 ]; then
    echo "error: required check is missing: $check" >&2
    failed=1
    continue
  fi

  non_success="$(jq -r --arg name "$check" '
    .[]
    | select(.name == $name and .state != "SUCCESS")
    | "\(.name): \(.state) \(.link)"
  ' <<< "$checks_json")"

  if [ -n "$non_success" ]; then
    echo "$non_success" >&2
    failed=1
  fi
done

non_passing="$(jq -r '
  .[]
  | select(.bucket != "pass")
  | "\(.name): \(.state) \(.link)"
' <<< "$checks_json")"

if [ -n "$non_passing" ]; then
  echo "error: non-passing checks remain:" >&2
  echo "$non_passing" >&2
  failed=1
fi

if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo "PR $pr is clean: $check_count GitHub checks attached and passing."
