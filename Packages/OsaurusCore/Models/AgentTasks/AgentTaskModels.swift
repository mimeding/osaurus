//
//  AgentTaskModels.swift
//  osaurus
//
//  Durable task-board domain types for local multi-agent orchestration state.
//  These are storage/service DTOs only; no remote execution or inbox protocol
//  behavior lives here.
//

import Foundation

public enum AgentTaskStatus: String, Codable, Sendable, CaseIterable, Equatable {
    case triage
    case todo
    case scheduled
    case ready
    case running
    case blocked
    case review
    case done
    case archived

    public var isTerminal: Bool {
        self == .done || self == .archived
    }

    public func canTransition(to next: AgentTaskStatus) -> Bool {
        guard self != next else { return true }
        switch self {
        case .triage:
            return [.todo, .scheduled, .ready, .blocked, .archived].contains(next)
        case .todo:
            return [.triage, .scheduled, .ready, .blocked, .archived].contains(next)
        case .scheduled:
            return [.todo, .ready, .blocked, .archived].contains(next)
        case .ready:
            return [.todo, .scheduled, .running, .blocked, .archived].contains(next)
        case .running:
            return [.ready, .blocked, .review, .done, .archived].contains(next)
        case .blocked:
            return [.triage, .todo, .scheduled, .ready, .archived].contains(next)
        case .review:
            return [.running, .blocked, .done, .archived].contains(next)
        case .done:
            return [.review, .archived].contains(next)
        case .archived:
            return false
        }
    }
}

public enum AgentTaskEventKind: String, Codable, Sendable, CaseIterable, Equatable {
    case create
    case update
    case claim
    case complete
    case block
    case archive
}

public enum AgentTaskRunStatus: String, Codable, Sendable, CaseIterable, Equatable {
    case running
    case completed
    case blocked
    case expired
    case abandoned
}

public enum AgentTaskLinkKind: String, Codable, Sendable, CaseIterable, Equatable {
    case dependsOn = "depends_on"
}

public struct AgentTask: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var details: String?
    public var status: AgentTaskStatus
    public var priority: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var scheduledAt: Date?
    public var blockedReason: String?
    public var metadataJSON: String?
    public var activeRunId: UUID?
    public var leaseOwner: String?
    public var leaseExpiresAt: Date?
    public var archivedAt: Date?

    public init(
        id: UUID = UUID(),
        title: String,
        details: String? = nil,
        status: AgentTaskStatus = .triage,
        priority: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        scheduledAt: Date? = nil,
        blockedReason: String? = nil,
        metadataJSON: String? = nil,
        activeRunId: UUID? = nil,
        leaseOwner: String? = nil,
        leaseExpiresAt: Date? = nil,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.status = status
        self.priority = priority
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.scheduledAt = scheduledAt
        self.blockedReason = blockedReason
        self.metadataJSON = metadataJSON
        self.activeRunId = activeRunId
        self.leaseOwner = leaseOwner
        self.leaseExpiresAt = leaseExpiresAt
        self.archivedAt = archivedAt
    }
}

public struct AgentTaskRun: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var taskId: UUID
    public var workerId: String
    public var status: AgentTaskRunStatus
    public var claimedAt: Date
    public var leaseExpiresAt: Date
    public var lastHeartbeatAt: Date
    public var completedAt: Date?
    public var error: String?

    public init(
        id: UUID = UUID(),
        taskId: UUID,
        workerId: String,
        status: AgentTaskRunStatus = .running,
        claimedAt: Date = Date(),
        leaseExpiresAt: Date,
        lastHeartbeatAt: Date = Date(),
        completedAt: Date? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.taskId = taskId
        self.workerId = workerId
        self.status = status
        self.claimedAt = claimedAt
        self.leaseExpiresAt = leaseExpiresAt
        self.lastHeartbeatAt = lastHeartbeatAt
        self.completedAt = completedAt
        self.error = error
    }
}

public struct AgentTaskEvent: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var taskId: UUID
    public var kind: AgentTaskEventKind
    public var createdAt: Date
    public var workerId: String?
    public var runId: UUID?
    public var fromStatus: AgentTaskStatus?
    public var toStatus: AgentTaskStatus?
    public var message: String?
    public var payloadJSON: String?

    public init(
        id: UUID = UUID(),
        taskId: UUID,
        kind: AgentTaskEventKind,
        createdAt: Date = Date(),
        workerId: String? = nil,
        runId: UUID? = nil,
        fromStatus: AgentTaskStatus? = nil,
        toStatus: AgentTaskStatus? = nil,
        message: String? = nil,
        payloadJSON: String? = nil
    ) {
        self.id = id
        self.taskId = taskId
        self.kind = kind
        self.createdAt = createdAt
        self.workerId = workerId
        self.runId = runId
        self.fromStatus = fromStatus
        self.toStatus = toStatus
        self.message = message
        self.payloadJSON = payloadJSON
    }
}

public struct AgentTaskLink: Codable, Sendable, Equatable {
    public var taskId: UUID
    public var dependsOnTaskId: UUID
    public var kind: AgentTaskLinkKind
    public var createdAt: Date

    public init(
        taskId: UUID,
        dependsOnTaskId: UUID,
        kind: AgentTaskLinkKind = .dependsOn,
        createdAt: Date = Date()
    ) {
        self.taskId = taskId
        self.dependsOnTaskId = dependsOnTaskId
        self.kind = kind
        self.createdAt = createdAt
    }
}

public struct AgentTaskCreateRequest: Sendable, Equatable {
    public var id: UUID?
    public var title: String
    public var details: String?
    public var status: AgentTaskStatus
    public var priority: Int
    public var scheduledAt: Date?
    public var metadataJSON: String?

    public init(
        id: UUID? = nil,
        title: String,
        details: String? = nil,
        status: AgentTaskStatus = .triage,
        priority: Int = 0,
        scheduledAt: Date? = nil,
        metadataJSON: String? = nil
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.status = status
        self.priority = priority
        self.scheduledAt = scheduledAt
        self.metadataJSON = metadataJSON
    }
}

public struct AgentTaskUpdate: Sendable, Equatable {
    public var title: String?
    public var details: String?
    public var status: AgentTaskStatus?
    public var priority: Int?
    public var scheduledAt: Date?
    public var clearScheduledAt: Bool
    public var blockedReason: String?
    public var clearBlockedReason: Bool
    public var metadataJSON: String?
    public var clearMetadataJSON: Bool

    public init(
        title: String? = nil,
        details: String? = nil,
        status: AgentTaskStatus? = nil,
        priority: Int? = nil,
        scheduledAt: Date? = nil,
        clearScheduledAt: Bool = false,
        blockedReason: String? = nil,
        clearBlockedReason: Bool = false,
        metadataJSON: String? = nil,
        clearMetadataJSON: Bool = false
    ) {
        self.title = title
        self.details = details
        self.status = status
        self.priority = priority
        self.scheduledAt = scheduledAt
        self.clearScheduledAt = clearScheduledAt
        self.blockedReason = blockedReason
        self.clearBlockedReason = clearBlockedReason
        self.metadataJSON = metadataJSON
        self.clearMetadataJSON = clearMetadataJSON
    }
}

public struct AgentTaskClaim: Sendable, Equatable {
    public var task: AgentTask
    public var run: AgentTaskRun

    public init(task: AgentTask, run: AgentTaskRun) {
        self.task = task
        self.run = run
    }
}
