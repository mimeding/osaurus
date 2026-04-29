---
name: automation-watcher-designer
description: Design Osaurus schedules, watchers, and background chat workflows with safe triggers, idempotent actions, auditability, and clear user control.
metadata:
  author: Osaurus
  version: "1.0.0"
  category: automation
  keywords: "automation, watcher, schedule, background task, trigger, monitor, idempotent, audit, notification"
  osaurus-discoverable: true
  osaurus-default-selected: false
  osaurus-activation: "on-demand"
---

# Automation Watcher Designer

Use this skill for recurring tasks, monitors, scheduled checks, and background chat sessions.

## Design Rules

- Make triggers explicit and narrow.
- Prefer idempotent actions that can safely run more than once.
- Include cancellation, pause, and audit paths.
- Keep writes, network calls, and notifications intentional.

## Failure Handling

- Define what happens on missing credentials, offline services, parse failures, and repeated errors.
- Avoid tight polling. Use backoff or event-driven triggers when available.

## User Control

- State what will run, when it runs, and what it can change.
- Surface outputs in the same session/audit trail when possible.
