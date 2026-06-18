//
//  OsaurusCLITests.swift
//  osaurus
//
//  Unit tests for the Osaurus CLI core functionality.
//

import XCTest
@testable import OsaurusCLICore

final class OsaurusCLITests: XCTestCase {
    func testConfiguration() {
        // Just a smoke test to ensure things link
        let root = Configuration.toolsRootDirectory()
        XCTAssertFalse(root.path.isEmpty)
    }

    func testResolveConfiguredPortReadsResolvedConfigRoot() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "osaurus-cli-config-\(UUID().uuidString)",
            isDirectory: true
        )
        let config = root.appendingPathComponent("config", isDirectory: true)
        try fm.createDirectory(at: config, withIntermediateDirectories: true)
        try #"{"port":2468}"#.write(
            to: config.appendingPathComponent("server.json"),
            atomically: true,
            encoding: .utf8
        )

        let previous = ProcessInfo.processInfo.environment["OSAURUS_TEST_ROOT"]
        setenv("OSAURUS_TEST_ROOT", root.path, 1)
        defer {
            if let previous {
                setenv("OSAURUS_TEST_ROOT", previous, 1)
            } else {
                unsetenv("OSAURUS_TEST_ROOT")
            }
            try? fm.removeItem(at: root)
        }

        XCTAssertEqual(Configuration.resolveConfiguredPort(), 2468)
    }
}
