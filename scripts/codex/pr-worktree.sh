#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/codex/pr-worktree.sh <task-id> [branch] [base]

Creates a task worktree under /tmp/osaurus-wt/<task-id>.
Defaults:
  branch: codex/<task-id>
  base:   origin/main
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -lt 1 ]]; then
  usage
  exit 0
fi

TASK_ID="$1"
BRANCH="${2:-codex/$TASK_ID}"
BASE="${3:-origin/main}"
ROOT="$(git rev-parse --show-toplevel)"
WORKTREE_ROOT="${OSAURUS_WORKTREE_ROOT:-/tmp/osaurus-wt}"
WORKTREE="$WORKTREE_ROOT/$TASK_ID"

case "$TASK_ID" in
  *..* | /* | *//* | '')
    echo "Invalid task id: $TASK_ID" >&2
    exit 2
    ;;
esac

cd "$ROOT"
GH_PROMPT_DISABLED=1 GIT_TERMINAL_PROMPT=0 git fetch origin --prune
mkdir -p "$WORKTREE_ROOT"

if [[ -e "$WORKTREE" ]]; then
  echo "Worktree already exists: $WORKTREE" >&2
  exit 3
fi

if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git worktree add "$WORKTREE" "$BRANCH"
else
  git worktree add -b "$BRANCH" "$WORKTREE" "$BASE"
fi

git -C "$WORKTREE" status --short --branch
