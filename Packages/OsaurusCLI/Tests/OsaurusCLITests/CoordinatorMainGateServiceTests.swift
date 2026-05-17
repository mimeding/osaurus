import Foundation
import XCTest
@testable import OsaurusCLICore

final class CoordinatorMainGateServiceTests: XCTestCase {
    func testGateMainReusesPassingEvidenceForExactMainSHA() throws {
        let paths = try temporaryPaths()
        let evidenceDirectory = paths.evidenceDirectory
            .appendingPathComponent("gate-main", isDirectory: true)
            .appendingPathComponent(coordinatorTestMainSHA, isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let existing = CoordinatorMainGateReport(
            generatedAt: coordinatorTestDate,
            mainSHA: coordinatorTestMainSHA,
            status: .passed,
            action: .built,
            message: "exact-main release build passed",
            evidenceDirectory: evidenceDirectory.path,
            worktree: paths.worktreesDirectory.appendingPathComponent("main-\(coordinatorTestMainSHA.prefix(12))").path,
            command: CoordinatorMainGateCommandEvidence(
                command: ["swift", "build", "--package-path", "Packages/OsaurusCore", "-c", "release"],
                workingDirectory: "/worktree",
                exitCode: 0
            ),
            stdoutPath: evidenceDirectory.appendingPathComponent("stdout.txt").path,
            stderrPath: evidenceDirectory.appendingPathComponent("stderr.txt").path
        )
        try CoordinatorJSON.encoder().encode(existing).write(
            to: evidenceDirectory.appendingPathComponent("report.json"),
            options: .atomic
        )
        let runner = RecordingCoordinatorProcessRunner(stubs: [
            stub(command: ["git", "rev-parse", "--verify", "origin/main^{commit}"], stdout: "\(coordinatorTestMainSHA)\n")
        ])

        let report = try CoordinatorMainGateService(
            paths: paths,
            repositoryRoot: URL(fileURLWithPath: "/repo"),
            runner: runner
        )
        .run(now: coordinatorTestDate)

        XCTAssertTrue(report.ok)
        XCTAssertEqual(report.action, .validatedExisting)
        XCTAssertEqual(runner.invocations.map(\.command), [["git", "rev-parse", "--verify", "origin/main^{commit}"]])
    }

    func testGateMainCreatesExactMainWorktreeRunsBuildAndWritesEvidence() throws {
        let paths = try temporaryPaths()
        let runner = RecordingCoordinatorProcessRunner(stubs: [
            stub(command: ["git", "rev-parse", "--verify", "origin/main^{commit}"], stdout: "\(coordinatorTestMainSHA)\n"),
            RecordingCoordinatorProcessRunner.Stub(
                matches: { $0.command.prefix(4) == ["git", "worktree", "add", "--detach"] },
                result: processResult(command: ["git", "worktree", "add", "--detach"])
            ),
            stub(
                command: ["swift", "build", "--package-path", "Packages/OsaurusCore", "-c", "release"],
                stdout: "build ok\n"
            ),
        ])

        let report = try CoordinatorMainGateService(
            paths: paths,
            repositoryRoot: URL(fileURLWithPath: "/repo"),
            runner: runner
        )
        .run(now: coordinatorTestDate)

        XCTAssertTrue(report.ok)
        XCTAssertEqual(report.action, .built)
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.evidenceDirectory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.stdoutPath ?? ""))
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.stderrPath ?? ""))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(report.evidenceDirectory)/report.json"))
        XCTAssertEqual(try String(contentsOfFile: report.stdoutPath ?? "", encoding: .utf8), "build ok\n")
        XCTAssertEqual(try posixMode(URL(fileURLWithPath: report.evidenceDirectory)), 0o700)
        XCTAssertEqual(try posixMode(URL(fileURLWithPath: "\(report.evidenceDirectory)/report.json")), 0o600)
        XCTAssertEqual(try posixMode(URL(fileURLWithPath: report.stdoutPath ?? "")), 0o600)
        XCTAssertEqual(try posixMode(URL(fileURLWithPath: report.stderrPath ?? "")), 0o600)
    }

    func testGateMainWritesFailureEvidenceWhenReleaseBuildCannotLaunch() throws {
        let paths = try temporaryPaths()
        let runner = RecordingCoordinatorProcessRunner(stubs: [
            stub(command: ["git", "rev-parse", "--verify", "origin/main^{commit}"], stdout: "\(coordinatorTestMainSHA)\n"),
            RecordingCoordinatorProcessRunner.Stub(
                matches: { $0.command.prefix(4) == ["git", "worktree", "add", "--detach"] },
                result: processResult(command: ["git", "worktree", "add", "--detach"])
            ),
            throwingStub(command: ["swift", "build", "--package-path", "Packages/OsaurusCore", "-c", "release"]),
        ])

        let report = try CoordinatorMainGateService(
            paths: paths,
            repositoryRoot: URL(fileURLWithPath: "/repo"),
            runner: runner
        )
        .run(now: coordinatorTestDate)

        XCTAssertFalse(report.ok)
        XCTAssertEqual(report.message, "failed to launch exact-main release build")
        XCTAssertNil(report.command?.exitCode)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(report.evidenceDirectory)/report.json"))
    }
}
