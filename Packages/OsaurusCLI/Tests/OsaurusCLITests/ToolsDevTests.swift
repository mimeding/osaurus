//
//  ToolsDevTests.swift
//  osaurus
//
//  Tests for plugin development-mode helpers.
//

import OsaurusRepository
import XCTest

@testable import OsaurusCLICore

final class ToolsDevTests: XCTestCase {
    func testDevProxyConfigurationFileUsesResolvedConfigRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-tools-dev-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dirs = AppDataLocationResolver.PlatformDirectories(
            homeDirectory: root.appendingPathComponent("home", isDirectory: true),
            applicationSupportDirectory: nil,
            cachesDirectory: nil,
            xdgDataHome: root.appendingPathComponent("xdg-data", isDirectory: true),
            xdgConfigHome: root.appendingPathComponent("xdg-config", isDirectory: true),
            xdgCacheHome: root.appendingPathComponent("xdg-cache", isDirectory: true)
        )
        let locations = AppDataLocationResolver.resolve(
            environment: [:],
            platformDirectories: dirs
        )

        let file = ToolsDev.devProxyConfigurationFile(locations: locations)

        XCTAssertEqual(
            file,
            dirs.xdgConfigHome
                .appendingPathComponent("osaurus", isDirectory: true)
                .appendingPathComponent("dev-proxy.json")
        )
        XCTAssertNotEqual(
            file,
            dirs.xdgDataHome
                .appendingPathComponent("osaurus", isDirectory: true)
                .appendingPathComponent("config", isDirectory: true)
                .appendingPathComponent("dev-proxy.json")
        )
    }

    func testDevProxyConfigurationFileFollowsLegacyDataRootConfigFamily() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("osaurus-tools-dev-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let dirs = AppDataLocationResolver.PlatformDirectories(
            homeDirectory: root.appendingPathComponent("home", isDirectory: true),
            applicationSupportDirectory:
                root.appendingPathComponent("Library/Application Support", isDirectory: true),
            cachesDirectory: root.appendingPathComponent("Library/Caches", isDirectory: true),
            xdgDataHome: root.appendingPathComponent("home/.local/share", isDirectory: true),
            xdgConfigHome: root.appendingPathComponent("home/.config", isDirectory: true),
            xdgCacheHome: root.appendingPathComponent("home/.cache", isDirectory: true)
        )
        let legacy = dirs.homeDirectory.appendingPathComponent(".osaurus", isDirectory: true)
        let standardConfig = dirs.applicationSupportDirectory!
            .appendingPathComponent("Osaurus", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try fm.createDirectory(at: standardConfig, withIntermediateDirectories: true)

        let locations = AppDataLocationResolver.resolve(
            environment: [:],
            fileManager: fm,
            platformDirectories: dirs
        )
        let file = ToolsDev.devProxyConfigurationFile(locations: locations)

        XCTAssertEqual(
            file,
            legacy
                .appendingPathComponent("config", isDirectory: true)
                .appendingPathComponent("dev-proxy.json")
        )
    }
}
