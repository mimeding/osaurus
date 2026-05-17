import Foundation
@testable import OsaurusCLICore

func temporaryPaths(file: StaticString = #filePath, line: UInt = #line) throws -> CoordinatorPaths {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("osaurus-coord-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    return CoordinatorPaths(root: root)
}
