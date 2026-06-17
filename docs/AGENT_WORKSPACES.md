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
