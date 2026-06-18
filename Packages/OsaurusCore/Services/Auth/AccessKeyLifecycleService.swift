//
//  AccessKeyLifecycleService.swift
//  OsaurusCore
//
//  User-facing access-key lifecycle operations.
//

import Foundation

public protocol AccessKeyLifecycleManaging: AnyObject {
    func generate(
        label: String,
        expiration: AccessKeyExpiration,
        agentIndex: UInt32?
    ) throws -> (fullKey: String, info: AccessKeyInfo)

    func revoke(id: UUID)
    func delete(id: UUID)
    func listKeys() -> [AccessKeyInfo]
    func reload()
}

extension APIKeyManager: AccessKeyLifecycleManaging {}

public struct AccessKeyAgentScopeDescriptor: Sendable, Equatable, Hashable {
    public let address: OsaurusID
    public let name: String
    public let agentIndex: UInt32?

    public init(address: OsaurusID, name: String, agentIndex: UInt32?) {
        self.address = address
        self.name = name
        self.agentIndex = agentIndex
    }
}

public enum AccessKeyManagementScope: Sendable, Equatable {
    case allAgents
    case agent(name: String, address: OsaurusID, agentIndex: UInt32?)

    public var address: OsaurusID? {
        switch self {
        case .allAgents:
            return nil
        case .agent(_, let address, _):
            return address
        }
    }
}

public struct AccessKeyManagementRecord: Identifiable, Sendable {
    public let info: AccessKeyInfo
    public let status: AccessKeyStatus
    public let scope: AccessKeyManagementScope
    public let isLegacyPairing: Bool

    public var id: UUID { info.id }
    public var redactedDisplay: String { info.redactedDisplay }
    public var canRevoke: Bool { status == .active }
    public var canForget: Bool { status != .active }

    public init(
        info: AccessKeyInfo,
        knownAgents: [AccessKeyAgentScopeDescriptor],
        date: Date = Date()
    ) {
        self.info = info
        self.status = info.status(at: date)
        let lowerAudience = info.aud.lowercased()
        if let agent = knownAgents.first(where: { $0.address.lowercased() == lowerAudience }) {
            self.scope = .agent(
                name: agent.name,
                address: agent.address,
                agentIndex: agent.agentIndex
            )
        } else {
            self.scope = .allAgents
        }
        self.isLegacyPairing =
            info.expiration == .never
            && info.label.hasPrefix("Paired")
            && self.scope == .allAgents
    }
}

public struct AccessKeyManagementSnapshot: Sendable {
    public let records: [AccessKeyManagementRecord]

    public var totalCount: Int { records.count }
    public var activeCount: Int { records.filter { $0.status == .active }.count }
    public var revokedCount: Int { records.filter { $0.status == .revoked }.count }
    public var expiredCount: Int { records.filter { $0.status == .expired }.count }
    public var inactiveCount: Int { revokedCount + expiredCount }
    public var hasActiveKeys: Bool { activeCount > 0 }

    public init(records: [AccessKeyManagementRecord]) {
        self.records = records
    }
}

public final class AccessKeyLifecycleService: @unchecked Sendable {
    public static let shared = AccessKeyLifecycleService()

    public static let maximumLabelLength = 80

    private let manager: AccessKeyLifecycleManaging

    public init(manager: AccessKeyLifecycleManaging = APIKeyManager.shared) {
        self.manager = manager
    }

    public func create(
        label: String,
        expiration: AccessKeyExpiration,
        agentIndex: UInt32? = nil
    ) throws -> (fullKey: String, info: AccessKeyInfo) {
        let cleanLabel = try Self.validatedLabel(label)
        return try manager.generate(
            label: cleanLabel,
            expiration: expiration,
            agentIndex: agentIndex
        )
    }

    public func snapshot(
        knownAgents: [AccessKeyAgentScopeDescriptor] = [],
        includeInactive: Bool = true,
        reload: Bool = false
    ) -> AccessKeyManagementSnapshot {
        if reload {
            manager.reload()
        }
        let records = manager.listKeys()
            .sorted { $0.createdAt > $1.createdAt }
            .map { AccessKeyManagementRecord(info: $0, knownAgents: knownAgents) }
            .filter { includeInactive || $0.status == .active }
        return AccessKeyManagementSnapshot(records: records)
    }

    @discardableResult
    public func revoke(id: UUID) throws -> AccessKeyInfo {
        manager.reload()
        guard manager.listKeys().contains(where: { $0.id == id }) else {
            throw AccessKeyLifecycleError.keyNotFound
        }

        manager.revoke(id: id)

        guard let updated = manager.listKeys().first(where: { $0.id == id }) else {
            throw AccessKeyLifecycleError.revocationDidNotPersist
        }
        guard updated.revoked else {
            throw AccessKeyLifecycleError.revocationDidNotPersist
        }
        return updated
    }

    @discardableResult
    public func forget(id: UUID) throws -> AccessKeyInfo {
        manager.reload()
        guard let existing = manager.listKeys().first(where: { $0.id == id }) else {
            throw AccessKeyLifecycleError.keyNotFound
        }

        manager.delete(id: id)

        if manager.listKeys().contains(where: { $0.id == id }) {
            throw AccessKeyLifecycleError.removalDidNotPersist
        }

        return existing
    }

    @discardableResult
    public func revokeAndRemove(id: UUID) throws -> AccessKeyInfo {
        try forget(id: id)
    }

    public static func validatedLabel(_ label: String) throws -> String {
        let clean =
            label
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        guard !clean.isEmpty else { throw AccessKeyLifecycleError.emptyLabel }
        guard clean.count <= maximumLabelLength else {
            throw AccessKeyLifecycleError.labelTooLong(maximumLabelLength)
        }
        return clean
    }
}

public enum AccessKeyLifecycleError: LocalizedError, Equatable {
    case emptyLabel
    case labelTooLong(Int)
    case keyNotFound
    case revocationDidNotPersist
    case removalDidNotPersist

    public var errorDescription: String? {
        switch self {
        case .emptyLabel:
            return "Access key labels cannot be empty."
        case .labelTooLong(let maximum):
            return "Access key labels must be \(maximum) characters or fewer."
        case .keyNotFound:
            return "Access key could not be found."
        case .revocationDidNotPersist:
            return "Access key revocation was recorded, but the key metadata did not update."
        case .removalDidNotPersist:
            return "Access key revocation was recorded, but the key still appears in metadata."
        }
    }
}
