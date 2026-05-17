import Foundation
import XCTest
@testable import OsaurusCLICore

final class CoordinatorPreflightServiceTests: XCTestCase {
    func testPreflightPassesWhenAuthRateLimitAndMainSHAAreHealthy() {
        let runner = RecordingCoordinatorProcessRunner(stubs: [
            stub(command: ["gh", "auth", "status"]),
            stub(command: ["gh", "api", "rate_limit"], stdout: rateLimitJSON(remaining: 4_999, limit: 5_000)),
            stub(command: ["git", "rev-parse", "--verify", "origin/main^{commit}"], stdout: "\(coordinatorTestMainSHA)\n"),
            stub(command: ["git", "rev-parse", "--verify", "main^{commit}"], stdout: "\(coordinatorTestMainSHA)\n"),
        ])

        let report = CoordinatorPreflightService(repositoryRoot: URL(fileURLWithPath: "/repo"), runner: runner)
            .run(now: coordinatorTestDate)

        XCTAssertTrue(report.ok)
        XCTAssertEqual(report.originMainSHA, coordinatorTestMainSHA)
        XCTAssertEqual(report.mainSHA, coordinatorTestMainSHA)
        XCTAssertEqual(report.rateLimitRemaining, 4_999)
        XCTAssertEqual(report.checks.map(\.name), ["gh-auth", "gh-rate-limit", "origin-main", "sha-drift"])
    }

    func testPreflightFailsClosedWhenLocalMainDriftsFromOriginMain() {
        let localSHA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let runner = RecordingCoordinatorProcessRunner(stubs: [
            stub(command: ["gh", "auth", "status"]),
            stub(command: ["gh", "api", "rate_limit"], stdout: rateLimitJSON(remaining: 1, limit: 5_000)),
            stub(command: ["git", "rev-parse", "--verify", "origin/main^{commit}"], stdout: "\(coordinatorTestMainSHA)\n"),
            stub(command: ["git", "rev-parse", "--verify", "main^{commit}"], stdout: "\(localSHA)\n"),
        ])

        let report = CoordinatorPreflightService(repositoryRoot: URL(fileURLWithPath: "/repo"), runner: runner)
            .run(now: coordinatorTestDate)

        XCTAssertFalse(report.ok)
        XCTAssertEqual(report.checks.last?.name, "sha-drift")
        XCTAssertEqual(report.checks.last?.status, .fail)
        XCTAssertEqual(report.checks.last?.details["main"], localSHA)
        XCTAssertEqual(report.checks.last?.details["originMain"], coordinatorTestMainSHA)
    }

    private func rateLimitJSON(remaining: Int, limit: Int) -> String {
        """
        {"resources":{"core":{"remaining":\(remaining),"limit":\(limit)}}}
        """
    }
}
