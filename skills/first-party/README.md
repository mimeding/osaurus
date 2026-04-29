# First-Party High-Fidelity Skills

These skills are first-party Osaurus content packages, not built-in app code. They are meant to stay portable so they can be maintained here or split into a dedicated skills repository later.

## Add A Skill

1. Create `skills/first-party/<skill-slug>/SKILL.md`.
2. Use Agent Skills frontmatter with a clear description and retrieval-rich keywords.
3. Set `osaurus-default-selected: false` and `osaurus-activation: "on-demand"`.
4. Add optional small text references under `references/`.
5. Add `./skills/first-party/<skill-slug>` to `.claude-plugin/marketplace.json`.
6. Run `swift test --filter FirstPartySkillPackTests`.

## Authoring Guidelines

- Keep `SKILL.md` concise enough to load into a chat turn when requested.
- Put stable background material in `references/`; keep each file under 100KB.
- Make descriptions and keywords specific because discovery relies on metadata.
- Target the single Chat/Agent loop, not legacy separate-mode flows.
- Do not require new app tools for prose-only workflow guidance.
