# Skills

Import and manage reusable AI capabilities following the open [Agent Skills](https://agentskills.io/) specification.

Skills are packages of instructions, context, and resources that give your AI specialized expertise. Whether you need a research analyst, debugging assistant, or creative brainstormer, skills let you extend your AI's capabilities on demand.

---

## Quick Start

Osaurus comes with 6 built-in skills ready to use:

| Skill | Description |
|-------|-------------|
| **Research Analyst** | Structured research with source evaluation and citation |
| **Creative Brainstormer** | Ideation and creative problem solving |
| **Study Tutor** | Educational guidance using the Socratic method |
| **Productivity Coach** | Task management and productivity optimization |
| **Content Summarizer** | Distill long content into concise summaries |
| **Debug Assistant** | Systematic debugging methodology |

**To get started:**

1. Open Management window (`⌘ Shift M`) → **Skills**
2. Enable a skill by toggling it on
3. Start a new chat — the AI now has access to the skill's expertise

---

## Importing Skills

### From GitHub

Import skills from any GitHub repository that includes a skills marketplace:

1. Click **Import** → **From GitHub**
2. Enter the repository URL (e.g., `github.com/owner/repo` or `owner/repo`)
3. Browse available skills and select which to import
4. Click **Import Selected**

Osaurus looks for `.claude-plugin/marketplace.json` in the repository to discover available skills.

Skill packs are portable by design: a repository can contain only `.claude-plugin/marketplace.json` plus skill directories, with no Osaurus app code. First-party high-fidelity skills in this repo follow that same layout under `skills/first-party/` so they can be maintained here or split into a dedicated skills repository later.

### From Files

Import skills from local files:

1. Click **Import** → **From File**
2. Select a skill file

**Supported formats:**

| Format | Description |
|--------|-------------|
| `.md` / `SKILL.md` | Agent Skills format (Markdown with YAML frontmatter) |
| `.json` | JSON export format |
| `.zip` | ZIP archive with `SKILL.md` and optional `references/` and `assets/` folders |

---

## Managing Skills

### Enable/Disable

Toggle skills on or off from the Skills view. Disabled skills won't be available to the AI.

### Edit

Click a skill to expand it, then click **Edit** to modify:

- **Name** and **Description**
- **Category** for organization
- **Instructions** — the full guidance given to the AI
- **Version** and **Author** metadata

Built-in skills are read-only but can be viewed.

### Export

Export skills to share with others:

1. Expand a skill and click **Export**
2. Choose a format:
   - **JSON** — Osaurus format for backup
   - **Markdown** — Agent Skills compatible `.md` file
   - **ZIP** — Complete package with references and assets

### Delete

Click **Delete** to remove a custom skill. Built-in skills cannot be deleted.

---

## Creating Custom Skills

Create your own skills with the built-in editor:

1. Click **Create Skill**
2. Fill in the details:
   - **Name** — A clear, descriptive name
   - **Description** — Brief summary (shown in the skill list)
   - **Category** — Optional grouping (e.g., "Development", "Writing")
   - **Instructions** — Detailed guidance for the AI (Markdown supported)
3. Click **Save**

**Tips for writing effective instructions:**

- Be specific about the skill's purpose and approach
- Include examples of expected behavior
- Define any frameworks or methodologies to follow
- Specify output formats when relevant

---

## Skill Format

Osaurus follows the [Agent Skills specification](https://agentskills.io/), using `SKILL.md` files with YAML frontmatter:

```markdown
---
name: Research Analyst
description: Structured research with source evaluation
category: Research
version: 1.0.0
author: Your Name
---

# Research Analyst

You are a research analyst specializing in thorough, well-sourced research.

## Methodology

1. Understand the research question
2. Identify reliable sources
3. Evaluate source credibility
4. Synthesize findings
5. Present with citations

## Output Format

Always include:
- Executive summary
- Key findings
- Source citations
- Confidence assessment
```

### Directory Structure

Skills are stored as directories:

```
~/.osaurus/skills/
└── research-analyst/
    ├── SKILL.md           # Main skill file
    ├── references/        # Optional: files loaded into context
    │   └── guidelines.txt
    └── assets/            # Optional: supporting files
        └── template.md
```

For reusable packs, keep each skill directory self-contained and list it in the repository's `.claude-plugin/marketplace.json`.

---

## Reference Files

Add context files that are automatically loaded when the skill is active:

1. Edit a skill
2. Add files to the `references/` folder
3. Text files (`.txt`, `.md`, etc.) are loaded into the AI's context

**Use cases:**

- Style guides and formatting rules
- Domain-specific terminology
- Process documentation
- Example templates

**Limits:** Each reference file can be up to 100KB.

---

## Lightweight Capability Selection

Osaurus keeps startup prompts small. Tool preflight can select a relevant tool subset before a chat turn, but skill instructions are not automatically injected just because a skill exists. A skill reaches the system prompt only when it is selected for the agent or loaded on demand in the active session.

### Lifecycle

| State | Meaning |
|-------|---------|
| **Installed** | The skill exists on disk, in a plugin, or in a marketplace repository. |
| **Discoverable** | The skill is indexed for `capabilities_search`. |
| **Selected** | The user or agent configuration injects the skill at chat start. |
| **Loaded** | `capabilities_load` adds the skill to the current session for follow-up turns. |

High-fidelity first-party skills use this metadata by default:

```yaml
metadata:
  osaurus-discoverable: true
  osaurus-default-selected: false
  osaurus-activation: "on-demand"
```

That means they are searchable and loadable, but they do not add prompt weight until the agent needs them.

### Runtime Discovery

During a conversation, the AI can discover and load additional capabilities on demand:

1. **`capabilities_search`** searches indexed methods, tools, and discoverable skills.
2. **`capabilities_load`** loads specific IDs returned by search.

Loaded tools are added to the callable schema for the session. Loaded skills are appended to the session instructions on later turns without becoming globally selected for the agent.

### Search Modes

Preflight search modes control automatic tool selection:

| Mode        | Tools Loaded | Description                               |
| ----------- | ------------ | ----------------------------------------- |
| `off`       | 0            | Disable preflight selection               |
| `narrow`    | Up to 2      | Minimal tool injection                    |
| `balanced`  | Up to 5      | Default tool coverage                     |
| `wide`      | Up to 15     | Larger tool surface for complex tasks     |

Skills remain available through selected agent configuration and on-demand capability loading.

---

## Agent Integration

Skills are available to agents in two lightweight ways:

- Selected skills are injected at chat start for that agent.
- Discoverable skills can be found with `capabilities_search` and loaded into the current session with `capabilities_load`.

New high-fidelity skills can opt out of default agent selection with `osaurus-default-selected: false`. They still appear in search and can be loaded when the task calls for them.

---

## Troubleshooting

### Skills not appearing in chat

- Verify the skill is enabled (toggle is on)
- Check whether the skill is selected for the agent, or ask the agent to use `capabilities_search`
- Check that the skill's description and keywords clearly describe its purpose
- Start a new chat session
- For tools, try setting a wider preflight search mode in chat configuration

### GitHub import fails

- Ensure the repository is public or you have access
- Verify the repo contains `.claude-plugin/marketplace.json`
- Check your network connection

### Skill instructions not being followed

- Review the skill's instructions for clarity
- Ensure the skill's description is specific enough for the RAG search to match it
- Try being more explicit in your request to improve search relevance

### Import format errors

- For `.md` files: Ensure valid YAML frontmatter between `---` markers
- For `.zip` files: Ensure `SKILL.md` is at the root or in a named folder
- For `.json` files: Validate JSON syntax

---

## Related Documentation

- [Agents](../README.md#agents) — Custom AI assistants
- [Tools & Plugins](PLUGIN_AUTHORING.md) — Extend with custom tools
- [Agent Skills Specification](https://agentskills.io/) — Open format documentation
- [Features: Methods](FEATURES.md#methods) — Reusable learned workflows
- [Features: Context Management](FEATURES.md#context-management) — Automated capability selection
