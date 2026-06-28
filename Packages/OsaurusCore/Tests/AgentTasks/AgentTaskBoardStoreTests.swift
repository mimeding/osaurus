//
//  AgentTaskBoardStoreTests.swift
//  OsaurusCoreTests
//
//  Focused coverage for the durable local AgentTasks board foundation.
//

import CryptoKit
import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct AgentTaskBoardStoreTests {
    private func openInMemory() throws -> AgentTaskBoardStore {
        let store = AgentTaskBoardStore()
        try store.openForTesting()
        return store
    }

    private func tempDir(_ name: String = "agent-task-board") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func key(seed: UInt8) -> SymmetricKey {
        SymmetricKey(data: Data(repeating: seed, count: 32))
    }

    private func fixedDate(_ offset: TimeInterval = 0) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000 + offset)
    }

    @Test
    func migrationsCreateExpectedTables() throws {
        let store = try openInMemory()
        defer { store.close() }

        #expect(try store.schemaVersionForTesting() == 1)
        let tables = try store.tableNamesForTesting()
        #expect(tables.contains("tasks"))
        #expect(tables.contains("task_events"))
        #expect(tables.contains("task_runs"))
        #expect(tables.contains("task_links"))
    }

    @Test
    func createUpdateArchiveRoundTripsAndAppendsEvents() throws {
        let store = try openInMemory()
        defer { store.close() }

        let task = try store.createTask(
            AgentTaskCreateRequest(
                title: "Investigate flaky worker",
                details: "Capture local evidence",
                metadataJSON: #"{"issue":1714}"#
            ),
            now: fixedDate()
        )

        let updated = try store.updateTask(
            id: task.id,
            update: AgentTaskUpdate(
                title: "Investigate durable worker",
                status: .todo,
                priority: 7
            ),
            now: fixedDate(1),
            message: "triaged"
        )
        #expect(updated.title == "Investigate durable worker")
        #expect(updated.status == .todo)
        #expect(updated.priority == 7)

        let archived = try store.archiveTask(
            id: task.id,
            workerId: "tester",
            now: fixedDate(2),
            message: "not needed"
        )
        #expect(archived.status == .archived)
        #expect(archived.archivedAt == fixedDate(2))

        let maybeLoaded = try store.task(id: task.id)
        let loaded = try #require(maybeLoaded)
        #expect(loaded.status == .archived)
        #expect(try store.listTasks(statuses: [.archived]).map(\.id) == [task.id])
        #expect(try store.events(taskId: task.id).map(\.kind) == [.create, .update, .archive])
    }

    @Test
    func invalidStatusTransitionIsRejected() throws {
        let store = try openInMemory()
        defer { store.close() }
        let task = try store.createTask(AgentTaskCreateRequest(title: "Needs work"), now: fixedDate())

        #expect(throws: AgentTaskBoardError.self) {
            try store.updateTask(
                id: task.id,
                update: AgentTaskUpdate(status: .done),
                now: fixedDate(1)
            )
        }
        #expect(try store.task(id: task.id)?.status == .triage)
    }

    @Test
    func createRejectsInvalidInitialStatuses() throws {
        let store = try openInMemory()
        defer { store.close() }

        for status in [AgentTaskStatus.running, .blocked, .review, .done, .archived] {
            #expect(throws: AgentTaskBoardError.self) {
                try store.createTask(
                    AgentTaskCreateRequest(title: "Invalid \(status.rawValue)", status: status),
                    now: fixedDate()
                )
            }
        }

        #expect(throws: AgentTaskBoardError.self) {
            try store.createTask(
                AgentTaskCreateRequest(title: "Missing schedule", status: .scheduled),
                now: fixedDate()
            )
        }

        let scheduled = try store.createTask(
            AgentTaskCreateRequest(
                title: "Scheduled",
                status: .scheduled,
                scheduledAt: fixedDate(60)
            ),
            now: fixedDate()
        )
        #expect(scheduled.status == .scheduled)
    }

    @Test
    func updateCannotStrandScheduledTaskWithoutScheduledAt() throws {
        let store = try openInMemory()
        defer { store.close() }

        let scheduled = try store.createTask(
            AgentTaskCreateRequest(
                title: "Scheduled",
                status: .scheduled,
                scheduledAt: fixedDate(60)
            ),
            now: fixedDate()
        )

        #expect(throws: AgentTaskBoardError.self) {
            try store.updateTask(
                id: scheduled.id,
                update: AgentTaskUpdate(clearScheduledAt: true),
                now: fixedDate(1)
            )
        }

        let reloaded = try #require(try store.task(id: scheduled.id))
        #expect(reloaded.status == .scheduled)
        #expect(reloaded.scheduledAt == fixedDate(60))
    }

    @Test
    func updateFromRunningToReadyOrReviewFinishesRunAndClearsLease() throws {
        let store = try openInMemory()
        defer { store.close() }

        let readyTarget = try store.createTask(
            AgentTaskCreateRequest(title: "Return to ready", status: .ready),
            now: fixedDate()
        )
        let readyClaim = try #require(
            try store.claimTask(
                id: readyTarget.id,
                workerId: "worker-a",
                leaseTTL: 60,
                now: fixedDate(1)
            )
        )
        try store.setActiveRunForTesting(
            taskId: readyTarget.id,
            activeRunId: nil,
            leaseOwner: "worker-a",
            leaseExpiresAt: fixedDate(61)
        )

        let returned = try store.updateTask(
            id: readyTarget.id,
            update: AgentTaskUpdate(status: .ready),
            now: fixedDate(2),
            message: "manual requeue"
        )
        #expect(returned.status == .ready)
        #expect(returned.activeRunId == nil)
        #expect(returned.leaseOwner == nil)
        #expect(returned.leaseExpiresAt == nil)
        #expect(try store.runs(taskId: readyTarget.id).map(\.status) == [.abandoned])
        #expect(try store.events(taskId: readyTarget.id).last?.runId == readyClaim.run.id)

        let reviewTarget = try store.createTask(
            AgentTaskCreateRequest(title: "Move to review", status: .ready),
            now: fixedDate(3)
        )
        let reviewClaim = try #require(
            try store.claimTask(
                id: reviewTarget.id,
                workerId: "worker-b",
                leaseTTL: 60,
                now: fixedDate(4)
            )
        )

        let reviewed = try store.updateTask(
            id: reviewTarget.id,
            update: AgentTaskUpdate(status: .review),
            now: fixedDate(5),
            message: "ready for review"
        )
        #expect(reviewed.status == .review)
        #expect(reviewed.activeRunId == nil)
        #expect(reviewed.leaseOwner == nil)
        #expect(reviewed.leaseExpiresAt == nil)
        #expect(try store.runs(taskId: reviewTarget.id).map(\.status) == [.completed])
        #expect(try store.events(taskId: reviewTarget.id).last?.runId == reviewClaim.run.id)
    }

    @Test
    func updateToClaimableStatusRejectsNonRunningTaskWithActiveRunOrLease() throws {
        let store = try openInMemory()
        defer { store.close() }

        let staleRun = try store.createTask(
            AgentTaskCreateRequest(title: "Stale active run", status: .todo),
            now: fixedDate()
        )
        try store.setActiveRunForTesting(
            taskId: staleRun.id,
            activeRunId: UUID(),
            leaseOwner: "stale-worker",
            leaseExpiresAt: fixedDate(60)
        )

        #expect(throws: AgentTaskBoardError.self) {
            try store.updateTask(
                id: staleRun.id,
                update: AgentTaskUpdate(status: .ready),
                now: fixedDate(1)
            )
        }
        #expect(try store.task(id: staleRun.id)?.status == .todo)
        #expect(try store.task(id: staleRun.id)?.activeRunId != nil)

        let staleLease = try store.createTask(
            AgentTaskCreateRequest(title: "Stale lease", status: .todo),
            now: fixedDate(2)
        )
        try store.setActiveRunForTesting(
            taskId: staleLease.id,
            activeRunId: nil,
            leaseOwner: "stale-worker",
            leaseExpiresAt: fixedDate(62)
        )

        #expect(throws: AgentTaskBoardError.self) {
            try store.updateTask(
                id: staleLease.id,
                update: AgentTaskUpdate(status: .ready),
                now: fixedDate(3)
            )
        }
        #expect(try store.task(id: staleLease.id)?.status == .todo)
        #expect(try store.task(id: staleLease.id)?.leaseOwner == "stale-worker")
    }

    @Test
    func claimNextSkipsReadyRowsWithActiveRunId() throws {
        let store = try openInMemory()
        defer { store.close() }

        let orphaned = try store.createTask(
            AgentTaskCreateRequest(title: "Stale active row", status: .ready, priority: 100),
            now: fixedDate()
        )
        let claimable = try store.createTask(
            AgentTaskCreateRequest(title: "Claimable row", status: .ready, priority: 1),
            now: fixedDate(1)
        )
        try store.setActiveRunForTesting(
            taskId: orphaned.id,
            activeRunId: UUID(),
            leaseOwner: "stale-worker",
            leaseExpiresAt: fixedDate(120)
        )

        let claim = try #require(
            try store.claimNext(
                workerId: "worker-next",
                leaseTTL: 60,
                now: fixedDate(2)
            )
        )

        #expect(claim.task.id == claimable.id)
        #expect(try store.task(id: orphaned.id)?.status == .ready)
        #expect(try store.task(id: orphaned.id)?.activeRunId != nil)
    }

    @Test
    func dependencyInsertRejectsCycles() throws {
        let store = try openInMemory()
        defer { store.close() }

        let a = try store.createTask(AgentTaskCreateRequest(title: "A"), now: fixedDate())
        let b = try store.createTask(AgentTaskCreateRequest(title: "B"), now: fixedDate(1))
        let c = try store.createTask(AgentTaskCreateRequest(title: "C"), now: fixedDate(2))

        try store.addDependency(taskId: a.id, dependsOnTaskId: b.id, now: fixedDate(3))
        try store.addDependency(taskId: b.id, dependsOnTaskId: c.id, now: fixedDate(4))

        #expect(throws: AgentTaskBoardError.self) {
            try store.addDependency(taskId: c.id, dependsOnTaskId: a.id, now: fixedDate(5))
        }
        #expect(try store.dependencies(taskId: c.id).isEmpty)
    }

    @Test
    func claimRespectsDependenciesUntilPrerequisiteCompletes() throws {
        let store = try openInMemory()
        defer { store.close() }

        let prerequisite = try store.createTask(
            AgentTaskCreateRequest(title: "Prerequisite", status: .ready),
            now: fixedDate()
        )
        let dependent = try store.createTask(
            AgentTaskCreateRequest(title: "Dependent", status: .ready),
            now: fixedDate(1)
        )
        try store.addDependency(
            taskId: dependent.id,
            dependsOnTaskId: prerequisite.id,
            now: fixedDate(2)
        )

        #expect(
            try store.claimTask(
                id: dependent.id,
                workerId: "worker-a",
                leaseTTL: 60,
                now: fixedDate(3)
            ) == nil
        )

        let maybePrerequisiteClaim = try store.claimTask(
            id: prerequisite.id,
            workerId: "worker-a",
            leaseTTL: 60,
            now: fixedDate(4)
        )
        let prerequisiteClaim = try #require(maybePrerequisiteClaim)
        try store.completeTask(
            id: prerequisite.id,
            runId: prerequisiteClaim.run.id,
            workerId: "worker-a",
            now: fixedDate(5)
        )

        let maybeDependentClaim = try store.claimTask(
            id: dependent.id,
            workerId: "worker-b",
            leaseTTL: 60,
            now: fixedDate(6)
        )
        let dependentClaim = try #require(maybeDependentClaim)
        #expect(dependentClaim.task.status == .running)
        #expect(dependentClaim.task.leaseOwner == "worker-b")
    }

    @Test
    func concurrentAtomicClaimOnlyAllowsOneWinner() async throws {
        let dir = try tempDir("agent-task-board-claim")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("board.sqlite").path
        let keyData = Data(repeating: 0x34, count: 32)
        let primary = AgentTaskBoardStore()
        try primary.openForTesting(path: path, key: SymmetricKey(data: keyData))
        defer { primary.close() }

        let task = try primary.createTask(
            AgentTaskCreateRequest(title: "Claim once", status: .ready),
            now: fixedDate()
        )

        let winners = await withTaskGroup(of: String?.self) { group -> [String] in
            for i in 0 ..< 20 {
                group.addTask {
                    let store = AgentTaskBoardStore()
                    do {
                        try store.openForTesting(path: path, key: SymmetricKey(data: keyData))
                        defer { store.close() }
                        return try store.claimTask(
                            id: task.id,
                            workerId: "worker-\(i)",
                            leaseTTL: 60,
                            now: fixedDate(1)
                        )?.run.workerId
                    } catch {
                        store.close()
                        return nil
                    }
                }
            }

            var output: [String] = []
            for await winner in group {
                if let winner { output.append(winner) }
            }
            return output
        }

        #expect(winners.count == 1)
        let maybeLoaded = try primary.task(id: task.id)
        let loaded = try #require(maybeLoaded)
        #expect(loaded.status == .running)
        #expect(loaded.leaseOwner == winners.first)
        #expect(try primary.runs(taskId: task.id).count == 1)
    }

    @Test
    func staleLeaseCanBeReclaimedByAnotherWorker() throws {
        let store = try openInMemory()
        defer { store.close() }

        let task = try store.createTask(
            AgentTaskCreateRequest(title: "Reclaim me", status: .ready),
            now: fixedDate()
        )
        let maybeFirst = try store.claimTask(
            id: task.id,
            workerId: "worker-a",
            leaseTTL: 10,
            now: fixedDate(1)
        )
        let first = try #require(maybeFirst)
        let maybeSecond = try store.claimTask(
            id: task.id,
            workerId: "worker-b",
            leaseTTL: 10,
            now: fixedDate(12)
        )
        let second = try #require(maybeSecond)

        #expect(first.run.id != second.run.id)
        #expect(second.task.leaseOwner == "worker-b")
        let runs = try store.runs(taskId: task.id)
        #expect(runs.map(\.status) == [.expired, .running])
        #expect(try store.events(taskId: task.id).map(\.kind) == [.create, .claim, .update, .claim])
    }

    @Test
    func leaseRenewalRequiresCurrentOwnerRunAndUnexpiredLease() throws {
        let store = try openInMemory()
        defer { store.close() }

        let task = try store.createTask(
            AgentTaskCreateRequest(title: "Renew me", status: .ready),
            now: fixedDate()
        )
        let claim = try #require(
            try store.claimTask(
                id: task.id,
                workerId: "worker-a",
                leaseTTL: 10,
                now: fixedDate(1)
            )
        )

        #expect(
            try store.renewLease(
                taskId: task.id,
                runId: claim.run.id,
                workerId: "worker-b",
                leaseTTL: 20,
                now: fixedDate(5)
            ) == nil
        )
        #expect(
            try store.renewLease(
                taskId: task.id,
                runId: UUID(),
                workerId: "worker-a",
                leaseTTL: 20,
                now: fixedDate(5)
            ) == nil
        )

        let renewed = try #require(
            try store.renewLease(
                taskId: task.id,
                runId: claim.run.id,
                workerId: "worker-a",
                leaseTTL: 20,
                now: fixedDate(5)
            )
        )
        #expect(renewed.leaseExpiresAt == fixedDate(25))
        #expect(renewed.lastHeartbeatAt == fixedDate(5))
        #expect(try store.task(id: task.id)?.leaseExpiresAt == fixedDate(25))

        #expect(
            try store.renewLease(
                taskId: task.id,
                runId: claim.run.id,
                workerId: "worker-a",
                leaseTTL: 20,
                now: fixedDate(26)
            ) == nil
        )
        #expect(try store.task(id: task.id)?.leaseExpiresAt == fixedDate(25))
    }

    @Test
    func completeAndBlockRequireCurrentLeaseOwnerForRunningTasks() throws {
        let store = try openInMemory()
        defer { store.close() }

        let completable = try store.createTask(
            AgentTaskCreateRequest(title: "Complete me", status: .ready),
            now: fixedDate()
        )
        let completeClaim = try #require(
            try store.claimTask(
                id: completable.id,
                workerId: "worker-a",
                leaseTTL: 60,
                now: fixedDate(1)
            )
        )

        #expect(throws: AgentTaskBoardError.self) {
            try store.completeTask(
                id: completable.id,
                runId: completeClaim.run.id,
                workerId: "worker-b",
                now: fixedDate(2)
            )
        }
        #expect(try store.task(id: completable.id)?.status == .running)
        #expect(try store.runs(taskId: completable.id).map(\.status) == [.running])

        let completed = try store.completeTask(
            id: completable.id,
            runId: completeClaim.run.id,
            workerId: "worker-a",
            now: fixedDate(3)
        )
        #expect(completed.status == .done)
        #expect(try store.runs(taskId: completable.id).map(\.status) == [.completed])

        let blockable = try store.createTask(
            AgentTaskCreateRequest(title: "Block me", status: .ready),
            now: fixedDate(4)
        )
        let blockClaim = try #require(
            try store.claimTask(
                id: blockable.id,
                workerId: "worker-c",
                leaseTTL: 60,
                now: fixedDate(5)
            )
        )

        #expect(throws: AgentTaskBoardError.self) {
            try store.blockTask(
                id: blockable.id,
                reason: "needs human input",
                runId: blockClaim.run.id,
                workerId: "worker-d",
                now: fixedDate(6)
            )
        }
        #expect(try store.task(id: blockable.id)?.status == .running)
        #expect(try store.runs(taskId: blockable.id).map(\.status) == [.running])

        let blocked = try store.blockTask(
            id: blockable.id,
            reason: "needs human input",
            runId: blockClaim.run.id,
            workerId: "worker-c",
            now: fixedDate(7)
        )
        #expect(blocked.status == .blocked)
        #expect(blocked.blockedReason == "needs human input")
        #expect(try store.runs(taskId: blockable.id).map(\.status) == [.blocked])

        let expired = try store.createTask(
            AgentTaskCreateRequest(title: "Expired lease", status: .ready),
            now: fixedDate(8)
        )
        let expiredClaim = try #require(
            try store.claimTask(
                id: expired.id,
                workerId: "worker-e",
                leaseTTL: 5,
                now: fixedDate(9)
            )
        )

        #expect(throws: AgentTaskBoardError.self) {
            try store.completeTask(
                id: expired.id,
                runId: expiredClaim.run.id,
                workerId: "worker-e",
                now: fixedDate(15)
            )
        }
        #expect(try store.task(id: expired.id)?.status == .running)
        #expect(try store.runs(taskId: expired.id).map(\.status) == [.running])
    }

    @Test
    func crashStyleRecoveryReturnsExpiredRunningTaskToReadyAfterReopen() throws {
        let dir = try tempDir("agent-task-board-recovery")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("board.sqlite").path
        let dbKey = key(seed: 0x44)
        let taskId: UUID

        do {
            let firstOpen = AgentTaskBoardStore()
            try firstOpen.openForTesting(path: path, key: dbKey)
            defer { firstOpen.close() }
            let task = try firstOpen.createTask(
                AgentTaskCreateRequest(title: "Recover me", status: .ready),
                now: fixedDate()
            )
            taskId = task.id
            let maybeClaim = try firstOpen.claimTask(
                id: task.id,
                workerId: "worker-a",
                leaseTTL: 5,
                now: fixedDate(1)
            )
            _ = try #require(maybeClaim)
        }

        let reopened = AgentTaskBoardStore()
        try reopened.openForTesting(path: path, key: dbKey)
        defer { reopened.close() }
        #expect(try reopened.recoverExpiredLeases(asOf: fixedDate(7)) == 1)

        let maybeRecovered = try reopened.task(id: taskId)
        let recovered = try #require(maybeRecovered)
        #expect(recovered.status == .ready)
        #expect(recovered.activeRunId == nil)
        #expect(recovered.leaseOwner == nil)
        #expect(try reopened.runs(taskId: taskId).map(\.status) == [.expired])
    }

    @Test
    func productionOpenCreatesEncryptedBoardEvenWhenGlobalPolicyIsPlaintext() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try tempDir("agent-task-board-encrypted")
            let dbKey = key(seed: 0x55)
            OsaurusPaths.overrideRoot = root
            StorageKeyManager.shared._setKeyForTesting(dbKey)
            try StorageEncryptionPolicy.shared.setDesiredMode(.plaintext)
            defer {
                OsaurusPaths.overrideRoot = nil
                StorageEncryptionPolicy.shared.invalidateCache()
                StorageKeyManager.shared.wipeCache()
                try? FileManager.default.removeItem(at: root)
            }

            let store = AgentTaskBoardStore()
            try store.open()
            try store.createTask(
                AgentTaskCreateRequest(title: "Encrypted board", status: .ready),
                now: fixedDate()
            )
            store.close()

            let path = OsaurusPaths.agentTaskBoardDatabaseFile().path
            #expect(StorageFileFormat.detect(path: path) == .encrypted)
            #expect(StorageMigrationCoordinator.detectOnDiskPosture() == .empty)
        }
    }
}
