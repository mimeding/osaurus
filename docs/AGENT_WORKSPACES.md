# Agent Workspaces

Agent workspaces give each custom agent a durable knowledge-base surface made
from local file and folder references. They are stored under the agent's
per-agent data directory and are injected into the system prompt as bounded
summaries.

## What Is Stored

- Workspace metadata: name, description, source list, create/update times.
- Source metadata: kind, path, display name, status, size/count hints, and a
  bounded summary.
- File sources read only a small UTF-8 prefix and never ingest binary content.
- Folder sources record a shallow top-level listing, not recursive file content.

Workspaces are orientation context, not a vector index or retrieval engine. If
source-reading tools are available, the agent is instructed to inspect the
source path before quoting details.

## Context Source Boundary

Workspace knowledge is coordinated with the other Osaurus context sources before
it reaches the prompt. The contract is intentionally explicit so workspace/KB
summaries do not overlap with memory, the Agent DB, live filesystem context, or
screen awareness.

| Source kind | Owner | Provenance | Injection slot | Dedupe key | Privacy path | Precedence |
|---|---|---|---|---|---|---:|
| `memory` | Agent | Conversation-derived memory selected by the relevance gate | Latest user-message prefix | `agent:<id>:memory` | Local user message | 10 |
| `screen` | User | Frozen on-screen text snapshot for the current turn | Latest user-message prefix | `screen:current-turn` | Privacy-filtered user message | 20 |
| `hostWorkspace` | User | Live selected folder tree, manifests, project context, and git status | Static system prompt | `host-workspace:<root>` | Local system prompt | 60 |
| `agentWorkspace` | Agent | Durable workspace metadata and bounded source summaries attached to the agent | Dynamic system prompt | `agent:<id>:agent-workspaces` | Local system prompt | 100 |
| `agentDatabase` | Agent | Live per-agent SQLite schema and agent-authored tables | Dynamic system prompt | `agent:<id>:agent-db` | Local system prompt | 110 |
| `sandboxLocal` | Runtime | Live sandbox runtime state such as installed packages and configured secret names | Dynamic system prompt | `agent:<id>:sandbox-state` | Local system prompt | 120 |

The workspace/KB lane has a distinct role:

- It is durable source orientation selected by the user for a custom agent.
- It is not memory; memory is distilled from conversations and prepended to the
  latest user message only when relevant.
- It is not the Agent DB; the Agent DB is mutable agent-owned structured state.
- It is not folder or sandbox context; those describe the live execution
  filesystem and tools for the current chat.
- It is not screen context; screen context is a frozen current-turn snapshot
  that follows the screen privacy-filter path.

## HTTP API

List workspaces:

```http
GET /agents/{agentId}/workspaces
```

Create a workspace:

```http
POST /agents/{agentId}/workspaces
Content-Type: application/json

{
  "name": "Project notes",
  "description": "Planning docs for this agent",
  "paths": ["/Users/me/project/README.md", "/Users/me/project/docs"]
}
```

Attach more sources:

```http
POST /agents/{agentId}/workspaces/{workspaceId}/sources
Content-Type: application/json

{
  "paths": ["/Users/me/project/CHANGELOG.md"]
}
```

Delete a workspace:

```http
DELETE /agents/{agentId}/workspaces/{workspaceId}
```

Built-in agents are not exposed through this API. Agent-scoped API keys can
only access their own agent's workspace endpoints.
