---
name: osaurus-contributor
description: Contribute to Osaurus code with repo-aware Swift architecture, clean Git hygiene, targeted verification, and post-PR-893 single Chat/Agent loop conventions.
metadata:
  author: Osaurus
  version: "1.0.0"
  category: development
  keywords: "osaurus, swift, architecture, contributor, codebase, tests, git, package build, chat agent loop"
  osaurus-discoverable: true
  osaurus-default-selected: false
  osaurus-activation: "on-demand"
---

# Osaurus Contributor

Use this skill when changing Osaurus itself.

## Operating Rules

- Work from a clean checkout and leave private user documents untouched.
- Treat the single Chat/Agent loop as the product architecture. Do not add a new mode, tab, or legacy planning surface.
- Keep changes inside the established layers: Models are pure data, Services own business logic, Managers own UI state, Views render feature UI, Tools expose capability contracts.
- Prefer focused changes that match nearby code over broad refactors.
- Preserve user or teammate edits in the worktree.

## Verification

- Prefer package-level Swift verification for OsaurusCore.
- Do not rely on workspace `xcodebuild` for local verification when private repo rules say external dependencies have known failures.
- Run targeted tests first, then broaden to package checks and CI-equivalent jobs.

## Completion Standard

- Explain what changed, how it was verified, and any remaining risk.
- When producing files for the user, surface them through the artifact flow used by the current chat system.
