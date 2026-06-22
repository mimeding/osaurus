# Agent Channels

Agent Channels are provider-neutral communication connections that expose the
same agent actions across Discord, Slack, Telegram, and custom channel
definitions.

## Standard Actions

- `diagnostics`
- `list_spaces`
- `list_rooms`
- `read_messages`
- `search_messages`
- `draft_message`
- `send_message`
- `reply_thread`

The model-facing tools use these standard verbs through `agent_channel_*`
tools. Provider-specific adapters translate the standard action into the
provider API. Discord is the first executable adapter.

## Configuration

Non-secret channel definitions live in `agent-channels.json`. Secrets should be
stored separately in Keychain and referenced by name.

The connection center implementation can create, edit, delete, export, import,
and diagnose JSON-backed channel definitions, but the management entry remains
hidden while Agent Channels are still WIP. This keeps unfinished Discord/channel
settings out of the normal app surface while preserving the reviewable
configuration foundation.

```json
{
  "schemaVersion": 1,
  "connections": [
    {
      "id": "ops-webhook",
      "name": "Ops Webhook",
      "kind": "custom_http",
      "enabled": true,
      "supportedActions": ["diagnostics", "send_message"],
      "spaceAllowlist": ["ops"],
      "readRoomAllowlist": [],
      "writeRoomAllowlist": ["alerts"],
      "writeEnabled": true,
      "defaultReadLimit": 25,
      "secrets": [
        { "name": "bearer", "keychainId": "ops_webhook_token" }
      ],
      "customHTTP": {
        "baseURL": "https://hooks.example.test",
        "actions": {
          "send_message": {
            "method": "POST",
            "path": "/rooms/{room_id}/messages",
            "headers": {
              "Authorization": "Bearer ${secret:bearer}"
            },
            "bodyTemplate": "{\"text\":\"${content}\"}"
          }
        }
      }
    }
  ]
}
```

Custom HTTP execution is intentionally not enabled until the request templating,
credential substitution, response mapping, and security review are implemented.
Until then, JSON custom channels can be loaded and diagnosed, while executable
actions are provided by native adapters such as Discord.

## Connection Center Validation

The connection center validates channel definitions before saving:

- `discord` is reserved for the native Discord adapter.
- Custom HTTP connections require an HTTP or HTTPS base URL.
- Custom action names must match supported standard actions.
- HTTP action paths must start with `/`.
- Header/query fields and secret references reject line breaks.
- Secret references store only `name=keychain-id` pointers, not raw credentials.

## Discord Connection

Discord is the first native Agent Channel connection. It is addressed through
`connection_id: "discord"` on the `agent_channel_*` tools rather than through a
separate Discord-specific model-facing tool set.

The Discord bot token is stored in Keychain. The JSON configuration stores only
non-secret IDs and policy:

- `configuredGuildIds` limits which servers can be inspected.
- `readableChannelIds` limits rooms that `read_messages`, `read_thread`, and
  `search_messages` can read.
- `writableChannelIds` limits rooms that `draft_message`, `send_message`, and
  `reply_thread` can target.
- `writeEnabled` must be true, and send/reply actions still require
  `confirm_send: true`.

## Message State And Dedupe

Agent Channels keep provider-neutral message state in
`agent-channels/messages.sqlite`. The store is opened through the same
SQLCipher-aware storage stack as chat history, memory, and tools, and is
included in storage export/key rotation.

The schema is intentionally provider-neutral:

- `channel_messages` stores inbound and outbound message snapshots keyed by
  `connection_id + room_id + provider_message_id`.
- `channel_seen_events` stores receive-side event ids keyed by
  `connection_id + provider_event_id`.
- `channel_receive_cursors` stores optional per-room cursors for polling or
  relay catch-up.

Native adapters should write message snapshots whenever they read or send a
message. Discord does this for `read_messages`, `search_messages`, and
`send_message`, so repeated reads cannot duplicate the same provider message in
the local store. The store keeps only the newest 1,000 message snapshots per
connection/room pair so busy channels do not grow the database without bound.

Relay or webhook receivers should follow the same sequence used by the Telegram
plugin pattern:

1. Verify the provider secret/signature before parsing user-visible content.
2. Build a stable provider event id, such as a Telegram update id, Discord
   gateway sequence/event id, or Slack event id.
3. Call `markEventSeen(connectionId:providerEventId:)` before dispatch. A
   `false` result means the event was already processed and should be
   acknowledged without another agent dispatch.
4. Store the normalized message snapshot with `recordMessages(_:)`.
5. Update the room cursor when the provider exposes one.

This PR does not add a live Discord receive relay. It adds the durable message
and duplicate-filtering foundation that a relay, webhook receiver, Slack
adapter, or Telegram adapter can share.

## Async Channel Substrate

Async inbound channels should build on the shared substrate in
`Models/AgentChannel` and `Services/AgentChannel` before dispatching an agent
turn. The substrate captures the reusable contracts from Telegram-style chat
bridges and email-style resend bridges:

- Verify the webhook or source first with either a shared-secret header or an
  HMAC-SHA256 body signature. Verification failures are typed and never include
  the configured secret in diagnostics.
- Evaluate sender policy with blocklists, allowlists, default disposition, and
  bot-sender handling before parsing user-visible content into a prompt.
- Create an idempotency key from the connection plus the provider event id and
  register it through the Agent Channel message store. Duplicates should be
  acknowledged without creating another dispatch.
- Derive the chat session partition from `(agent_id, connection_id,
  provider_conversation_id, provider_thread_id, salt)` using a hash-backed
  external session key. Provider routing ids stay out of model-visible prompt
  text and sidebar grouping keys.
- Mint an opaque reply token for each inbound turn. The token is what the agent
  sees; the token registry holds the provider conversation/thread/reply address,
  agent scope, session id, task id, issue time, and expiry. The registry prunes
  expired bindings on issue/resolve activity and exposes explicit pruning for
  adapter maintenance jobs.
- Track artifact forwarding with typed statuses (`queued`, `forwarded`,
  `skipped`, `blocked`, `failed`) so adapters can report whether shared
  artifacts were actually delivered to the remote channel.
- Emit bounded in-memory audit events with typed status/failure values and
  hashed audit keys rather than raw provider event or routing ids. Adapters
  that need durable audit evidence should drain these events into their own
  channel store or support artifact.

The substrate is not a provider implementation. Discord, Telegram, Slack,
email, and custom adapters still own provider payload parsing, provider API
calls, rate-limit behavior, and channel-specific formatting. They should share
these contracts so retries, reply routing, session partitioning, and audit
event semantics behave consistently across channel families.
