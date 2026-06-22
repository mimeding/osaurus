//
//  CommunityPluginCatalogTests.swift
//  OsaurusRepository
//
//  Focused coverage for trusted community catalog parsing, filtering,
//  and install-preview behavior.
//

import Foundation
import XCTest

@testable import OsaurusRepository

final class CommunityPluginCatalogTests: XCTestCase {
    func test_catalogParsing_appliesDefaultValues() throws {
        let data = Data(
            """
            {
              "source_name": "Test catalog",
              "trusted_registry_url": "https://example.invalid/tools.git",
              "plugins": [
                {
                  "plugin_id": "osaurus.browser",
                  "name": "Browser",
                  "summary": "Browse the web",
                  "category": "Web",
                  "trust": { "trusted": true, "source": "fixture" }
                }
              ]
            }
            """.utf8
        )

        let catalog = try JSONDecoder().decode(CommunityPluginCatalog.self, from: data)

        XCTAssertEqual(catalog.schema_version, 1)
        XCTAssertEqual(catalog.source_name, "Test catalog")
        XCTAssertEqual(catalog.plugins.count, 1)
        XCTAssertEqual(catalog.plugins[0].tags, [])
        XCTAssertFalse(catalog.plugins[0].featured)
        XCTAssertEqual(catalog.entry(for: "osaurus.browser")?.trust?.source, "fixture")
    }

    func test_indexFiltersByCategoryQueryAndInstallState() {
        let catalog = CommunityPluginCatalog(
            schema_version: 1,
            plugins: [
                CommunityPluginCatalogEntry(
                    plugin_id: "osaurus.browser",
                    name: "Browser",
                    summary: "Browse pages",
                    category: "Web",
                    tags: ["automation"],
                    featured: true,
                    sort_rank: 2
                ),
                CommunityPluginCatalogEntry(
                    plugin_id: "osaurus.calendar",
                    name: "Calendar",
                    summary: "Schedule work",
                    category: "Productivity",
                    sort_rank: 1
                ),
            ]
        )

        let index = CommunityPluginCatalogIndex(
            catalog: catalog,
            specs: [
                makeSpec(pluginId: "osaurus.browser", name: "Browser"),
                makeSpec(pluginId: "osaurus.calendar", name: "Calendar"),
                makeSpec(pluginId: "osaurus.local", name: "Local Only"),
            ],
            installedVersionsByPluginId: [
                "osaurus.browser": sv("1.0.0"),
            ]
        )

        XCTAssertEqual(index.filtered(category: "web").map(\.pluginId), ["osaurus.browser"])
        XCTAssertEqual(index.filtered(query: "automation").map(\.pluginId), ["osaurus.browser"])
        XCTAssertEqual(index.filtered(installFilter: .installed).map(\.pluginId), ["osaurus.browser"])
        XCTAssertEqual(
            index.filtered(installFilter: .available).map(\.pluginId),
            ["osaurus.calendar", "osaurus.local"]
        )
        XCTAssertEqual(index.categories.map(\.id), ["productivity", "web", "registry"])
    }

    func test_indexFilteringAllowsCustomQueryMatcher() {
        let index = CommunityPluginCatalogIndex(
            catalog: .empty,
            specs: [
                makeSpec(pluginId: "osaurus.browser", name: "Browser"),
            ]
        )

        let matches = index.filtered(
            query: "brwsr",
            queryMatcher: { query, candidate in
                query == "brwsr" && candidate == "browser"
            }
        )

        XCTAssertEqual(matches.map(\.pluginId), ["osaurus.browser"])
    }

    func test_installPreviewMarksInstallableUpdateAndInstalledStates() {
        let spec = makeSpec(pluginId: "osaurus.browser", name: "Browser", version: "2.0.0")

        let fresh = PluginInstallPreview(spec: spec, installedVersion: nil)
        let update = PluginInstallPreview(spec: spec, installedVersion: sv("1.0.0"))
        let installed = PluginInstallPreview(spec: spec, installedVersion: sv("2.0.0"))

        XCTAssertEqual(fresh.state, .installable)
        XCTAssertTrue(fresh.canInstall)
        XCTAssertEqual(update.state, .updateAvailable)
        XCTAssertTrue(update.canInstall)
        XCTAssertEqual(installed.state, .installed)
        XCTAssertFalse(installed.canInstall)
    }

    func test_installPreviewRecordsCatalogTrustState() {
        let trustedEntry = CommunityPluginCatalogEntry(
            plugin_id: "osaurus.trusted",
            name: "Trusted",
            trust: CommunityPluginTrust(trusted: true, source: "fixture")
        )
        let untrustedEntry = CommunityPluginCatalogEntry(
            plugin_id: "osaurus.review",
            name: "Needs Review",
            trust: CommunityPluginTrust(trusted: false, source: "fixture")
        )

        let trustedPreview = PluginInstallPreview(
            spec: makeSpec(pluginId: "osaurus.trusted", name: "Trusted"),
            catalogEntry: trustedEntry
        )
        let registryOnlyPreview = PluginInstallPreview(
            spec: makeSpec(pluginId: "osaurus.registry", name: "Registry Only")
        )
        let untrustedPreview = PluginInstallPreview(
            spec: makeSpec(pluginId: "osaurus.review", name: "Needs Review"),
            catalogEntry: untrustedEntry
        )

        XCTAssertEqual(trustedPreview.trustState, .trustedCatalog)
        XCTAssertTrue(trustedPreview.canInstall)
        XCTAssertEqual(registryOnlyPreview.trustState, .registryOnly)
        XCTAssertTrue(registryOnlyPreview.canInstall)
        XCTAssertEqual(untrustedPreview.trustState, .reviewRequired)
        XCTAssertEqual(untrustedPreview.state, .unavailable)
        XCTAssertFalse(untrustedPreview.canInstall)
        XCTAssertEqual(untrustedPreview.failureReasons, [.catalogReviewRequired])
    }

    func test_installPreviewBlocksIncompatiblePlugin() {
        let incompatible = makeSpec(
            pluginId: "osaurus.linux",
            name: "Linux Only",
            artifactOS: "linux"
        )

        let incompatiblePreview = PluginInstallPreview(spec: incompatible)

        XCTAssertEqual(incompatiblePreview.state, .unavailable)
        XCTAssertFalse(incompatiblePreview.canInstall)
        XCTAssertEqual(incompatiblePreview.failureReasons, [.incompatiblePlatform])
        XCTAssertEqual(
            incompatiblePreview.primaryBlockingMessage?.message,
            "No compatible macOS arm64 release is available."
        )
    }

    func test_installPreviewBlocksMissingReleaseAndSignature() {
        let missingRelease = makeSpec(
            pluginId: "osaurus.no-release",
            name: "No Release",
            versions: []
        )
        let missingSignature = makeSpec(
            pluginId: "osaurus.unsigned",
            name: "Unsigned",
            publicKeys: nil,
            minisign: nil
        )

        let missingReleasePreview = PluginInstallPreview(spec: missingRelease)
        let missingSignaturePreview = PluginInstallPreview(spec: missingSignature)

        XCTAssertEqual(missingReleasePreview.state, .unavailable)
        XCTAssertFalse(missingReleasePreview.canInstall)
        XCTAssertEqual(missingReleasePreview.failureReasons, [.missingRegistryRelease])

        XCTAssertEqual(missingSignaturePreview.state, .unavailable)
        XCTAssertFalse(missingSignaturePreview.canInstall)
        XCTAssertEqual(
            missingSignaturePreview.failureReasons,
            [.missingArtifactSignature, .missingRegistrySigningKey]
        )
    }

    func test_catalogOnlyPreviewDisablesInstallActionUntilRegistryRefresh() {
        let entry = CommunityPluginCatalogEntry(
            plugin_id: "osaurus.catalog-only",
            name: "Catalog Only",
            trust: CommunityPluginTrust(trusted: true, source: "fixture")
        )

        let preview = PluginInstallPreview(catalogEntry: entry)

        XCTAssertEqual(preview.state, .unavailable)
        XCTAssertFalse(preview.canInstall)
        XCTAssertEqual(preview.failureReasons, [.missingRegistryRelease])
        XCTAssertEqual(
            preview.primaryBlockingMessage?.message,
            "Registry metadata is unavailable. Refresh the repository before installing."
        )
    }

    func test_primaryBlockingMessageProvidesFailureReasonForRendering() {
        let preview = PluginInstallPreview(
            spec: makeSpec(
                pluginId: "osaurus.unsigned",
                name: "Unsigned",
                minisign: nil
            )
        )

        XCTAssertEqual(preview.primaryBlockingMessage?.severity, .blocking)
        XCTAssertEqual(preview.primaryBlockingMessage?.failureReason, .missingArtifactSignature)
        XCTAssertEqual(
            preview.primaryBlockingMessage?.message,
            "The selected release is missing its minisign signature."
        )
    }

    private func makeSpec(
        pluginId: String,
        name: String,
        version: String = "1.0.0",
        publicKeys: [String: String]? = ["minisign": "trusted-public-key"],
        minisign: MinisignInfo? = MinisignInfo(signature: "trusted-signature", key_id: nil),
        artifactOS: String = "macos",
        versions: [PluginVersionEntry]? = nil
    ) -> PluginSpec {
        PluginSpec(
            plugin_id: pluginId,
            name: name,
            description: "\(name) description",
            license: "MIT",
            public_keys: publicKeys,
            capabilities: RegistryCapabilities(
                tools: [
                    RegistryCapabilities.ToolSummary(
                        name: "\(pluginId).tool",
                        description: "Test tool"
                    ),
                ]
            ),
            versions: versions ?? [
                PluginVersionEntry(
                    version: sv(version),
                    release_date: "2026-06-18",
                    notes: "Fixture release",
                    artifacts: [
                        PluginArtifact(
                            os: artifactOS,
                            arch: "arm64",
                            min_macos: "15.0",
                            url: "https://example.invalid/\(pluginId).zip",
                            sha256: String(repeating: "a", count: 64),
                            minisign: minisign,
                            size: 1024
                        ),
                    ],
                    requires: nil
                ),
            ]
        )
    }

    private func sv(_ version: String) -> SemanticVersion {
        guard let parsed = SemanticVersion.parse(version) else {
            XCTFail("Invalid fixture semantic version: \(version)")
            return SemanticVersion(major: 0, minor: 0, patch: 0)
        }
        return parsed
    }
}
