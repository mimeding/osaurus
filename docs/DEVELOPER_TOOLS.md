# Developer Tools

Osaurus includes built-in developer tools for debugging, monitoring, and testing your integration. Access them via the Management window (`⌘ Shift M`).

---

## Insights

The **Insights** tab provides real-time monitoring of all API requests flowing through Osaurus.

### Accessing Insights

1. Open the Management window (`⌘ Shift M`)
2. Click **Insights** in the sidebar

### Features

#### Request Logging

Every API request is logged with:

| Field        | Description                 |
| ------------ | --------------------------- |
| **Time**     | Request timestamp           |
| **Source**   | Origin: Chat UI or HTTP API |
| **Method**   | HTTP method (GET/POST)      |
| **Path**     | Request endpoint            |
| **Status**   | HTTP status code            |
| **Duration** | Total response time         |

Click any row to expand and see full request/response details.

#### Filtering

Filter requests to find what you need:

| Filter     | Options                      |
| ---------- | ---------------------------- |
| **Search** | Filter by path or model name |
| **Method** | All, GET only, POST only     |
| **Source** | All, Chat UI, HTTP API       |

#### Aggregate Stats

The stats bar shows real-time metrics:

| Stat           | Description                           |
| -------------- | ------------------------------------- |
| **Requests**   | Total request count                   |
| **Success**    | Success rate percentage               |
| **Avg Time**   | Average response duration             |
| **Errors**     | Total error count                     |
| **Inferences** | Chat completion requests (if any)     |
| **Avg Speed**  | Average tokens/second (for inference) |

#### Request Details

Expand a request row to see:

**Request Panel:**

- Full request body (formatted JSON)
- Copy to clipboard

**Response Panel:**

- Full response body (formatted JSON)
- Status indicator (green for success, red for error)
- Response duration
- Copy to clipboard

**Inference Details** (for chat completions):

- Model used
- Token counts (input → output)
- Generation speed (tok/s)
- Temperature
- Max tokens
- Finish reason

**Tool Calls** (if applicable):

- Tool name
- Arguments
- Duration
- Success/error status

### Use Cases

- **Debugging API integration** — See exactly what's being sent and received
- **Performance monitoring** — Track latency and throughput
- **Tool call inspection** — Debug tool calling behavior
- **Error investigation** — Understand why requests fail

---

## Server Explorer

The **Server** tab provides an interactive API reference and testing interface.

### Accessing Server Explorer

1. Open the Management window (`⌘ Shift M`)
2. Click **Server** in the sidebar

### Features

#### Server Status

View current server state:

| Info           | Description                      |
| -------------- | -------------------------------- |
| **Server URL** | Base URL for API requests        |
| **Status**     | Running, Stopped, Starting, etc. |

Copy the server URL with one click for use in your applications.

#### API Endpoint Catalog

Browse all available endpoints, organized by category:

| Category  | Endpoints                                              |
| --------- | ------------------------------------------------------ |
| **Core**  | `/`, `/health`, `/models`, `/tags`                     |
| **Chat**  | `/chat/completions`, `/chat`, `/messages`, `/responses` |
| **Audio** | `/audio/transcriptions`                                |
| **MCP**   | `/mcp/health`, `/mcp/tools`, `/mcp/call`               |

Each endpoint shows:

- HTTP method (GET/POST)
- Path
- Compatibility badge (OpenAI, Ollama, Anthropic, Open Responses, MCP)
- Description

#### Interactive Testing

Test any endpoint directly:

1. Click an endpoint row to expand it
2. For POST requests, edit the JSON payload
3. Click **Send Request**
4. View the formatted response

**Request Panel (left):**

- Editable JSON payload for POST requests
- Request preview for GET requests
- Reset button to restore default payload
- Send Request button

**Response Panel (right):**

- Formatted response body
- Status code badge
- Response duration
- Copy button
- Clear button

#### Documentation Link

Quick access to the full documentation at docs.osaurus.ai.

### Use Cases

- **API exploration** — Discover available endpoints
- **Quick testing** — Test endpoints without external tools
- **Payload experimentation** — Try different request formats
- **Response inspection** — See formatted API responses

---

## Workflow Examples

### Debugging a Chat Integration

1. Open **Insights**
2. Send a request from your application
3. Find the request in the log (filter by path if needed)
4. Expand to see request/response details
5. Check for errors in the response
6. If using tools, inspect tool call details

### Testing Tool Calling

1. Open **Server Explorer**
2. Expand `/chat/completions`
3. Modify the payload to include tools:

```json
{
  "model": "foundation",
  "messages": [{ "role": "user", "content": "What time is it?" }],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "current_time",
        "description": "Get the current time"
      }
    }
  ]
}
```

4. Click **Send Request**
5. Observe the tool call in the response
6. Check **Insights** for the full request flow

### Monitoring Performance

1. Open **Insights**
2. Run your test workload
3. Observe:
   - Avg Time (should be consistent)
   - Success rate (should be high)
   - Avg Speed for inference (tok/s)
4. Expand slow requests to investigate

### Verifying MCP Tools

1. Open **Server Explorer**
2. Expand `GET /mcp/tools`
3. Click **Send Request**
4. Verify your expected tools are listed
5. Test a specific tool with `POST /mcp/call`

---

## Tips

### Clear Logs Regularly

The Insights log grows over time. Use the **Clear** button to reset when debugging a specific issue.

### Use Source Filters

Filter by source to distinguish between:

- **Chat** — Requests from the built-in chat UI
- **HTTP** — Requests from external applications

### Copy Responses

Use the copy button to quickly grab response payloads for debugging in other tools.

### Keep Server Running

The Server Explorer requires the server to be running. If endpoints show as disabled, start the server first.

---

## CI testing conventions

How CI runs the Osaurus test suite, and the hooks that exist to debug it when it goes sideways.

### Jobs

The CI workflow is pinned to the runner and Xcode version declared in [`.github/workflows/ci.yml`](../.github/workflows/ci.yml).

| Job | Purpose | Current Timeout |
| --- | --- | --- |
| `test-core` | `xcodebuild test` for `OsaurusCoreTests` through `osaurus.xcworkspace` | 45 minutes |
| `test-cli` | `swift test --package-path Packages/OsaurusCLI --parallel` | 10 minutes |
| `swiftlint` | SwiftLint over the repo | 10 minutes |
| `shellcheck` | ShellCheck for scripts | 10 minutes |

### Reproduce CI locally

The Makefile target `make ci-test` runs the same core `xcodebuild` path CI uses, pipes output through `xcbeautify`, and writes a result bundle:

```bash
brew install xcbeautify    # one-time
make ci-test
open build/Tests.xcresult  # full Xcode Test Navigator UI
```

Use narrower package tests while iterating, then use `make ci-test` before a risky PR or when chasing a CI-only failure.

### Long-running and integration tests

Tests that require external infrastructure (Apple Containerization, real GPU, network, model downloads, provider credentials, etc.) must:

1. **Be opt-in via an environment variable** - never run unconditionally in CI.
2. **Use Swift Testing's `.disabled(if:)` trait** at the suite level so they are reported as `Disabled` rather than silently passing. Pattern:

   ```swift
   private let isEnabled =
       ProcessInfo.processInfo.environment["OSAURUS_RUN_FOO_TESTS"] == "1"

   @Suite(.disabled(if: !isEnabled, "Set OSAURUS_RUN_FOO_TESTS=1 to run"))
   struct FooIntegrationTests { ... }
   ```

3. **Keep individual test bodies under ~250ms of `Task.sleep`** and prefer event-driven waits such as continuations or `AsyncStream`.

Currently env-gated:

| Env var | Suite | Notes |
| --- | --- | --- |
| `OSAURUS_RUN_SANDBOX_INTEGRATION_TESTS=1` | [`SandboxIntegrationTests`](../Packages/OsaurusCore/Tests/Sandbox/SandboxIntegrationTests.swift) | Boots a Linux VM and runs package-manager workloads. |

### CI cache controls

The `test-core` job caches SPM packages and `~/Library/Developer/Xcode/DerivedData`. DerivedData is keyed on Swift sources, manifests, resources, C headers/sources, the pinned Xcode version, and `CACHE_SALT`.

Two recovery levers exist when you suspect a bad cache:

1. **One-shot cold build**: trigger CI manually via the **Run workflow** button and check `clear_cache`. CI still restores the cache first so the save key is available, then wipes restored DerivedData before building. The SPM source cache is preserved.
2. **Permanent bust**: bump `CACHE_SALT` at the top of `.github/workflows/ci.yml` and merge. Every DerivedData and SPM cache key invalidates immediately.

DerivedData cache saves only on successful `main` runs. PRs can read caches but cannot overwrite them.

### Where the logs live

The full `xcodebuild` output is grouped by `xcbeautify`. On failure or cancellation CI also publishes:

- A GitHub step summary that distinguishes build failure, launch hang, zero-test-result hang, and ordinary failed test cases.
- The raw `Tests.xcresult` bundle as a downloadable artifact named `test-core-xcresult-N`, retained for 7 days.

Per-test timeouts are enabled with a 60-second default allowance and 120-second maximum allowance. This surfaces hung test names before the job wall-timeout whenever the test bundle launches far enough to report them.

### Deferred follow-up

Test wall-time is bounded by the build-from-scratch cost of the full `OsaurusCore` package. The biggest remaining lever is splitting `OsaurusCore` into focused targets so a foundation-only PR does not rebuild MLX, FluidAudio, Sparkle, VecturaKit, Containerization, SQLCipher, and SwiftUI-adjacent code.

The first split should isolate pure models, schemas, utility code, and low-dependency tests. One known boundary leak to clean before that split: `Models/Configuration/VLMDetection.swift` imports `MLXVLM` from the otherwise pure `Models/` tree.

See [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md) for the prioritized architecture workstream.

---

## Related Documentation

- [Inference Runtime](INFERENCE_RUNTIME.md) — Single MLX path through vmlx-swift-lm's BatchEngine, model leases, and the one max-batch-size knob
- [OpenAI API Guide](OpenAI_API_GUIDE.md) — API usage and examples
- [FEATURES.md](FEATURES.md) — Feature inventory
- [README](../README.md) — Quick start guide
