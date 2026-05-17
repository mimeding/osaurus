import Foundation
import XCTest
@testable import OsaurusCLICore

final class CoordinatorControlServiceTests: XCTestCase {
    func testControlMarkersUsePrivatePermissions() throws {
        let paths = try temporaryPaths()
        let service = CoordinatorControlService(paths: paths)

        try service.pause(reason: "pause", now: coordinatorTestDate)
        try service.stop(reason: "stop", now: coordinatorTestDate)

        XCTAssertEqual(try posixMode(paths.stateDirectory), 0o700)
        XCTAssertEqual(try posixMode(paths.pauseFile), 0o600)
        XCTAssertEqual(try posixMode(paths.stopFile), 0o600)
    }
}
