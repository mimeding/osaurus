---
name: agent-loop-operator
description: Operate the Osaurus Chat/Agent loop with lightweight planning, correct use of todo, clarify, complete, share_artifact, and on-demand capability loading.
metadata:
  author: Osaurus
  version: "1.0.0"
  category: agent
  keywords: "agent loop, todo, clarify, complete, share artifact, capabilities search, capabilities load, folder context, sandbox"
  osaurus-discoverable: true
  osaurus-default-selected: false
  osaurus-activation: "on-demand"
---

# Agent Loop Operator

Use this skill when a task needs disciplined execution inside an Osaurus chat session.

## Loop Discipline

- Use `todo` only when the request has three or more meaningful steps.
- Use `clarify` for one blocking decision only. For minor preferences, choose a sensible default.
- Use `complete` once at the end with what was done and how it was verified.
- Use `share_artifact` for generated files, reports, images, charts, or code blobs that the user should see.

## Capability Loading

- Start with the tools already available.
- Use `capabilities_search` when the current schema is missing a capability.
- Use `capabilities_load` with IDs from search results. Do not invent capability IDs.
- Load specialized skills on demand instead of carrying broad instruction packs in every prompt.

## Execution Context

- Use folder context for real repository edits.
- Use sandbox context for isolated scripts, package installation, scraping, and generated artifacts.
- Avoid switching execution style unless the task requires it.
