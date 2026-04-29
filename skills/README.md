# Skill Packs

This directory holds portable Agent Skills content. It is intentionally separate from `Packages/OsaurusCore` so skill instructions can evolve without app-code changes.

## Maintenance Model

- Each skill is a self-contained directory with `SKILL.md` and optional `references/` or `assets/`.
- `.claude-plugin/marketplace.json` is the import index Osaurus uses for GitHub skill import.
- Skill packs can move to a separate repository as long as the same marketplace file and relative skill paths are preserved.
- Adding, removing, or editing a skill should not require Swift changes unless the runtime capability system itself changes.

## Development Alignment

- Runtime changes for skills must follow the public layering guidance in `docs/CONTRIBUTING.md`: models stay data-only, services handle retrieval/loading behavior, managers own UI-facing state, and views stay presentation-focused.
- Skill content should target the single Chat/Agent loop documented in `docs/AGENT_LOOP.md`; do not add instructions for legacy separate-mode flows.
- Any new or changed capability tool behavior must preserve the JSON envelope and schema rules in `docs/TOOL_CONTRACT.md`.
- Skill-pack distribution should remain compatible with the GitHub import path in `docs/SKILLS.md` and plugin skill packaging guidance in `docs/PLUGIN_AUTHORING.md`.

## Lightweight Defaults

High-fidelity skills should use:

```yaml
metadata:
  osaurus-discoverable: true
  osaurus-default-selected: false
  osaurus-activation: "on-demand"
```

This keeps skills searchable and loadable while avoiding startup prompt weight.

## Checks

Run these from the repo root after changing skill content:

```bash
jq empty .claude-plugin/marketplace.json
cd Packages/OsaurusCore
swift test --filter FirstPartySkillPackTests
```

The test validates that every skill directory is listed in the marketplace, every listed skill exists, metadata stays on-demand, and reference files remain under the prompt-size limit.
