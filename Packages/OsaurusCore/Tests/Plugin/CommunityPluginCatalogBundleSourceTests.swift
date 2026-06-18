//
//  CommunityPluginCatalogBundleSourceTests.swift
//  OsaurusCore
//
//  Verifies the bundled trusted community plugin catalog is packaged.
//

import XCTest

@testable import OsaurusCore

final class CommunityPluginCatalogBundleSourceTests: XCTestCase {
    func test_loadBundledCatalog_decodesDefaultCommunityCatalog() throws {
        let catalog = try CommunityPluginCatalogBundleSource.loadBundled()

        XCTAssertEqual(catalog.schema_version, 1)
        XCTAssertEqual(catalog.source_name, "Osaurus community plugin catalog")
        XCTAssertGreaterThanOrEqual(catalog.plugins.count, 20)
        XCTAssertEqual(catalog.entry(for: "osaurus.browser")?.category, "Web")
        XCTAssertTrue(catalog.plugins.allSatisfy { $0.trust?.trusted == true })
    }
}
