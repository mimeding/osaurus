//
//  AgentWorkspace.swift
//  osaurus
//
//  Persistent per-agent workspace metadata and bounded source summaries.
//

import Foundation

public struct AgentWorkspace: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let agentId: UUID
    public var name: String
    public var description: String
    public var sources: [AgentWorkspaceSource]
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        agentId: UUID,
        name: String,
        description: String = "",
        sources: [AgentWorkspaceSource] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.agentId = agentId
        self.name = name
        self.description = description
        self.sources = sources
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct AgentWorkspaceSource: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var kind: AgentWorkspaceSourceKind
    public var path: String
    public var displayName: String
    public var status: AgentWorkspaceSourceStatus
    public var byteCount: Int64?
    public var itemCount: Int?
    public var summary: String?
    public var error: String?
    public var indexedAt: Date?

    public init(
        id: UUID = UUID(),
        kind: AgentWorkspaceSourceKind,
        path: String,
        displayName: String,
        status: AgentWorkspaceSourceStatus,
        byteCount: Int64? = nil,
        itemCount: Int? = nil,
        summary: String? = nil,
        error: String? = nil,
        indexedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.path = path
        self.displayName = displayName
        self.status = status
        self.byteCount = byteCount
        self.itemCount = itemCount
        self.summary = summary
        self.error = error
        self.indexedAt = indexedAt
    }
}

public enum AgentWorkspaceSourceKind: String, Codable, Sendable {
    case file
    case folder
    case missing
}

public enum AgentWorkspaceSourceStatus: String, Codable, Sendable {
    case indexed
    case skipped
    case error
}

public struct AgentWorkspacePromptSummary: Sendable, Equatable {
    public let workspaces: [AgentWorkspacePromptWorkspace]
    public let omittedWorkspaces: Int
    public let omittedSources: Int
    public let canReadSources: Bool

    public init(
        workspaces: [AgentWorkspacePromptWorkspace],
        omittedWorkspaces: Int = 0,
        omittedSources: Int = 0,
        canReadSources: Bool = false
    ) {
        self.workspaces = workspaces
        self.omittedWorkspaces = omittedWorkspaces
        self.omittedSources = omittedSources
        self.canReadSources = canReadSources
    }
}

public struct AgentWorkspacePromptWorkspace: Sendable, Equatable {
    public let name: String
    public let description: String
    public let sources: [AgentWorkspacePromptSource]

    public init(
        name: String,
        description: String,
        sources: [AgentWorkspacePromptSource]
    ) {
        self.name = name
        self.description = description
        self.sources = sources
    }
}

public struct AgentWorkspacePromptSource: Sendable, Equatable {
    public let kind: AgentWorkspaceSourceKind
    public let path: String
    public let displayName: String
    public let status: AgentWorkspaceSourceStatus
    public let summary: String?
    public let error: String?

    public init(
        kind: AgentWorkspaceSourceKind,
        path: String,
        displayName: String,
        status: AgentWorkspaceSourceStatus,
        summary: String?,
        error: String?
    ) {
        self.kind = kind
        self.path = path
        self.displayName = displayName
        self.status = status
        self.summary = summary
        self.error = error
    }
}
