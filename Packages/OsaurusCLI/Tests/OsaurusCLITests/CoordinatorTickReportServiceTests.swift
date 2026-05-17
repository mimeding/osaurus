import Foundation
import XCTest
@testable import OsaurusCLICore

final class CoordinatorTickReportServiceTests: XCTestCase {
    func testStatusTickReportIsDeterministicMarkdownArtifact() throws {
        let paths = try temporaryPaths()
        _ = try CoordinatorBootstrap(paths: paths).initialize(lanes: [])
        let snapshot = try CoordinatorStatusService(paths: paths).snapshot(now: coordinatorTestDate)

        let artifact = try CoordinatorTickReportService(paths: paths).writeStatusReport(
            snapshot,
            now: coordinatorTestDate
        )

        XCTAssertEqual(
            artifact.path,
            paths.tickReportsDirectory.appendingPathComponent("20260331T233320Z-status.md").path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path))
        XCTAssertTrue(artifact.markdown.contains("# Coordinator Tick Report"))
        XCTAssertTrue(artifact.markdown.contains("- Generated: 2026-03-31T23:33:20Z"))
        XCTAssertTrue(artifact.markdown.contains("- Initialized: yes"))
        XCTAssertEqual(try posixMode(paths.tickReportsDirectory), 0o700)
        XCTAssertEqual(try posixMode(URL(fileURLWithPath: artifact.path)), 0o600)
    }
}
