import Foundation
import XCTest
@testable import OsaurusCLICore

final class CoordinatorHeartbeatServiceTests: XCTestCase {
    func testHeartbeatReapsLocksHonorsPauseAndWritesTickReport() throws {
        let paths = try temporaryPaths()
        _ = try CoordinatorBootstrap(paths: paths).initialize(lanes: [])
        try CoordinatorControlService(paths: paths).pause(reason: "operator pause", now: coordinatorTestDate)
        _ = try CoordinatorLockService(paths: paths).acquire(
            resource: "stale",
            owner: "worker",
            ttl: 1,
            now: coordinatorTestDate
        )
        let tickDate = coordinatorTestDate.addingTimeInterval(10)
        let runner = healthyHeartbeatRunner()

        let report = try CoordinatorHeartbeatService(
            paths: paths,
            repositoryRoot: URL(fileURLWithPath: "/repo"),
            runner: runner
        )
        .tick(now: tickDate)

        XCTAssertFalse(report.ok)
        XCTAssertEqual(report.reapedLocks.map(\.resource), ["stale"])
        XCTAssertEqual(report.gate.action, "skipped")
        XCTAssertEqual(report.gate.reason, "coordinator is paused")
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.tickReportPath))
        XCTAssertEqual(try CoordinatorLockService(paths: paths).list(), [])
        XCTAssertFalse(runner.invocations.contains { $0.command == ["swift", "build", "--package-path", "Packages/OsaurusCore", "-c", "release"] })
    }

    func testHeartbeatRunsGateWhenPreflightAndPlanAreClean() throws {
        let paths = try temporaryPaths()
        _ = try CoordinatorBootstrap(paths: paths).initialize(lanes: [])
        let runner = RecordingCoordinatorProcessRunner(stubs: healthyHeartbeatStubs() + [
            stub(command: ["git", "rev-parse", "--verify", "origin/main^{commit}"], stdout: "\(coordinatorTestMainSHA)\n"),
            RecordingCoordinatorProcessRunner.Stub(
                matches: { $0.command.prefix(4) == ["git", "worktree", "add", "--detach"] },
                result: processResult(command: ["git", "worktree", "add", "--detach"])
            ),
            stub(command: ["swift", "build", "--package-path", "Packages/OsaurusCore", "-c", "release"]),
        ])

        let report = try CoordinatorHeartbeatService(
            paths: paths,
            repositoryRoot: URL(fileURLWithPath: "/repo"),
            runner: runner
        )
        .tick(now: coordinatorTestDate)

        XCTAssertTrue(report.ok)
        XCTAssertEqual(report.gate.action, "built")
        XCTAssertEqual(report.gate.status, "passed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.tickReportPath))
    }

    private func healthyHeartbeatRunner() -> RecordingCoordinatorProcessRunner {
        RecordingCoordinatorProcessRunner(stubs: healthyHeartbeatStubs())
    }

    private func healthyHeartbeatStubs() -> [RecordingCoordinatorProcessRunner.Stub] {
        [
            stub(command: ["gh", "auth", "status"]),
            stub(command: ["gh", "api", "rate_limit"], stdout: "{\"resources\":{\"core\":{\"remaining\":10,\"limit\":5000}}}"),
            stub(command: ["git", "rev-parse", "--verify", "origin/main^{commit}"], stdout: "\(coordinatorTestMainSHA)\n"),
            stub(command: ["git", "rev-parse", "--verify", "main^{commit}"], stdout: "\(coordinatorTestMainSHA)\n"),
            stub(command: ["git", "rev-parse", "--verify", "origin/main^{commit}"], stdout: "\(coordinatorTestMainSHA)\n"),
            stub(command: ["git", "diff", "--name-only", "origin/main", "--", "docs/OPEN_PR_BUG_DEVELOPMENT_PLAN.md"]),
        ]
    }
}
