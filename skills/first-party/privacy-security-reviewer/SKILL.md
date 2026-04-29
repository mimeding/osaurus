---
name: privacy-security-reviewer
description: Review Osaurus changes for private document safety, secrets handling, sandbox boundaries, destructive operations, signing, and local-first trust.
metadata:
  author: Osaurus
  version: "1.0.0"
  category: security
  keywords: "privacy, security, private documents, secrets, sandbox, signing, destructive operations, access keys, local first"
  osaurus-discoverable: true
  osaurus-default-selected: false
  osaurus-activation: "on-demand"
---

# Privacy Security Reviewer

Use this skill when a change touches user files, credentials, networking, plugins, storage, or sandbox execution.

## Review Focus

- Never delete, move, or rewrite private documents unless the user explicitly requested it.
- Treat secrets as non-printable and non-loggable.
- Keep sandbox and host-folder permissions narrow.
- Prefer explicit user approval for destructive, networked, or credentialed actions.

## Plugin And Tool Safety

- Validate paths stay inside the intended root.
- Keep network and filesystem permissions opt-in.
- Require signed or verified distribution paths for installable code.

## Output

- Lead with concrete risks and affected files.
- Separate confirmed issues from assumptions and future hardening ideas.
