import Foundation
import XCTest
@testable import OsaurusCLICore

final class CoordinatorPlanDriftServiceTests: XCTestCase {
    func testPlanDriftPassesWhenPlanMatchesOriginMain() {
        let runner = RecordingCoordinatorProcessRunner(stubs: [
            stub(command: ["git", "rev-parse", "--verify", "origin/main^{commit}"], stdout: "\(coordinatorTestMainSHA)\n"),
            stub(command: ["git", "diff", "--name-only", "origin/main", "--", "docs/OPEN_PR_BUG_DEVELOPMENT_PLAN.md"]),
        ])

        let report = CoordinatorPlanDriftService(repositoryRoot: URL(fileURLWithPath: "/repo"), runner: runner)
            .check(now: coordinatorTestDate)

        XCTAssertTrue(report.allowsGate)
        XCTAssertEqual(report.status, .clean)
        XCTAssertEqual(report.baselineSHA, coordinatorTestMainSHA)
    }

    func testPlanDriftBlocksGateWhenPlanDiffers() {
        let runner = RecordingCoordinatorProcessRunner(stubs: [
            stub(command: ["git", "rev-parse", "--verify", "origin/main^{commit}"], stdout: "\(coordinatorTestMainSHA)\n"),
            stub(
                command: ["git", "diff", "--name-only", "origin/main", "--", "docs/OPEN_PR_BUG_DEVELOPMENT_PLAN.md"],
                stdout: "docs/OPEN_PR_BUG_DEVELOPMENT_PLAN.md\n"
            ),
        ])

        let report = CoordinatorPlanDriftService(repositoryRoot: URL(fileURLWithPath: "/repo"), runner: runner)
            .check(now: coordinatorTestDate)

        XCTAssertFalse(report.allowsGate)
        XCTAssertEqual(report.status, .drifted)
        XCTAssertEqual(report.changedPaths, ["docs/OPEN_PR_BUG_DEVELOPMENT_PLAN.md"])
    }
}
