//
//  AuthAccessKeyLifecycleServiceTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct AuthAccessKeyLifecycleServiceTests {
    @Test func create_normalizesLabelAndRejectsBlankLabels() throws {
        let manager = FakeAccessKeyLifecycleManager()
        let service = AccessKeyLifecycleService(manager: manager)

        let created = try service.create(label: "  Desktop   Client  ", expiration: .days90)
        #expect(created.info.label == "Desktop Client")

        #expect(throws: AccessKeyLifecycleError.emptyLabel) {
            _ = try service.create(label: "   ", expiration: .days90)
        }
    }

    @Test func create_rejectsOverlongLabelsBeforeKeyGeneration() {
        let manager = FakeAccessKeyLifecycleManager()
        let service = AccessKeyLifecycleService(manager: manager)
        let longLabel = String(repeating: "a", count: AccessKeyLifecycleService.maximumLabelLength + 1)

        #expect(throws: AccessKeyLifecycleError.labelTooLong(80)) {
            _ = try service.create(label: longLabel, expiration: .days90)
        }
        #expect(manager.generatedLabels.isEmpty)
    }

    @Test func revoke_marksMetadataRevokedWithoutRemovingRow() throws {
        let existing = AccessKeyInfo.fixture(label: "CLI")
        let manager = FakeAccessKeyLifecycleManager(keys: [existing])
        let service = AccessKeyLifecycleService(manager: manager)

        let revoked = try service.revoke(id: existing.id)

        #expect(revoked.id == existing.id)
        #expect(revoked.revoked)
        #expect(revoked.revokedAt != nil)
        #expect(manager.reloadCount == 1)
        #expect(manager.revokedIds == [existing.id])
        #expect(manager.listKeys().count == 1)
    }

    @Test func revoke_reportsPersistenceFailures() {
        let existing = AccessKeyInfo.fixture(label: "Sticky")
        let manager = FakeAccessKeyLifecycleManager(keys: [existing])
        manager.keepRevokedIdsActive = true
        let service = AccessKeyLifecycleService(manager: manager)

        #expect(throws: AccessKeyLifecycleError.revocationDidNotPersist) {
            _ = try service.revoke(id: existing.id)
        }
    }

    @Test func forget_deletesMetadataAfterRecordingRevocation() throws {
        let existing = AccessKeyInfo.fixture(label: "CLI")
        let manager = FakeAccessKeyLifecycleManager(keys: [existing])
        let service = AccessKeyLifecycleService(manager: manager)

        let removed = try service.forget(id: existing.id)

        #expect(removed.id == existing.id)
        #expect(manager.reloadCount == 1)
        #expect(manager.deletedIds == [existing.id])
        #expect(manager.listKeys().isEmpty)
    }

    @Test func forget_reportsPersistenceFailures() {
        let existing = AccessKeyInfo.fixture(label: "Sticky")
        let manager = FakeAccessKeyLifecycleManager(keys: [existing])
        manager.keepDeletedIdsInMetadata = true
        let service = AccessKeyLifecycleService(manager: manager)

        #expect(throws: AccessKeyLifecycleError.removalDidNotPersist) {
            _ = try service.revokeAndRemove(id: existing.id)
        }
    }

    @Test func snapshot_classifiesScopeCountsAndRedactsDisplay() {
        let agent = AccessKeyAgentScopeDescriptor(
            address: "0x2222222222222222222222222222222222222222",
            name: "Research",
            agentIndex: 7
        )
        let active = AccessKeyInfo.fixture(
            label: "Desktop",
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
        )
        let revoked = AccessKeyInfo.fixture(
            label: "Paired - old",
            expiration: .never,
            id: UUID(),
            revoked: true,
            revokedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let expired = AccessKeyInfo.fixture(
            label: "Agent",
            id: UUID(),
            aud: agent.address,
            expiresAt: Date(timeIntervalSince1970: 1)
        )
        let manager = FakeAccessKeyLifecycleManager(keys: [active, revoked, expired])
        let service = AccessKeyLifecycleService(manager: manager)

        let snapshot = service.snapshot(knownAgents: [agent], includeInactive: true)

        #expect(snapshot.totalCount == 3)
        #expect(snapshot.activeCount == 1)
        #expect(snapshot.revokedCount == 1)
        #expect(snapshot.expiredCount == 1)
        #expect(snapshot.records.first { $0.id == active.id }?.redactedDisplay.contains("...") == true)
        #expect(snapshot.records.first { $0.id == revoked.id }?.isLegacyPairing == true)
        #expect(snapshot.records.first { $0.id == expired.id }?.scope == .agent(
            name: "Research",
            address: agent.address,
            agentIndex: 7
        ))

        let activeOnly = service.snapshot(knownAgents: [agent], includeInactive: false)
        #expect(activeOnly.records.map(\.id) == [active.id])
    }
}

private final class FakeAccessKeyLifecycleManager: AccessKeyLifecycleManaging {
    var keys: [AccessKeyInfo]
    var generatedLabels: [String] = []
    var generatedAgentIndexes: [UInt32?] = []
    var revokedIds: [UUID] = []
    var deletedIds: [UUID] = []
    var reloadCount = 0
    var keepRevokedIdsActive = false
    var keepDeletedIdsInMetadata = false

    init(keys: [AccessKeyInfo] = []) {
        self.keys = keys
    }

    func generate(
        label: String,
        expiration: AccessKeyExpiration,
        agentIndex: UInt32?
    ) throws -> (fullKey: String, info: AccessKeyInfo) {
        generatedLabels.append(label)
        generatedAgentIndexes.append(agentIndex)
        let info = AccessKeyInfo.fixture(label: label, expiration: expiration)
        keys.append(info)
        return ("osk-v1.fake.\(info.id.uuidString)", info)
    }

    func revoke(id: UUID) {
        revokedIds.append(id)
        guard !keepRevokedIdsActive else { return }
        guard let index = keys.firstIndex(where: { $0.id == id }) else { return }
        keys[index] = keys[index].withRevoked(at: Date(timeIntervalSince1970: 1_700_000_123))
    }

    func delete(id: UUID) {
        deletedIds.append(id)
        guard !keepDeletedIdsInMetadata else { return }
        keys.removeAll { $0.id == id }
    }

    func listKeys() -> [AccessKeyInfo] {
        keys
    }

    func reload() {
        reloadCount += 1
    }
}

private extension AccessKeyInfo {
    static func fixture(
        label: String,
        expiration: AccessKeyExpiration = .days90,
        id: UUID = UUID(),
        aud: OsaurusID = "0x1111111111111111111111111111111111111111",
        expiresAt: Date? = nil,
        revoked: Bool = false,
        revokedAt: Date? = nil
    ) -> AccessKeyInfo {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        return AccessKeyInfo(
            id: id,
            label: label,
            prefix: "osk-v1.fake",
            nonce: id.uuidString.lowercased(),
            cnt: 1,
            iss: "0x1111111111111111111111111111111111111111",
            aud: aud,
            createdAt: created,
            expiration: expiration,
            expiresAt: expiresAt ?? expiration.expirationDate(from: created),
            revoked: revoked,
            revokedAt: revokedAt
        )
    }
}
