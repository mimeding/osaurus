//
//  AgentTaskBoardService.swift
//  osaurus
//
//  Public service facade for durable local task-board state. This deliberately
//  does not spawn agents, poll inboxes, run remote commands, or expose UI
//  workflows; it is storage and coordination API only.
//

import Foundation

public final class AgentTaskBoardService: @unchecked Sendable {
    public static let shared = AgentTaskBoardService(store: .shared)

    private let store: AgentTaskBoardStore

    public init(store: AgentTaskBoardStore) {
        self.store = store
    }

    public func open() throws {
        try store.open()
    }

    public func close() {
        store.close()
    }

    @discardableResult
    public func createTask(
        _ request: AgentTaskCreateRequest,
        now: Date = Date()
    ) throws -> AgentTask {
        try store.createTask(request, now: now)
    }

    public func task(id: UUID) throws -> AgentTask? {
        try store.task(id: id)
    }

    public func listTasks(statuses: [AgentTaskStatus]? = nil) throws -> [AgentTask] {
        try store.listTasks(statuses: statuses)
    }

    @discardableResult
    public func updateTask(
        id: UUID,
        update: AgentTaskUpdate,
        now: Date = Date(),
        message: String? = nil
    ) throws -> AgentTask {
        try store.updateTask(id: id, update: update, now: now, message: message)
    }

    @discardableResult
    public func addDependency(
        taskId: UUID,
        dependsOnTaskId: UUID,
        now: Date = Date()
    ) throws -> AgentTaskLink {
        try store.addDependency(taskId: taskId, dependsOnTaskId: dependsOnTaskId, now: now)
    }

    public func dependencies(taskId: UUID) throws -> [AgentTaskLink] {
        try store.dependencies(taskId: taskId)
    }

    public func removeDependency(
        taskId: UUID,
        dependsOnTaskId: UUID,
        now: Date = Date()
    ) throws {
        try store.removeDependency(taskId: taskId, dependsOnTaskId: dependsOnTaskId, now: now)
    }

    public func claimTask(
        id: UUID,
        workerId: String,
        leaseTTL: TimeInterval,
        now: Date = Date()
    ) throws -> AgentTaskClaim? {
        try store.claimTask(id: id, workerId: workerId, leaseTTL: leaseTTL, now: now)
    }

    public func claimNext(
        workerId: String,
        leaseTTL: TimeInterval,
        now: Date = Date()
    ) throws -> AgentTaskClaim? {
        try store.claimNext(workerId: workerId, leaseTTL: leaseTTL, now: now)
    }

    public func renewLease(
        taskId: UUID,
        runId: UUID,
        workerId: String,
        leaseTTL: TimeInterval,
        now: Date = Date()
    ) throws -> AgentTaskRun? {
        try store.renewLease(
            taskId: taskId,
            runId: runId,
            workerId: workerId,
            leaseTTL: leaseTTL,
            now: now
        )
    }

    @discardableResult
    public func recoverExpiredLeases(asOf now: Date = Date()) throws -> Int {
        try store.recoverExpiredLeases(asOf: now)
    }

    @discardableResult
    public func completeTask(
        id: UUID,
        runId: UUID? = nil,
        workerId: String? = nil,
        now: Date = Date(),
        message: String? = nil
    ) throws -> AgentTask {
        try store.completeTask(
            id: id,
            runId: runId,
            workerId: workerId,
            now: now,
            message: message
        )
    }

    @discardableResult
    public func blockTask(
        id: UUID,
        reason: String,
        runId: UUID? = nil,
        workerId: String? = nil,
        now: Date = Date()
    ) throws -> AgentTask {
        try store.blockTask(
            id: id,
            reason: reason,
            runId: runId,
            workerId: workerId,
            now: now
        )
    }

    @discardableResult
    public func archiveTask(
        id: UUID,
        workerId: String? = nil,
        now: Date = Date(),
        message: String? = nil
    ) throws -> AgentTask {
        try store.archiveTask(id: id, workerId: workerId, now: now, message: message)
    }

    public func events(taskId: UUID) throws -> [AgentTaskEvent] {
        try store.events(taskId: taskId)
    }

    public func runs(taskId: UUID) throws -> [AgentTaskRun] {
        try store.runs(taskId: taskId)
    }
}
