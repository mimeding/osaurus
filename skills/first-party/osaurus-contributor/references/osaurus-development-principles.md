# Osaurus Development Principles

- The chat window is the agent loop.
- Startup context should stay small; load specialized instructions only when they are selected or requested.
- Tool behavior must follow the JSON success/failure envelope in `docs/TOOL_CONTRACT.md`.
- New workflows should compose with folder context, sandbox context, `todo`, `clarify`, `complete`, and `share_artifact`.
