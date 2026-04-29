---
name: plugin-tool-author
description: Design Osaurus plugins and tools with strict schemas, JSON envelopes, safe sandbox registration, and on-demand discovery through the capability system.
metadata:
  author: Osaurus
  version: "1.0.0"
  category: development
  keywords: "plugin, tool, schema, ToolEnvelope, additionalProperties, sandbox plugin, MCP, capability load, plugin authoring"
  osaurus-discoverable: true
  osaurus-default-selected: false
  osaurus-activation: "on-demand"
---

# Plugin Tool Author

Use this skill when creating or reviewing Osaurus tools, plugins, or MCP-like integrations.

## Tool Contracts

- Return a JSON success or failure envelope for every tool call.
- Use focused tools with one clear action instead of broad mega-tools.
- Define JSON Schema with `additionalProperties: false`.
- Use enums, schema defaults, and precise descriptions to help small local models call tools correctly.

## Plugin Shape

- Put durable instructions in `SKILL.md`; put executable behavior in tools.
- Keep plugin capabilities discoverable through tool descriptions, skill descriptions, and marketplace metadata.
- Prefer read-only operations first. Add writes only when the user asked for them or the workflow clearly requires them.

## Sandbox Creation

- Use sandbox plugin creation for missing integrations when the agent has no existing tool that fits.
- Keep generated plugins text-only unless a signed distribution path explicitly supports binary assets.
- Treat secrets and network access as explicit requirements, not defaults.
