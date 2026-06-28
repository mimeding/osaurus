//
//  AgentTaskBoardStore.swift
//  osaurus
//
//  Durable local task-board storage for spawned/remote-agent orchestration.
//  The on-disk database is always opened through SQLCipher with the shared
//  Osaurus storage key. In-memory test stores are plaintext by design.
//

import CryptoKit
import Foundation
import OsaurusSQLCipher

public enum AgentTaskBoardError: Error, LocalizedError, Equatable {
    case failedToOpen(String)
    case failedToExecute(String)
    case failedToPrepare(String)
    case migrationFailed(String)
    case notOpen
    case notFound(UUID)
    case invalidInput(String)
    case invalidTransition(from: AgentTaskStatus, to: AgentTaskStatus)
    case dependencyCycle(taskId: UUID, dependsOnTaskId: UUID)

    public var errorDescription: String? {
        switch self {
        case .failedToOpen(let message):
            return "Failed to open agent task board: \(message)"
        case .failedToExecute(let message):
            return "Failed to execute agent task board query: \(message)"
        case .failedToPrepare(let message):
            return "Failed to prepare agent task board query: \(message)"
        case .migrationFailed(let message):
            return "Agent task board migration failed: \(message)"
        case .notOpen:
            return "Agent task board is not open"
        case .notFound(let id):
            return "Agent task not found: \(id.uuidString)"
        case .invalidInput(let message):
            return "Invalid agent task input: \(message)"
        case .invalidTransition(let from, let to):
            return "Invalid agent task status transition: \(from.rawValue) -> \(to.rawValue)"
        case .dependencyCycle(let taskId, let dependsOnTaskId):
            return
                "Dependency would create a cycle: \(taskId.uuidString) depends on \(dependsOnTaskId.uuidString)"
        }
    }
}

public final class AgentTaskBoardStore: @unchecked Sendable {
    public static let shared = AgentTaskBoardStore()

    private static let latestSchemaVersion = 1
    private static let sqliteTransient = unsafeBitCast(
        OpaquePointer(bitPattern: -1),
        to: sqlite3_destructor_type.self
    )

    private let queue = DispatchQueue(label: "ai.osaurus.agent-tasks.board-store")
    private var db: OpaquePointer?
    private var registeredMaintenanceHandle = false

    public init() {}

    deinit { close() }

    // MARK: - Lifecycle

    public func open() throws {
        StorageMutationGate.blockingAwaitNotMutating()
        try queue.sync {
            guard db == nil else {
                registerMaintenanceHandleIfNeededLocked()
                return
            }
            OsaurusPaths.ensureExistsSilent(OsaurusPaths.agentTasks())
            do {
                db = try EncryptedSQLiteOpener.open(
                    path: OsaurusPaths.agentTaskBoardDatabaseFile().path,
                    key: StorageKeyManager.shared.currentKey()
                )
                try applyConnectionPragmas()
                try runMigrations()
            } catch let error as EncryptedSQLiteError {
                throw AgentTaskBoardError.failedToOpen(error.localizedDescription)
            } catch {
                throw AgentTaskBoardError.failedToOpen(error.localizedDescription)
            }
            registerMaintenanceHandleIfNeededLocked()
        }
    }

    /// Test seam for deterministic on-disk stores with an inline key, and
    /// plaintext `:memory:` stores. Production callers should use `open()`.
    func openForTesting(path: String = ":memory:", key: SymmetricKey? = nil) throws {
        try queue.sync {
            guard db == nil else { return }
            if path != ":memory:" {
                let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            db = try EncryptedSQLiteOpener.open(
                path: path,
                key: key,
                applyPerfPragmas: path != ":memory:"
            )
            try applyConnectionPragmas()
            try runMigrations()
        }
    }

    public func close() {
        queue.sync {
            if registeredMaintenanceHandle {
                OsaurusDatabaseHandle.deregister(name: "agent-task-board")
                registeredMaintenanceHandle = false
            }
            guard let connection = db else { return }
            try? executeRaw("PRAGMA optimize")
            sqlite3_close(connection)
            db = nil
        }
    }

    public var isOpen: Bool { queue.sync { db != nil } }

    private lazy var maintenanceHandle = OsaurusDatabaseHandle(
        name: "agent-task-board",
        exec: { [weak self] sql in
            self?.queue.sync {
                guard self?.db != nil else { return }
                try? self?.executeRaw(sql)
            }
        },
        closer: { [weak self] in self?.close() },
        reopener: { [weak self] in try? self?.open() }
    )

    private func registerMaintenanceHandleIfNeededLocked() {
        guard !registeredMaintenanceHandle else { return }
        OsaurusDatabaseHandle.register(maintenanceHandle)
        registeredMaintenanceHandle = true
    }

    // MARK: - Schema

    public func schemaVersionForTesting() throws -> Int {
        try queue.sync { try getSchemaVersion() }
    }

    private func runMigrations() throws {
        let current = try getSchemaVersion()
        guard current <= Self.latestSchemaVersion else {
            throw AgentTaskBoardError.migrationFailed(
                "on-disk schema v\(current) is newer than supported v\(Self.latestSchemaVersion)"
            )
        }
        do {
            if current < 1 { try migrateToV1() }
        } catch {
            throw AgentTaskBoardError.migrationFailed(error.localizedDescription)
        }
    }

    private func migrateToV1() throws {
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS tasks (
                    id               TEXT PRIMARY KEY,
                    title            TEXT NOT NULL,
                    details          TEXT,
                    status           TEXT NOT NULL,
                    priority         INTEGER NOT NULL DEFAULT 0,
                    created_at       REAL NOT NULL,
                    updated_at       REAL NOT NULL,
                    scheduled_at     REAL,
                    blocked_reason   TEXT,
                    metadata_json    TEXT,
                    active_run_id    TEXT,
                    lease_owner      TEXT,
                    lease_expires_at REAL,
                    archived_at      REAL,
                    CHECK (
                        status IN (
                            'triage', 'todo', 'scheduled', 'ready',
                            'running', 'blocked', 'review', 'done', 'archived'
                        )
                    )
                )
            """
        )
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status)")
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_tasks_claimable ON tasks(status, scheduled_at, priority)")
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_tasks_lease ON tasks(status, lease_expires_at)")

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS task_runs (
                    id                TEXT PRIMARY KEY,
                    task_id           TEXT NOT NULL,
                    worker_id         TEXT NOT NULL,
                    status            TEXT NOT NULL,
                    claimed_at        REAL NOT NULL,
                    lease_expires_at  REAL NOT NULL,
                    last_heartbeat_at REAL NOT NULL,
                    completed_at      REAL,
                    error             TEXT,
                    CHECK (status IN ('running', 'completed', 'blocked', 'expired', 'abandoned')),
                    FOREIGN KEY(task_id) REFERENCES tasks(id) ON DELETE CASCADE
                )
            """
        )
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_task_runs_task ON task_runs(task_id, claimed_at DESC)")
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_task_runs_status ON task_runs(status, lease_expires_at)")

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS task_events (
                    id            TEXT PRIMARY KEY,
                    task_id       TEXT NOT NULL,
                    kind          TEXT NOT NULL,
                    created_at    REAL NOT NULL,
                    worker_id     TEXT,
                    run_id        TEXT,
                    from_status   TEXT,
                    to_status     TEXT,
                    message       TEXT,
                    payload_json  TEXT,
                    CHECK (kind IN ('create', 'update', 'claim', 'complete', 'block', 'archive')),
                    FOREIGN KEY(task_id) REFERENCES tasks(id) ON DELETE CASCADE,
                    FOREIGN KEY(run_id) REFERENCES task_runs(id) ON DELETE SET NULL
                )
            """
        )
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_task_events_task ON task_events(task_id, created_at ASC)")

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS task_links (
                    task_id            TEXT NOT NULL,
                    depends_on_task_id TEXT NOT NULL,
                    kind               TEXT NOT NULL DEFAULT 'depends_on',
                    created_at         REAL NOT NULL,
                    PRIMARY KEY(task_id, depends_on_task_id, kind),
                    CHECK(task_id != depends_on_task_id),
                    CHECK(kind IN ('depends_on')),
                    FOREIGN KEY(task_id) REFERENCES tasks(id) ON DELETE CASCADE,
                    FOREIGN KEY(depends_on_task_id) REFERENCES tasks(id) ON DELETE CASCADE
                )
            """
        )
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_task_links_depends ON task_links(depends_on_task_id)")

        try setSchemaVersion(1)
    }

    // MARK: - CRUD

    @discardableResult
    public func createTask(
        _ request: AgentTaskCreateRequest,
        now: Date = Date()
    ) throws -> AgentTask {
        try Self.validateTitle(request.title)
        guard Self.validInitialStatuses.contains(request.status) else {
            throw AgentTaskBoardError.invalidInput(
                "\(request.status.rawValue) is not a valid initial task status"
            )
        }
        if request.status == .scheduled, request.scheduledAt == nil {
            throw AgentTaskBoardError.invalidInput("scheduled tasks require scheduledAt")
        }

        return try inImmediateTransaction {
            let task = AgentTask(
                id: request.id ?? UUID(),
                title: request.title,
                details: request.details,
                status: request.status,
                priority: request.priority,
                createdAt: now,
                updatedAt: now,
                scheduledAt: request.scheduledAt,
                metadataJSON: request.metadataJSON
            )
            try insertTaskLocked(task)
            try insertEventLocked(
                AgentTaskEvent(
                    taskId: task.id,
                    kind: .create,
                    createdAt: now,
                    toStatus: task.status
                )
            )
            return task
        }
    }

    public func task(id: UUID) throws -> AgentTask? {
        try queue.sync { try readTaskLocked(id: id) }
    }

    public func listTasks(statuses: [AgentTaskStatus]? = nil) throws -> [AgentTask] {
        try queue.sync {
            let columns = Self.taskColumns
            var sql = "SELECT \(columns) FROM tasks"
            if let statuses, !statuses.isEmpty {
                let placeholders = statuses.enumerated().map { "?\($0.offset + 1)" }.joined(separator: ", ")
                sql += " WHERE status IN (\(placeholders))"
            }
            sql += " ORDER BY priority DESC, created_at ASC"

            var tasks: [AgentTask] = []
            try prepareAndStep(sql) { stmt in
                if let statuses {
                    for (index, status) in statuses.enumerated() {
                        Self.bindText(stmt, index: index + 1, value: status.rawValue)
                    }
                }
            } process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    tasks.append(Self.readTask(stmt))
                }
            }
            return tasks
        }
    }

    @discardableResult
    public func updateTask(
        id: UUID,
        update: AgentTaskUpdate,
        now: Date = Date(),
        message: String? = nil
    ) throws -> AgentTask {
        try inImmediateTransaction {
            var task = try requireTaskLocked(id: id)
            guard task.status != .archived else {
                throw AgentTaskBoardError.invalidTransition(from: .archived, to: update.status ?? .archived)
            }
            let fromStatus = task.status
            var clearedRunId: UUID?

            if let title = update.title {
                try Self.validateTitle(title)
                task.title = title
            }
            if update.details != nil { task.details = update.details }
            if let priority = update.priority { task.priority = priority }
            if update.clearScheduledAt {
                task.scheduledAt = nil
            } else if let scheduledAt = update.scheduledAt {
                task.scheduledAt = scheduledAt
            }
            if update.clearBlockedReason {
                task.blockedReason = nil
            } else if update.blockedReason != nil {
                task.blockedReason = update.blockedReason
            }
            if update.clearMetadataJSON {
                task.metadataJSON = nil
            } else if update.metadataJSON != nil {
                task.metadataJSON = update.metadataJSON
            }
            if let next = update.status {
                guard ![.running, .blocked, .done, .archived].contains(next) else {
                    throw AgentTaskBoardError.invalidInput(
                        "\(next.rawValue) status must be reached through the dedicated task-board API"
                    )
                }
                guard task.status.canTransition(to: next) else {
                    throw AgentTaskBoardError.invalidTransition(from: task.status, to: next)
                }
                if next == .scheduled, task.scheduledAt == nil {
                    throw AgentTaskBoardError.invalidInput("scheduled tasks require scheduledAt")
                }
                if task.status == .running, [.ready, .review].contains(next) {
                    clearedRunId = try finishActiveRunForManualTransitionLocked(
                        task: &task,
                        to: next,
                        now: now
                    )
                } else if [.ready, .review].contains(next), Self.hasActiveRunOrLease(task) {
                    throw AgentTaskBoardError.invalidInput(
                        "cannot move task with an active run or lease to \(next.rawValue)"
                    )
                }
                task.status = next
                if next != .blocked { task.blockedReason = nil }
                if next != .archived { task.archivedAt = nil }
            }
            task.updatedAt = now
            if task.status == .archived, task.archivedAt == nil {
                task.archivedAt = now
            }
            if task.status == .scheduled, task.scheduledAt == nil {
                throw AgentTaskBoardError.invalidInput("scheduled tasks require scheduledAt")
            }

            try updateTaskLocked(task)
            try insertEventLocked(
                AgentTaskEvent(
                    taskId: task.id,
                    kind: .update,
                    createdAt: now,
                    runId: clearedRunId,
                    fromStatus: fromStatus,
                    toStatus: task.status,
                    message: message
                )
            )
            return task
        }
    }

    // MARK: - Dependencies

    @discardableResult
    public func addDependency(
        taskId: UUID,
        dependsOnTaskId: UUID,
        now: Date = Date()
    ) throws -> AgentTaskLink {
        try inImmediateTransaction {
            _ = try requireTaskLocked(id: taskId)
            _ = try requireTaskLocked(id: dependsOnTaskId)
            guard taskId != dependsOnTaskId else {
                throw AgentTaskBoardError.dependencyCycle(taskId: taskId, dependsOnTaskId: dependsOnTaskId)
            }
            if try dependencyWouldCreateCycleLocked(taskId: taskId, dependsOnTaskId: dependsOnTaskId) {
                throw AgentTaskBoardError.dependencyCycle(taskId: taskId, dependsOnTaskId: dependsOnTaskId)
            }

            let link = AgentTaskLink(taskId: taskId, dependsOnTaskId: dependsOnTaskId, createdAt: now)
            try prepareAndStep(
                """
                    INSERT OR IGNORE INTO task_links
                        (task_id, depends_on_task_id, kind, created_at)
                    VALUES (?1, ?2, ?3, ?4)
                """
            ) { stmt in
                Self.bindText(stmt, index: 1, value: taskId.uuidString)
                Self.bindText(stmt, index: 2, value: dependsOnTaskId.uuidString)
                Self.bindText(stmt, index: 3, value: AgentTaskLinkKind.dependsOn.rawValue)
                Self.bindDate(stmt, index: 4, value: now)
            } process: { stmt in
                try Self.requireDone(stmt, connection: db, context: "addDependency")
            }
            try insertEventLocked(
                AgentTaskEvent(
                    taskId: taskId,
                    kind: .update,
                    createdAt: now,
                    message: "dependency added",
                    payloadJSON: #"{"depends_on":"\#(dependsOnTaskId.uuidString)"}"#
                )
            )
            return link
        }
    }

    public func dependencies(taskId: UUID) throws -> [AgentTaskLink] {
        try queue.sync {
            var links: [AgentTaskLink] = []
            try prepareAndStep(
                """
                    SELECT task_id, depends_on_task_id, kind, created_at
                    FROM task_links
                    WHERE task_id = ?1
                    ORDER BY created_at ASC
                """
            ) { stmt in
                Self.bindText(stmt, index: 1, value: taskId.uuidString)
            } process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let link = Self.readLink(stmt) {
                        links.append(link)
                    }
                }
            }
            return links
        }
    }

    public func removeDependency(
        taskId: UUID,
        dependsOnTaskId: UUID,
        now: Date = Date()
    ) throws {
        try inImmediateTransaction {
            try prepareAndStep(
                """
                    DELETE FROM task_links
                    WHERE task_id = ?1 AND depends_on_task_id = ?2 AND kind = 'depends_on'
                """
            ) { stmt in
                Self.bindText(stmt, index: 1, value: taskId.uuidString)
                Self.bindText(stmt, index: 2, value: dependsOnTaskId.uuidString)
            } process: { stmt in
                try Self.requireDone(stmt, connection: db, context: "removeDependency")
            }
            try insertEventLocked(
                AgentTaskEvent(
                    taskId: taskId,
                    kind: .update,
                    createdAt: now,
                    message: "dependency removed",
                    payloadJSON: #"{"depends_on_removed":"\#(dependsOnTaskId.uuidString)"}"#
                )
            )
        }
    }

    // MARK: - Claiming and leases

    public func claimTask(
        id: UUID,
        workerId: String,
        leaseTTL: TimeInterval,
        now: Date = Date()
    ) throws -> AgentTaskClaim? {
        try Self.validateWorker(workerId)
        try Self.validateLeaseTTL(leaseTTL)
        return try inImmediateTransaction {
            _ = try expireLeasesLocked(asOf: now)
            return try claimTaskLocked(id: id, workerId: workerId, leaseTTL: leaseTTL, now: now)
        }
    }

    public func claimNext(
        workerId: String,
        leaseTTL: TimeInterval,
        now: Date = Date()
    ) throws -> AgentTaskClaim? {
        try Self.validateWorker(workerId)
        try Self.validateLeaseTTL(leaseTTL)
        return try inImmediateTransaction {
            _ = try expireLeasesLocked(asOf: now)
            guard let candidate = try nextClaimableTaskLocked(asOf: now) else { return nil }
            return try claimTaskLocked(id: candidate.id, workerId: workerId, leaseTTL: leaseTTL, now: now)
        }
    }

    public func renewLease(
        taskId: UUID,
        runId: UUID,
        workerId: String,
        leaseTTL: TimeInterval,
        now: Date = Date()
    ) throws -> AgentTaskRun? {
        try Self.validateWorker(workerId)
        try Self.validateLeaseTTL(leaseTTL)
        return try inImmediateTransaction {
            guard var task = try readTaskLocked(id: taskId),
                task.status == .running,
                task.activeRunId == runId,
                task.leaseOwner == workerId,
                let leaseExpiresAt = task.leaseExpiresAt,
                leaseExpiresAt > now
            else {
                return nil
            }

            let newExpiry = now.addingTimeInterval(leaseTTL)
            task.leaseExpiresAt = newExpiry
            task.updatedAt = now
            try updateTaskLocked(task)

            try prepareAndStep(
                """
                    UPDATE task_runs
                    SET lease_expires_at = ?2,
                        last_heartbeat_at = ?3
                    WHERE id = ?1 AND status = 'running'
                """
            ) { stmt in
                Self.bindText(stmt, index: 1, value: runId.uuidString)
                Self.bindDate(stmt, index: 2, value: newExpiry)
                Self.bindDate(stmt, index: 3, value: now)
            } process: { stmt in
                try Self.requireDone(stmt, connection: db, context: "renewLease")
            }
            return try readRunLocked(id: runId)
        }
    }

    @discardableResult
    public func recoverExpiredLeases(asOf now: Date = Date()) throws -> Int {
        try inImmediateTransaction {
            try expireLeasesLocked(asOf: now)
        }
    }

    // MARK: - Terminal operations

    @discardableResult
    public func completeTask(
        id: UUID,
        runId: UUID? = nil,
        workerId: String? = nil,
        now: Date = Date(),
        message: String? = nil
    ) throws -> AgentTask {
        if let workerId { try Self.validateWorker(workerId) }
        return try inImmediateTransaction {
            var task = try requireTaskLocked(id: id)
            let fromStatus = task.status
            let runForEvent = runId ?? task.activeRunId
            guard task.status.canTransition(to: .done) else {
                throw AgentTaskBoardError.invalidTransition(from: task.status, to: .done)
            }
            try validateActiveRunIfPresentLocked(task: task, runId: runId, workerId: workerId, now: now)

            if let activeRunId = task.activeRunId {
                try finishRunLocked(
                    id: activeRunId,
                    status: .completed,
                    completedAt: now,
                    error: nil
                )
            }
            task.status = .done
            task.updatedAt = now
            task.activeRunId = nil
            task.leaseOwner = nil
            task.leaseExpiresAt = nil
            task.blockedReason = nil
            try updateTaskLocked(task)
            try insertEventLocked(
                AgentTaskEvent(
                    taskId: task.id,
                    kind: .complete,
                    createdAt: now,
                    workerId: workerId,
                    runId: runForEvent,
                    fromStatus: fromStatus,
                    toStatus: .done,
                    message: message
                )
            )
            return task
        }
    }

    @discardableResult
    public func blockTask(
        id: UUID,
        reason: String,
        runId: UUID? = nil,
        workerId: String? = nil,
        now: Date = Date()
    ) throws -> AgentTask {
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentTaskBoardError.invalidInput("block reason cannot be empty")
        }
        if let workerId { try Self.validateWorker(workerId) }
        return try inImmediateTransaction {
            var task = try requireTaskLocked(id: id)
            let fromStatus = task.status
            let runForEvent = runId ?? task.activeRunId
            guard task.status.canTransition(to: .blocked) else {
                throw AgentTaskBoardError.invalidTransition(from: task.status, to: .blocked)
            }
            try validateActiveRunIfPresentLocked(task: task, runId: runId, workerId: workerId, now: now)

            if let activeRunId = task.activeRunId {
                try finishRunLocked(
                    id: activeRunId,
                    status: .blocked,
                    completedAt: now,
                    error: reason
                )
            }
            task.status = .blocked
            task.updatedAt = now
            task.blockedReason = reason
            task.activeRunId = nil
            task.leaseOwner = nil
            task.leaseExpiresAt = nil
            try updateTaskLocked(task)
            try insertEventLocked(
                AgentTaskEvent(
                    taskId: task.id,
                    kind: .block,
                    createdAt: now,
                    workerId: workerId,
                    runId: runForEvent,
                    fromStatus: fromStatus,
                    toStatus: .blocked,
                    message: reason
                )
            )
            return task
        }
    }

    @discardableResult
    public func archiveTask(
        id: UUID,
        workerId: String? = nil,
        now: Date = Date(),
        message: String? = nil
    ) throws -> AgentTask {
        try inImmediateTransaction {
            var task = try requireTaskLocked(id: id)
            let fromStatus = task.status
            let runForEvent = task.activeRunId
            guard task.status.canTransition(to: .archived) else {
                throw AgentTaskBoardError.invalidTransition(from: task.status, to: .archived)
            }
            if let activeRunId = task.activeRunId {
                try finishRunLocked(
                    id: activeRunId,
                    status: .abandoned,
                    completedAt: now,
                    error: "task archived"
                )
            }
            task.status = .archived
            task.updatedAt = now
            task.archivedAt = now
            task.activeRunId = nil
            task.leaseOwner = nil
            task.leaseExpiresAt = nil
            try updateTaskLocked(task)
            try insertEventLocked(
                AgentTaskEvent(
                    taskId: task.id,
                    kind: .archive,
                    createdAt: now,
                    workerId: workerId,
                    runId: runForEvent,
                    fromStatus: fromStatus,
                    toStatus: .archived,
                    message: message
                )
            )
            return task
        }
    }

    // MARK: - History

    public func events(taskId: UUID) throws -> [AgentTaskEvent] {
        try queue.sync {
            var events: [AgentTaskEvent] = []
            try prepareAndStep(
                """
                    SELECT id, task_id, kind, created_at, worker_id, run_id,
                           from_status, to_status, message, payload_json
                    FROM task_events
                    WHERE task_id = ?1
                    ORDER BY created_at ASC
                """
            ) { stmt in
                Self.bindText(stmt, index: 1, value: taskId.uuidString)
            } process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let event = Self.readEvent(stmt) {
                        events.append(event)
                    }
                }
            }
            return events
        }
    }

    public func runs(taskId: UUID) throws -> [AgentTaskRun] {
        try queue.sync {
            var runs: [AgentTaskRun] = []
            try prepareAndStep(
                """
                    SELECT id, task_id, worker_id, status, claimed_at,
                           lease_expires_at, last_heartbeat_at, completed_at, error
                    FROM task_runs
                    WHERE task_id = ?1
                    ORDER BY claimed_at ASC
                """
            ) { stmt in
                Self.bindText(stmt, index: 1, value: taskId.uuidString)
            } process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let run = Self.readRun(stmt) {
                        runs.append(run)
                    }
                }
            }
            return runs
        }
    }

    func tableNamesForTesting() throws -> Set<String> {
        try queue.sync {
            var names = Set<String>()
            try prepareAndStep(
                "SELECT name FROM sqlite_master WHERE type = 'table'"
            ) { _ in } process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let raw = sqlite3_column_text(stmt, 0) {
                        names.insert(String(cString: raw))
                    }
                }
            }
            return names
        }
    }

    func deleteAllForTesting() throws {
        try inImmediateTransaction {
            try executeRaw("DELETE FROM task_links")
            try executeRaw("DELETE FROM task_events")
            try executeRaw("DELETE FROM task_runs")
            try executeRaw("DELETE FROM tasks")
        }
    }

    func setActiveRunForTesting(
        taskId: UUID,
        activeRunId: UUID?,
        leaseOwner: String? = nil,
        leaseExpiresAt: Date? = nil
    ) throws {
        try inImmediateTransaction {
            var task = try requireTaskLocked(id: taskId)
            task.activeRunId = activeRunId
            task.leaseOwner = leaseOwner
            task.leaseExpiresAt = leaseExpiresAt
            try updateTaskLocked(task)
        }
    }

    // MARK: - Claim internals

    private func claimTaskLocked(
        id: UUID,
        workerId: String,
        leaseTTL: TimeInterval,
        now: Date
    ) throws -> AgentTaskClaim? {
        let task = try requireTaskLocked(id: id)
        guard Self.isClaimable(task, asOf: now) else { return nil }
        guard try dependenciesSatisfiedLocked(taskId: id) else { return nil }

        let runId = UUID()
        let expires = now.addingTimeInterval(leaseTTL)
        let run = AgentTaskRun(
            id: runId,
            taskId: id,
            workerId: workerId,
            claimedAt: now,
            leaseExpiresAt: expires,
            lastHeartbeatAt: now
        )
        try insertRunLocked(run)

        var claimed = task
        claimed.status = .running
        claimed.updatedAt = now
        claimed.activeRunId = runId
        claimed.leaseOwner = workerId
        claimed.leaseExpiresAt = expires
        claimed.blockedReason = nil
        try updateTaskLocked(claimed)

        try insertEventLocked(
            AgentTaskEvent(
                taskId: id,
                kind: .claim,
                createdAt: now,
                workerId: workerId,
                runId: runId,
                fromStatus: task.status,
                toStatus: .running
            )
        )
        return AgentTaskClaim(task: claimed, run: run)
    }

    private func nextClaimableTaskLocked(asOf now: Date) throws -> AgentTask? {
        var task: AgentTask?
        try prepareAndStep(
            """
                SELECT \(Self.taskColumns)
                FROM tasks AS t
                WHERE (
                    t.status = 'ready'
                    OR (
                        t.status = 'scheduled'
                        AND t.scheduled_at IS NOT NULL
                        AND t.scheduled_at <= ?1
                    )
                )
                AND t.active_run_id IS NULL
                AND NOT EXISTS (
                    SELECT 1
                    FROM task_links AS l
                    JOIN tasks AS dep ON dep.id = l.depends_on_task_id
                    WHERE l.task_id = t.id
                      AND l.kind = 'depends_on'
                      AND dep.status != 'done'
                )
                ORDER BY t.priority DESC, COALESCE(t.scheduled_at, t.created_at) ASC, t.created_at ASC
                LIMIT 1
            """
        ) { stmt in
            Self.bindDate(stmt, index: 1, value: now)
        } process: { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                task = Self.readTask(stmt)
            }
        }
        return task
    }

    private func expireLeasesLocked(asOf now: Date) throws -> Int {
        var expired: [(taskId: UUID, runId: UUID?)] = []
        try prepareAndStep(
            """
                SELECT id, active_run_id
                FROM tasks
                WHERE status = 'running'
                  AND lease_expires_at IS NOT NULL
                  AND lease_expires_at <= ?1
            """
        ) { stmt in
            Self.bindDate(stmt, index: 1, value: now)
        } process: { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let taskId = Self.uuidColumn(stmt, 0) else { continue }
                expired.append((taskId, Self.uuidColumn(stmt, 1)))
            }
        }

        for item in expired {
            if let runId = item.runId {
                try finishRunLocked(
                    id: runId,
                    status: .expired,
                    completedAt: now,
                    error: "lease expired"
                )
            }
            var task = try requireTaskLocked(id: item.taskId)
            let fromStatus = task.status
            task.status = .ready
            task.updatedAt = now
            task.activeRunId = nil
            task.leaseOwner = nil
            task.leaseExpiresAt = nil
            task.blockedReason = nil
            try updateTaskLocked(task)
            try insertEventLocked(
                AgentTaskEvent(
                    taskId: item.taskId,
                    kind: .update,
                    createdAt: now,
                    runId: item.runId,
                    fromStatus: fromStatus,
                    toStatus: .ready,
                    message: "lease expired; task returned to ready"
                )
            )
        }
        return expired.count
    }

    private static func isClaimable(_ task: AgentTask, asOf now: Date) -> Bool {
        switch task.status {
        case .ready:
            return task.activeRunId == nil
        case .scheduled:
            guard let scheduledAt = task.scheduledAt else { return false }
            return scheduledAt <= now && task.activeRunId == nil
        default:
            return false
        }
    }

    private func dependenciesSatisfiedLocked(taskId: UUID) throws -> Bool {
        var count = 0
        try prepareAndStep(
            """
                SELECT COUNT(*)
                FROM task_links AS l
                JOIN tasks AS dep ON dep.id = l.depends_on_task_id
                WHERE l.task_id = ?1
                  AND l.kind = 'depends_on'
                  AND dep.status != 'done'
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: taskId.uuidString)
        } process: { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int(stmt, 0))
            }
        }
        return count == 0
    }

    private func validateActiveRunIfPresentLocked(
        task: AgentTask,
        runId: UUID?,
        workerId: String?,
        now: Date
    ) throws {
        guard let activeRunId = task.activeRunId else { return }
        if let runId, runId != activeRunId {
            throw AgentTaskBoardError.invalidInput(
                "run \(runId.uuidString) does not own task \(task.id.uuidString)"
            )
        }
        guard task.status == .running else { return }
        guard let leaseOwner = task.leaseOwner,
            let workerId,
            workerId == leaseOwner
        else {
            throw AgentTaskBoardError.invalidInput(
                "worker does not own the active lease for task \(task.id.uuidString)"
            )
        }
        if let leaseExpiresAt = task.leaseExpiresAt, leaseExpiresAt <= now {
            throw AgentTaskBoardError.invalidInput(
                "active lease for task \(task.id.uuidString) has expired"
            )
        }
    }

    private func finishActiveRunForManualTransitionLocked(
        task: inout AgentTask,
        to next: AgentTaskStatus,
        now: Date
    ) throws -> UUID? {
        let runId: UUID?
        if let activeRunId = task.activeRunId {
            runId = activeRunId
        } else {
            runId = try runningRunIdForTaskLocked(taskId: task.id)
        }
        guard let runId else {
            throw AgentTaskBoardError.invalidInput(
                "cannot move running task to \(next.rawValue) without an active run to finish"
            )
        }
        let runStatus: AgentTaskRunStatus = next == .review ? .completed : .abandoned
        let error = next == .review ? nil : "task returned to ready"
        try finishRunLocked(
            id: runId,
            status: runStatus,
            completedAt: now,
            error: error
        )
        task.activeRunId = nil
        task.leaseOwner = nil
        task.leaseExpiresAt = nil
        return runId
    }

    private func runningRunIdForTaskLocked(taskId: UUID) throws -> UUID? {
        var runId: UUID?
        try prepareAndStep(
            """
                SELECT id
                FROM task_runs
                WHERE task_id = ?1 AND status = 'running'
                ORDER BY claimed_at DESC
                LIMIT 1
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: taskId.uuidString)
        } process: { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                runId = Self.uuidColumn(stmt, 0)
            }
        }
        return runId
    }

    private static func hasActiveRunOrLease(_ task: AgentTask) -> Bool {
        task.activeRunId != nil || task.leaseOwner != nil || task.leaseExpiresAt != nil
    }

    // MARK: - Dependency internals

    private func dependencyWouldCreateCycleLocked(
        taskId: UUID,
        dependsOnTaskId: UUID
    ) throws -> Bool {
        var found = false
        try prepareAndStep(
            """
                WITH RECURSIVE dependency_chain(id) AS (
                    SELECT ?1
                    UNION
                    SELECT l.depends_on_task_id
                    FROM task_links AS l
                    JOIN dependency_chain AS c ON l.task_id = c.id
                    WHERE l.kind = 'depends_on'
                )
                SELECT 1 FROM dependency_chain WHERE id = ?2 LIMIT 1
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: dependsOnTaskId.uuidString)
            Self.bindText(stmt, index: 2, value: taskId.uuidString)
        } process: { stmt in
            found = sqlite3_step(stmt) == SQLITE_ROW
        }
        return found
    }

    // MARK: - Row writers

    private func insertTaskLocked(_ task: AgentTask) throws {
        try prepareAndStep(
            """
                INSERT INTO tasks (
                    id, title, details, status, priority, created_at, updated_at,
                    scheduled_at, blocked_reason, metadata_json, active_run_id,
                    lease_owner, lease_expires_at, archived_at
                )
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
            """
        ) { stmt in
            Self.bindTask(task, stmt: stmt)
        } process: { stmt in
            try Self.requireDone(stmt, connection: db, context: "insertTask")
        }
    }

    private func updateTaskLocked(_ task: AgentTask) throws {
        try prepareAndStep(
            """
                UPDATE tasks SET
                    title = ?2,
                    details = ?3,
                    status = ?4,
                    priority = ?5,
                    created_at = ?6,
                    updated_at = ?7,
                    scheduled_at = ?8,
                    blocked_reason = ?9,
                    metadata_json = ?10,
                    active_run_id = ?11,
                    lease_owner = ?12,
                    lease_expires_at = ?13,
                    archived_at = ?14
                WHERE id = ?1
            """
        ) { stmt in
            Self.bindTask(task, stmt: stmt)
        } process: { stmt in
            try Self.requireDone(stmt, connection: db, context: "updateTask")
        }
    }

    private func insertRunLocked(_ run: AgentTaskRun) throws {
        try prepareAndStep(
            """
                INSERT INTO task_runs (
                    id, task_id, worker_id, status, claimed_at, lease_expires_at,
                    last_heartbeat_at, completed_at, error
                )
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: run.id.uuidString)
            Self.bindText(stmt, index: 2, value: run.taskId.uuidString)
            Self.bindText(stmt, index: 3, value: run.workerId)
            Self.bindText(stmt, index: 4, value: run.status.rawValue)
            Self.bindDate(stmt, index: 5, value: run.claimedAt)
            Self.bindDate(stmt, index: 6, value: run.leaseExpiresAt)
            Self.bindDate(stmt, index: 7, value: run.lastHeartbeatAt)
            Self.bindOptionalDate(stmt, index: 8, value: run.completedAt)
            Self.bindText(stmt, index: 9, value: run.error)
        } process: { stmt in
            try Self.requireDone(stmt, connection: db, context: "insertRun")
        }
    }

    private func finishRunLocked(
        id: UUID,
        status: AgentTaskRunStatus,
        completedAt: Date,
        error: String?
    ) throws {
        try prepareAndStep(
            """
                UPDATE task_runs
                SET status = ?2,
                    completed_at = ?3,
                    error = COALESCE(?4, error)
                WHERE id = ?1 AND status = 'running'
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: id.uuidString)
            Self.bindText(stmt, index: 2, value: status.rawValue)
            Self.bindDate(stmt, index: 3, value: completedAt)
            Self.bindText(stmt, index: 4, value: error)
        } process: { stmt in
            try Self.requireDone(stmt, connection: db, context: "finishRun")
        }
    }

    private func insertEventLocked(_ event: AgentTaskEvent) throws {
        try prepareAndStep(
            """
                INSERT INTO task_events (
                    id, task_id, kind, created_at, worker_id, run_id,
                    from_status, to_status, message, payload_json
                )
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: event.id.uuidString)
            Self.bindText(stmt, index: 2, value: event.taskId.uuidString)
            Self.bindText(stmt, index: 3, value: event.kind.rawValue)
            Self.bindDate(stmt, index: 4, value: event.createdAt)
            Self.bindText(stmt, index: 5, value: event.workerId)
            Self.bindText(stmt, index: 6, value: event.runId?.uuidString)
            Self.bindText(stmt, index: 7, value: event.fromStatus?.rawValue)
            Self.bindText(stmt, index: 8, value: event.toStatus?.rawValue)
            Self.bindText(stmt, index: 9, value: event.message)
            Self.bindText(stmt, index: 10, value: event.payloadJSON)
        } process: { stmt in
            try Self.requireDone(stmt, connection: db, context: "insertEvent")
        }
    }

    // MARK: - Row readers

    private static let taskColumns =
        """
            id, title, details, status, priority, created_at, updated_at,
            scheduled_at, blocked_reason, metadata_json, active_run_id,
            lease_owner, lease_expires_at, archived_at
        """

    private func requireTaskLocked(id: UUID) throws -> AgentTask {
        guard let task = try readTaskLocked(id: id) else {
            throw AgentTaskBoardError.notFound(id)
        }
        return task
    }

    private func readTaskLocked(id: UUID) throws -> AgentTask? {
        var task: AgentTask?
        try prepareAndStep(
            "SELECT \(Self.taskColumns) FROM tasks WHERE id = ?1"
        ) { stmt in
            Self.bindText(stmt, index: 1, value: id.uuidString)
        } process: { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                task = Self.readTask(stmt)
            }
        }
        return task
    }

    private func readRunLocked(id: UUID) throws -> AgentTaskRun? {
        var run: AgentTaskRun?
        try prepareAndStep(
            """
                SELECT id, task_id, worker_id, status, claimed_at,
                       lease_expires_at, last_heartbeat_at, completed_at, error
                FROM task_runs
                WHERE id = ?1
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: id.uuidString)
        } process: { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                run = Self.readRun(stmt)
            }
        }
        return run
    }

    private static func readTask(_ stmt: OpaquePointer) -> AgentTask {
        AgentTask(
            id: uuidColumn(stmt, 0) ?? UUID(),
            title: textColumn(stmt, 1) ?? "",
            details: textColumn(stmt, 2),
            status: AgentTaskStatus(rawValue: textColumn(stmt, 3) ?? "") ?? .triage,
            priority: Int(sqlite3_column_int64(stmt, 4)),
            createdAt: dateColumn(stmt, 5) ?? Date(timeIntervalSince1970: 0),
            updatedAt: dateColumn(stmt, 6) ?? Date(timeIntervalSince1970: 0),
            scheduledAt: dateColumn(stmt, 7),
            blockedReason: textColumn(stmt, 8),
            metadataJSON: textColumn(stmt, 9),
            activeRunId: uuidColumn(stmt, 10),
            leaseOwner: textColumn(stmt, 11),
            leaseExpiresAt: dateColumn(stmt, 12),
            archivedAt: dateColumn(stmt, 13)
        )
    }

    private static func readRun(_ stmt: OpaquePointer) -> AgentTaskRun? {
        guard let id = uuidColumn(stmt, 0),
            let taskId = uuidColumn(stmt, 1),
            let workerId = textColumn(stmt, 2),
            let status = AgentTaskRunStatus(rawValue: textColumn(stmt, 3) ?? ""),
            let claimedAt = dateColumn(stmt, 4),
            let leaseExpiresAt = dateColumn(stmt, 5),
            let lastHeartbeatAt = dateColumn(stmt, 6)
        else {
            return nil
        }
        return AgentTaskRun(
            id: id,
            taskId: taskId,
            workerId: workerId,
            status: status,
            claimedAt: claimedAt,
            leaseExpiresAt: leaseExpiresAt,
            lastHeartbeatAt: lastHeartbeatAt,
            completedAt: dateColumn(stmt, 7),
            error: textColumn(stmt, 8)
        )
    }

    private static func readEvent(_ stmt: OpaquePointer) -> AgentTaskEvent? {
        guard let id = uuidColumn(stmt, 0),
            let taskId = uuidColumn(stmt, 1),
            let kind = AgentTaskEventKind(rawValue: textColumn(stmt, 2) ?? ""),
            let createdAt = dateColumn(stmt, 3)
        else {
            return nil
        }
        return AgentTaskEvent(
            id: id,
            taskId: taskId,
            kind: kind,
            createdAt: createdAt,
            workerId: textColumn(stmt, 4),
            runId: uuidColumn(stmt, 5),
            fromStatus: textColumn(stmt, 6).flatMap(AgentTaskStatus.init(rawValue:)),
            toStatus: textColumn(stmt, 7).flatMap(AgentTaskStatus.init(rawValue:)),
            message: textColumn(stmt, 8),
            payloadJSON: textColumn(stmt, 9)
        )
    }

    private static func readLink(_ stmt: OpaquePointer) -> AgentTaskLink? {
        guard let taskId = uuidColumn(stmt, 0),
            let dependsOnTaskId = uuidColumn(stmt, 1),
            let kind = AgentTaskLinkKind(rawValue: textColumn(stmt, 2) ?? ""),
            let createdAt = dateColumn(stmt, 3)
        else {
            return nil
        }
        return AgentTaskLink(
            taskId: taskId,
            dependsOnTaskId: dependsOnTaskId,
            kind: kind,
            createdAt: createdAt
        )
    }

    // MARK: - SQL helpers

    private func applyConnectionPragmas() throws {
        try executeRaw("PRAGMA busy_timeout = 5000")
        try executeRaw("PRAGMA foreign_keys = ON")
    }

    private func getSchemaVersion() throws -> Int {
        var version = 0
        try prepareAndStep("PRAGMA user_version") { _ in } process: { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                version = Int(sqlite3_column_int(stmt, 0))
            }
        }
        return version
    }

    private func setSchemaVersion(_ version: Int) throws {
        try executeRaw("PRAGMA user_version = \(version)")
    }

    private func inImmediateTransaction<T>(_ operation: () throws -> T) throws -> T {
        try queue.sync {
            guard db != nil else { throw AgentTaskBoardError.notOpen }
            try executeRaw("BEGIN IMMEDIATE")
            do {
                let result = try operation()
                try executeRaw("COMMIT")
                return result
            } catch {
                try? executeRaw("ROLLBACK")
                throw error
            }
        }
    }

    private func executeRaw(_ sql: String) throws {
        guard let connection = db else { throw AgentTaskBoardError.notOpen }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(connection))
            sqlite3_free(errorMessage)
            throw AgentTaskBoardError.failedToExecute(message)
        }
    }

    private func prepareAndStep(
        _ sql: String,
        bind: (OpaquePointer) throws -> Void,
        process: (OpaquePointer) throws -> Void
    ) throws {
        guard let connection = db else { throw AgentTaskBoardError.notOpen }
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(connection, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK, let statement = stmt else {
            throw AgentTaskBoardError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement)
        try process(statement)
    }

    private static func requireDone(
        _ stmt: OpaquePointer,
        connection: OpaquePointer?,
        context: String
    ) throws {
        let step = sqlite3_step(stmt)
        guard step == SQLITE_DONE else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "step returned \(step)"
            throw AgentTaskBoardError.failedToExecute("\(context): \(message)")
        }
    }

    private static let validInitialStatuses: Set<AgentTaskStatus> = [.triage, .todo, .scheduled, .ready]

    private static func bindTask(_ task: AgentTask, stmt: OpaquePointer) {
        bindText(stmt, index: 1, value: task.id.uuidString)
        bindText(stmt, index: 2, value: task.title)
        bindText(stmt, index: 3, value: task.details)
        bindText(stmt, index: 4, value: task.status.rawValue)
        sqlite3_bind_int64(stmt, 5, Int64(task.priority))
        bindDate(stmt, index: 6, value: task.createdAt)
        bindDate(stmt, index: 7, value: task.updatedAt)
        bindOptionalDate(stmt, index: 8, value: task.scheduledAt)
        bindText(stmt, index: 9, value: task.blockedReason)
        bindText(stmt, index: 10, value: task.metadataJSON)
        bindText(stmt, index: 11, value: task.activeRunId?.uuidString)
        bindText(stmt, index: 12, value: task.leaseOwner)
        bindOptionalDate(stmt, index: 13, value: task.leaseExpiresAt)
        bindOptionalDate(stmt, index: 14, value: task.archivedAt)
    }

    private static func bindText(_ stmt: OpaquePointer, index: Int, value: String?) {
        if let value {
            sqlite3_bind_text(stmt, Int32(index), value, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, Int32(index))
        }
    }

    private static func bindDate(_ stmt: OpaquePointer, index: Int, value: Date) {
        sqlite3_bind_double(stmt, Int32(index), value.timeIntervalSince1970)
    }

    private static func bindOptionalDate(_ stmt: OpaquePointer, index: Int, value: Date?) {
        if let value {
            bindDate(stmt, index: index, value: value)
        } else {
            sqlite3_bind_null(stmt, Int32(index))
        }
    }

    private static func textColumn(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
            let raw = sqlite3_column_text(stmt, index)
        else {
            return nil
        }
        return String(cString: raw)
    }

    private static func uuidColumn(_ stmt: OpaquePointer, _ index: Int32) -> UUID? {
        textColumn(stmt, index).flatMap(UUID.init(uuidString:))
    }

    private static func dateColumn(_ stmt: OpaquePointer, _ index: Int32) -> Date? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, index))
    }

    private static func validateTitle(_ title: String) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentTaskBoardError.invalidInput("title cannot be empty")
        }
    }

    private static func validateWorker(_ workerId: String) throws {
        guard !workerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentTaskBoardError.invalidInput("workerId cannot be empty")
        }
    }

    private static func validateLeaseTTL(_ ttl: TimeInterval) throws {
        guard ttl.isFinite, ttl > 0 else {
            throw AgentTaskBoardError.invalidInput("leaseTTL must be positive")
        }
    }
}
