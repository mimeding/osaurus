import Foundation
import XCTest
@testable import OsaurusCLICore

final class CoordinatorBootstrapTests: XCTestCase {
    func testInitializeCreatesLayoutAndSeedsState() throws {
        let paths = try temporaryPaths()
        let result = try CoordinatorBootstrap(paths: paths).initialize(lanes: ["alpha", "beta"])

        XCTAssertTrue(result.initialized)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.stateDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.locksDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.worktreesDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.artifactsDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.evidenceDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.laneDirectory(named: "alpha").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.featureFlagsFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.statusFile.path))
        XCTAssertEqual(result.seededFiles.count, 3)
    }

    func testInitializeIsIdempotent() throws {
        let paths = try temporaryPaths()
        _ = try CoordinatorBootstrap(paths: paths).initialize(lanes: ["alpha"])
        let second = try CoordinatorBootstrap(paths: paths).initialize(lanes: ["alpha"])

        XCTAssertTrue(second.createdDirectories.isEmpty)
        XCTAssertTrue(second.seededFiles.isEmpty)
        XCTAssertFalse(second.existingDirectories.isEmpty)
    }
}
