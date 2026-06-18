//
//  AppDataLocationResolverTests.swift
//  OsaurusRepository
//

import Foundation
import XCTest

@testable import OsaurusRepository

final class AppDataLocationResolverTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-location-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let sandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
        try super.tearDownWithError()
    }

    func testNewInstallUsesAppleStandardLocationsWithoutCreatingThem() throws {
        let fm = FileManager.default
        let dirs = platformDirectories()

        let locations = AppDataLocationResolver.resolve(
            environment: [:],
            fileManager: fm,
            platformDirectories: dirs
        )

        XCTAssertEqual(
            locations.dataRoot,
            dirs.applicationSupportDirectory!.appendingPathComponent("Osaurus", isDirectory: true)
        )
        XCTAssertEqual(
            locations.configRoot,
            dirs.applicationSupportDirectory!
                .appendingPathComponent("Osaurus", isDirectory: true)
                .appendingPathComponent("config", isDirectory: true)
        )
        XCTAssertEqual(
            locations.cacheRoot,
            dirs.cachesDirectory!.appendingPathComponent("Osaurus", isDirectory: true)
        )
        XCTAssertEqual(locations.data.source, .standard)
        XCTAssertEqual(locations.config.source, .standard)
        XCTAssertEqual(locations.cache.source, .standard)
        XCTAssertFalse(fm.fileExists(atPath: locations.dataRoot.path))
        XCTAssertFalse(fm.fileExists(atPath: locations.cacheRoot.path))
    }

    func testExistingHomeDotDirectoryKeepsDataAndConfigInLegacyRoot() throws {
        let fm = FileManager.default
        let dirs = platformDirectories()
        let legacy = dirs.homeDirectory.appendingPathComponent(".osaurus", isDirectory: true)
        try fm.createDirectory(
            at: legacy.appendingPathComponent("config", isDirectory: true),
            withIntermediateDirectories: true
        )

        let locations = AppDataLocationResolver.resolve(
            environment: [:],
            fileManager: fm,
            platformDirectories: dirs
        )

        XCTAssertEqual(locations.dataRoot, legacy)
        XCTAssertEqual(locations.data.source, .legacyHomeDotDirectory)
        XCTAssertEqual(
            locations.configRoot,
            legacy.appendingPathComponent("config", isDirectory: true)
        )
        XCTAssertEqual(locations.config.source, .legacyHomeDotDirectory)
        XCTAssertEqual(locations.cache.source, .standard)
        XCTAssertFalse(fm.fileExists(atPath: locations.standardDataRoot.path))
    }

    func testExistingLegacyCacheFallsBackForCompatibility() throws {
        let fm = FileManager.default
        let dirs = platformDirectories()
        let legacyCache = dirs.homeDirectory
            .appendingPathComponent(".osaurus", isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)
        try fm.createDirectory(at: legacyCache, withIntermediateDirectories: true)

        let locations = AppDataLocationResolver.resolve(
            environment: [:],
            fileManager: fm,
            platformDirectories: dirs
        )

        XCTAssertEqual(locations.cacheRoot, legacyCache)
        XCTAssertEqual(locations.cache.source, .legacyHomeDotDirectory)
    }

    func testStandardRootWinsOverRetiredApplicationSupportWhenHomeLegacyIsAbsent() throws {
        let fm = FileManager.default
        let dirs = platformDirectories()
        let standard = dirs.applicationSupportDirectory!.appendingPathComponent(
            "Osaurus",
            isDirectory: true
        )
        let retired = dirs.applicationSupportDirectory!.appendingPathComponent(
            "com.dinoki.osaurus",
            isDirectory: true
        )
        try fm.createDirectory(at: standard, withIntermediateDirectories: true)
        try fm.createDirectory(at: retired, withIntermediateDirectories: true)

        let locations = AppDataLocationResolver.resolve(
            environment: [:],
            fileManager: fm,
            platformDirectories: dirs
        )

        XCTAssertEqual(locations.dataRoot, standard)
        XCTAssertEqual(locations.data.source, .standard)
        XCTAssertTrue(
            locations.candidates.contains {
                $0.kind == .data && $0.source == .legacyApplicationSupport && $0.exists
            }
        )
    }

    func testRetiredApplicationSupportIsReadOnlyFallbackWhenItIsTheOnlyExistingRoot() throws {
        let fm = FileManager.default
        let dirs = platformDirectories()
        let retired = dirs.applicationSupportDirectory!.appendingPathComponent(
            "com.dinoki.osaurus",
            isDirectory: true
        )
        try fm.createDirectory(
            at: retired.appendingPathComponent("config", isDirectory: true),
            withIntermediateDirectories: true
        )

        let locations = AppDataLocationResolver.resolve(
            environment: [:],
            fileManager: fm,
            platformDirectories: dirs
        )

        XCTAssertEqual(locations.dataRoot, retired)
        XCTAssertEqual(locations.data.source, .legacyApplicationSupport)
        XCTAssertEqual(
            locations.configRoot,
            retired.appendingPathComponent("config", isDirectory: true)
        )
        XCTAssertEqual(locations.config.source, .legacyApplicationSupport)
        XCTAssertFalse(fm.fileExists(atPath: locations.standardDataRoot.path))
    }

    func testEnvironmentOverrideCollapsesLocationsUnderTestRoot() throws {
        let dirs = platformDirectories()
        let root = sandbox.appendingPathComponent("override-root", isDirectory: true)

        let locations = AppDataLocationResolver.resolve(
            environment: [AppDataLocationResolver.testRootEnvironmentVariable: root.path],
            platformDirectories: dirs
        )

        XCTAssertEqual(locations.dataRoot, root)
        XCTAssertEqual(locations.configRoot, root.appendingPathComponent("config", isDirectory: true))
        XCTAssertEqual(locations.cacheRoot, root.appendingPathComponent("cache", isDirectory: true))
        XCTAssertEqual(locations.data.source, .environmentOverride)
        XCTAssertEqual(locations.config.source, .environmentOverride)
        XCTAssertEqual(locations.cache.source, .environmentOverride)
    }

    func testXDGDirectoriesAreUsedWhenAppleDirectoriesAreUnavailable() throws {
        let dirs = AppDataLocationResolver.PlatformDirectories(
            homeDirectory: sandbox.appendingPathComponent("home", isDirectory: true),
            applicationSupportDirectory: nil,
            cachesDirectory: nil,
            xdgDataHome: sandbox.appendingPathComponent("xdg-data", isDirectory: true),
            xdgConfigHome: sandbox.appendingPathComponent("xdg-config", isDirectory: true),
            xdgCacheHome: sandbox.appendingPathComponent("xdg-cache", isDirectory: true)
        )

        let locations = AppDataLocationResolver.resolve(
            environment: [:],
            platformDirectories: dirs
        )

        XCTAssertEqual(
            locations.dataRoot,
            dirs.xdgDataHome.appendingPathComponent("osaurus", isDirectory: true)
        )
        XCTAssertEqual(
            locations.configRoot,
            dirs.xdgConfigHome.appendingPathComponent("osaurus", isDirectory: true)
        )
        XCTAssertEqual(
            locations.cacheRoot,
            dirs.xdgCacheHome.appendingPathComponent("osaurus", isDirectory: true)
        )
    }

    private func platformDirectories() -> AppDataLocationResolver.PlatformDirectories {
        AppDataLocationResolver.PlatformDirectories(
            homeDirectory: sandbox.appendingPathComponent("home", isDirectory: true),
            applicationSupportDirectory:
                sandbox.appendingPathComponent("Library/Application Support", isDirectory: true),
            cachesDirectory: sandbox.appendingPathComponent("Library/Caches", isDirectory: true),
            xdgDataHome: sandbox.appendingPathComponent("home/.local/share", isDirectory: true),
            xdgConfigHome: sandbox.appendingPathComponent("home/.config", isDirectory: true),
            xdgCacheHome: sandbox.appendingPathComponent("home/.cache", isDirectory: true)
        )
    }
}
