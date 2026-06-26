# Durable Agent Task Board

PR-C adds a durable local task-board foundation for future spawned and remote
agent orchestration. It is intentionally limited to storage, service APIs, and
tests.

## Scope

Included:

- SQLCipher-backed local SQLite store at `~/.osaurus/agent-tasks/board.sqlite`.
- `AgentTaskBoardService` facade for task CRUD, dependencies, claiming, lease
  renewal, completion, blocking, archiving, event history, run history, and
  crash recovery.
- Tables for `tasks`, `task_events`, `task_runs`, and `task_links`.
- DAG dependency validation with cycle rejection.
- Atomic claim semantics with lease TTLs and stale reclaim.

Not included:

- Team protocol.
- Channel inboxes or Agent Channel UI.
- Remote command center.
- Remote agent execution.
- UI-heavy workflows.

## Threat Model

The board is encrypted at rest with the existing Osaurus storage key and the
vendored SQLCipher opener. This protects against offline theft of the database
file, including direct reads of task titles, details, metadata, events, run
records, and dependency links.

This does not protect against a compromised Osaurus process, malicious code
running with the user's privileges while the process has the storage key in
memory, screen capture of rendered UI, or data intentionally exported through a
future orchestration protocol.

The task-board database is marked as `alwaysEncrypted` in the storage catalog.
It remains SQLCipher-encrypted even when the rest of local storage follows the
global plaintext/FileVault posture. The catalog still includes it for storage
key rotation and plaintext backup/export flows.

## Schema

`tasks` is the current task state:

- Status values: `triage`, `todo`, `scheduled`, `ready`, `running`, `blocked`,
  `review`, `done`, `archived`.
- Claim state lives on the task row as `active_run_id`, `lease_owner`, and
  `lease_expires_at`.
- `archived` is terminal.

`task_runs` records claim attempts and their outcome:

- A claim inserts a `running` run.
- Completion marks the active run `completed`.
- Blocking marks the active run `blocked`.
- Lease expiry marks the old active run `expired`.
- Archiving a running task marks the active run `abandoned`.

`task_events` is append-only history for user-visible mutations:

- `create`
- `update`
- `claim`
- `complete`
- `block`
- `archive`

`task_links` stores dependencies:

- `task_id` depends on `depends_on_task_id`.
- `addDependency` rejects self-dependencies and transitive cycles.
- A task is claimable only when all dependencies are `done`.

## Claim And Recovery Semantics

Claims use `BEGIN IMMEDIATE` and update the task, insert the run row, and append
the claim event in one transaction. A task can only be claimed when it is:

- `ready`, or
- `scheduled` with `scheduled_at <= now`.

Running tasks are not claimable until their lease expires. Every claim path
first expires stale leases in the same transaction. Expiring a lease marks the
old run `expired`, clears the task lease fields, returns the task to `ready`,
and appends an `update` event. A later worker may then claim it with a new run
row.

`recoverExpiredLeases(asOf:)` exposes the same recovery step for startup or
crash-style cleanup. It is safe to call repeatedly.
