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
