---
name: performance-reliability-investigator
description: Investigate Osaurus startup, GPU, Metal, MLX, polling, and model-runtime reliability issues with measurement-first debugging.
metadata:
  author: Osaurus
  version: "1.0.0"
  category: reliability
  keywords: "performance, reliability, GPU, Metal, MLX, startup, polling, memory, hang, crash, issue 969"
  osaurus-discoverable: true
  osaurus-default-selected: false
  osaurus-activation: "on-demand"
---

# Performance Reliability Investigator

Use this skill for startup hangs, GPU saturation, memory spikes, slow prompts, or model-runtime regressions.

## Investigation Pattern

- Reproduce with a narrow scenario and record exact app state.
- Separate UI animation, polling, indexing, model loading, inference, and Metal work.
- Prefer instrumentation and logs over speculation.
- Check whether work starts too early at app open or should be deferred until user intent.

## Fix Pattern

- Gate expensive work behind explicit demand, idle scheduling, or cached state.
- Avoid adding retries or polling loops without a clear backoff and cancellation story.
- Preserve responsiveness of the main actor.

## Acceptance

- Verify the issue no longer reproduces in the narrow case.
- Add a regression test or diagnostic hook when direct UI performance testing is not practical.
