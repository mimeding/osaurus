//
//  StorageLocationStandardsTests.swift
//
//  Pins the #1422 storage-location audit: data/config/cache resolution,
//  compatibility fallback, stable reason codes, and JSON diagnostics.
//

import Foundation
import OsaurusRepository
import Testing

@testable import OsaurusCore

@Suite
struct StorageLocationStandardsTests {
    private let home = "/Users/sam"
    private let support = "/Users/sam/Library/Application Support"
    private let caches = "/Users/sam/Library/Caches"

    private func makeInputs(
        dataSource: AppDataLocationResolver.LocationSource = .standard,
        configSource: AppDataLocationResolver.LocationSource? = nil,
        cacheSource: AppDataLocationResolver.LocationSource? = nil,
        supportPath: String? = "/Users/sam/Library/Application Support",
        standardDataPresent: Bool = false,
        standardConfigPresent: Bool = false,
        standardCachePresent: Bool = false,
        legacyHomePresent: Bool = false,
        legacyHomeConfigPresent: Bool = false,
        legacyHomeCachePresent: Bool = false,
        legacyApplicationSupportPresent: Bool = false,
        legacyApplicationSupportConfigPresent: Bool = false,
        legacyApplicationSupportCachePresent: Bool = false,
        modelsRootPath: String = "/Users/sam/MLXModels"
    ) -> StorageLocationStandards.Inputs {
        let standardData =
            supportPath.map { "\($0)/Osaurus" } ?? "\(home)/.local/share/osaurus"
        let standardConfig =
            supportPath.map { "\($0)/Osaurus/config" } ?? "\(home)/.config/osaurus"
        let standardCache =
            supportPath.map { _ in "\(caches)/Osaurus" } ?? "\(home)/.cache/osaurus"
        let legacyHome = "\(home)/.osaurus"
        let legacyApplicationSupport = supportPath.map { "\($0)/com.dinoki.osaurus" }

        let resolvedConfigSource = configSource ?? dataSource
        let resolvedCacheSource = cacheSource ?? dataSource
        let data = AppDataLocationResolver.ResolvedLocation(
            kind: .data,
            source: dataSource,
            url: url(pathForData(source: dataSource, standard: standardData, legacyHome: legacyHome,
                                 legacyApplicationSupport: legacyApplicationSupport))
        )
        let config = AppDataLocationResolver.ResolvedLocation(
            kind: .config,
            source: resolvedConfigSource,
            url: url(pathForConfig(source: resolvedConfigSource, standard: standardConfig,
                                   legacyHome: legacyHome,
                                   legacyApplicationSupport: legacyApplicationSupport))
        )
        let cache = AppDataLocationResolver.ResolvedLocation(
            kind: .cache,
            source: resolvedCacheSource,
            url: url(pathForCache(source: resolvedCacheSource, standard: standardCache,
                                  legacyHome: legacyHome,
                                  legacyApplicationSupport: legacyApplicationSupport))
        )

        let candidates = makeCandidates(
            selected: [data, config, cache],
            standardData: standardData,
            standardConfig: standardConfig,
            standardCache: standardCache,
            legacyHome: legacyHome,
            legacyApplicationSupport: legacyApplicationSupport,
            standardDataPresent: standardDataPresent,
            standardConfigPresent: standardConfigPresent,
            standardCachePresent: standardCachePresent,
            legacyHomePresent: legacyHomePresent,
            legacyHomeConfigPresent: legacyHomeConfigPresent,
            legacyHomeCachePresent: legacyHomeCachePresent,
            legacyApplicationSupportPresent: legacyApplicationSupportPresent,
            legacyApplicationSupportConfigPresent: legacyApplicationSupportConfigPresent,
            legacyApplicationSupportCachePresent: legacyApplicationSupportCachePresent
        )
        let locations = AppDataLocationResolver.ResolvedLocations(
            data: data,
            config: config,
            cache: cache,
            candidates: candidates,
            standardDataRoot: url(standardData),
            standardConfigRoot: url(standardConfig),
            standardCacheRoot: url(standardCache),
            legacyHomeRoot: url(legacyHome),
            legacyApplicationSupportRoot: legacyApplicationSupport.map(url)
        )
        return StorageLocationStandards.Inputs(
            locations: locations,
            homeDirectoryPath: home,
            applicationSupportPath: supportPath,
            modelsRootPath: modelsRootPath
        )
    }

    // MARK: - Root classification

    @Test("Standard Application Support data/config/cache locations are compliant")
    func applicationSupportRoot() {
        let report = StorageLocationStandards.audit(
            makeInputs(
                configSource: .standard,
                modelsRootPath: "/Users/sam/Library/Application Support/Osaurus/models"
            )
        )

        #expect(report.classification == .appleApplicationSupport)
        #expect(report.specCompliant)
        #expect(report.dataSource == .standard)
        #expect(report.configSource == .standard)
        #expect(report.cacheSource == .standard)
        #expect(report.reasonCodes.isEmpty)
    }

    @Test("XDG fallback classifies as spec-compliant when Apple directories are unavailable")
    func xdgFallbackRoot() {
        let report = StorageLocationStandards.audit(
            makeInputs(
                configSource: .standard,
                supportPath: nil,
                modelsRootPath: "/Volumes/External/MLXModels"
            )
        )

        #expect(report.classification == .xdgBaseDirectory)
        #expect(report.specCompliant)
        #expect(report.appleSpecCandidateRootPath == nil)
        #expect(report.standardDataRootPath == "/Users/sam/.local/share/osaurus")
        #expect(report.standardConfigRootPath == "/Users/sam/.config/osaurus")
        #expect(report.standardCacheRootPath == "/Users/sam/.cache/osaurus")
    }

    @Test("Existing ~/.osaurus root remains active and reports manual migration")
    func homeDotDirectoryRoot() {
        let report = StorageLocationStandards.audit(
            makeInputs(
                dataSource: .legacyHomeDotDirectory,
                configSource: .legacyHomeDotDirectory,
                legacyHomePresent: true,
                legacyHomeConfigPresent: true
            )
        )

        #expect(report.classification == .homeDotDirectory)
        #expect(!report.specCompliant)
        #expect(report.migrationRequired)
        #expect(
            report.reasonCodes == [
                "root_home_dot_directory_not_apple_spec",
                "config_root_legacy_fallback",
                "cache_root_legacy_fallback",
                "migration_required_manual",
                "models_root_home_visible_by_design",
            ]
        )
        #expect(report.findings[0].message.contains("No data is moved automatically"))
    }

    @Test("Standard candidate present does not override active legacy data")
    func standardCandidatePresentLegacyActive() {
        let report = StorageLocationStandards.audit(
            makeInputs(
                dataSource: .legacyHomeDotDirectory,
                configSource: .legacyHomeDotDirectory,
                standardDataPresent: true,
                legacyHomePresent: true,
                legacyHomeConfigPresent: true,
                modelsRootPath: "/Volumes/External/MLXModels"
            )
        )

        #expect(report.dataSource == .legacyHomeDotDirectory)
        #expect(
            report.reasonCodes == [
                "root_home_dot_directory_not_apple_spec",
                "standard_location_available_legacy_active",
                "config_root_legacy_fallback",
                "cache_root_legacy_fallback",
                "migration_required_manual",
            ]
        )
    }

    @Test("Retired Application Support root is reported as a legacy fallback")
    func legacyApplicationSupportFallback() {
        let report = StorageLocationStandards.audit(
            makeInputs(
                dataSource: .legacyApplicationSupport,
                configSource: .legacyApplicationSupport,
                legacyApplicationSupportPresent: true,
                legacyApplicationSupportConfigPresent: true,
                modelsRootPath: "/Volumes/External/MLXModels"
            )
        )

        #expect(report.classification == .legacyApplicationSupport)
        #expect(report.legacyApplicationSupportRootPresent)
        #expect(
            report.reasonCodes == [
                "data_root_legacy_application_support_fallback",
                "legacy_application_support_root_present",
                "config_root_legacy_fallback",
                "cache_root_legacy_fallback",
                "migration_required_manual",
            ]
        )
        let legacy = report.findings.first {
            $0.code == .legacyApplicationSupportRootPresent
        }
        #expect(legacy?.message.contains("does not copy, merge, or delete") == true)
    }

    @Test("Existing legacy cache fallback keeps diagnostics non-compliant")
    func legacyCacheFallback() {
        let report = StorageLocationStandards.audit(
            makeInputs(
                configSource: .standard,
                cacheSource: .legacyHomeDotDirectory,
                legacyHomeCachePresent: true,
                modelsRootPath: "/Volumes/External/MLXModels"
            )
        )

        #expect(report.classification == .appleApplicationSupport)
        #expect(!report.specCompliant)
        #expect(report.reasonCodes == ["cache_root_legacy_fallback", "migration_required_manual"])
    }

    // MARK: - Overrides

    @Test("Test override reports test_override and suppresses spec assessment")
    func testOverrideClassification() {
        let report = StorageLocationStandards.audit(
            makeInputs(
                dataSource: .testOverride,
                configSource: .testOverride,
                cacheSource: .testOverride,
                modelsRootPath: "/Users/sam/MLXModels"
            )
        )

        #expect(report.classification == .testOverride)
        #expect(!report.specCompliant)
        #expect(report.reasonCodes == ["root_overridden_for_tests"])
    }

    @Test("Environment override reports environment_override")
    func environmentOverrideClassification() {
        let report = StorageLocationStandards.audit(
            makeInputs(
                dataSource: .environmentOverride,
                configSource: .environmentOverride,
                cacheSource: .environmentOverride,
                modelsRootPath: "/Users/sam/MLXModels"
            )
        )

        #expect(report.classification == .environmentOverride)
        #expect(report.reasonCodes == ["root_environment_override"])
    }

    // MARK: - Diagnostic surface stability

    @Test("Reason-code raw values are pinned")
    func reasonCodeRawValuesPinned() {
        let expected: [StorageLocationStandards.ReasonCode: String] = [
            .rootHomeDotDirectoryNotAppleSpec: "root_home_dot_directory_not_apple_spec",
            .dataRootLegacyApplicationSupportFallback:
                "data_root_legacy_application_support_fallback",
            .rootOverriddenForTests: "root_overridden_for_tests",
            .rootEnvironmentOverride: "root_environment_override",
            .rootCustomLocation: "root_custom_location",
            .standardLocationAvailableLegacyActive: "standard_location_available_legacy_active",
            .legacyApplicationSupportRootPresent: "legacy_application_support_root_present",
            .configRootLegacyFallback: "config_root_legacy_fallback",
            .cacheRootLegacyFallback: "cache_root_legacy_fallback",
            .migrationRequiredManual: "migration_required_manual",
            .modelsRootHomeVisibleByDesign: "models_root_home_visible_by_design",
        ]

        #expect(StorageLocationStandards.ReasonCode.allCases.count == expected.count)
        for (code, raw) in expected {
            #expect(code.rawValue == raw)
        }
    }

    @Test("JSON object carries the snake_case diagnostic surface")
    func jsonObjectShape() throws {
        let report = StorageLocationStandards.audit(
            makeInputs(
                dataSource: .legacyHomeDotDirectory,
                configSource: .legacyHomeDotDirectory,
                standardDataPresent: true,
                legacyHomePresent: true,
                legacyHomeConfigPresent: true
            )
        )
        let json = StorageLocationStandards.jsonObject(for: report)

        #expect(
            Set(json.keys) == [
                "classification",
                "spec_compliant",
                "active_root",
                "data_root",
                "data_source",
                "config_root",
                "config_source",
                "cache_root",
                "cache_source",
                "standard_data_root",
                "standard_config_root",
                "standard_cache_root",
                "apple_spec_candidate_root",
                "apple_spec_candidate_root_present",
                "legacy_home_root",
                "legacy_home_root_present",
                "legacy_application_support_root",
                "legacy_application_support_root_present",
                "legacy_application_support_merge_marker",
                "legacy_application_support_merge_marked",
                "migration_required",
                "candidate_locations",
                "models_root",
                "models_root_classification",
                "reason_codes",
                "findings",
                "summary",
            ]
        )
        #expect(json["classification"] as? String == "home_dot_directory")
        #expect(json["data_source"] as? String == "legacy_home_dot_directory")
        #expect(json["config_source"] as? String == "legacy_home_dot_directory")
        #expect(json["cache_source"] as? String == "legacy_home_dot_directory")
        #expect(json["migration_required"] as? Bool == true)

        let candidates = try #require(json["candidate_locations"] as? [[String: Any]])
        #expect(candidates.contains { $0["selected"] as? Bool == true })
        #expect(candidates.contains { $0["source"] as? String == "standard" })
        #expect(JSONSerialization.isValidJSONObject(json))
    }

    @Test("JSON object uses NSNull for absent Application Support path")
    func jsonObjectNullability() {
        let report = StorageLocationStandards.audit(
            makeInputs(configSource: .standard, supportPath: nil)
        )
        let json = StorageLocationStandards.jsonObject(for: report)

        #expect(json["apple_spec_candidate_root"] is NSNull)
        #expect(json["legacy_application_support_root"] is NSNull)
    }

    @Test("Summary stays one stable line")
    func summaryShape() {
        let report = StorageLocationStandards.audit(
            makeInputs(
                dataSource: .legacyHomeDotDirectory,
                configSource: .legacyHomeDotDirectory,
                legacyHomePresent: true,
                legacyHomeConfigPresent: true
            )
        )

        #expect(
            report.summary
                == "data=legacy_home_dot_directory; config=legacy_home_dot_directory; "
                + "cache=legacy_home_dot_directory; needs-attention; migration=required; "
                + "models_root=home_visible"
        )
        #expect(!report.summary.contains("\n"))
    }

    // MARK: - Helpers

    private func makeCandidates(
        selected: [AppDataLocationResolver.ResolvedLocation],
        standardData: String,
        standardConfig: String,
        standardCache: String,
        legacyHome: String,
        legacyApplicationSupport: String?,
        standardDataPresent: Bool,
        standardConfigPresent: Bool,
        standardCachePresent: Bool,
        legacyHomePresent: Bool,
        legacyHomeConfigPresent: Bool,
        legacyHomeCachePresent: Bool,
        legacyApplicationSupportPresent: Bool,
        legacyApplicationSupportConfigPresent: Bool,
        legacyApplicationSupportCachePresent: Bool
    ) -> [AppDataLocationResolver.Candidate] {
        var candidates: [AppDataLocationResolver.Candidate] = []

        func append(
            kind: AppDataLocationResolver.LocationKind,
            source: AppDataLocationResolver.LocationSource,
            path: String,
            exists: Bool
        ) {
            let candidateURL = url(path)
            candidates.append(
                AppDataLocationResolver.Candidate(
                    kind: kind,
                    source: source,
                    url: candidateURL,
                    exists: exists,
                    isSelected: selected.contains {
                        $0.kind == kind
                            && $0.source == source
                            && $0.url.standardizedFileURL.path
                                == candidateURL.standardizedFileURL.path
                    }
                )
            )
        }

        append(kind: .data, source: .standard, path: standardData, exists: standardDataPresent)
        append(
            kind: .data,
            source: .legacyHomeDotDirectory,
            path: legacyHome,
            exists: legacyHomePresent
        )
        if let legacyApplicationSupport {
            append(
                kind: .data,
                source: .legacyApplicationSupport,
                path: legacyApplicationSupport,
                exists: legacyApplicationSupportPresent
            )
        }

        append(
            kind: .config,
            source: .standard,
            path: standardConfig,
            exists: standardConfigPresent
        )
        append(
            kind: .config,
            source: .legacyHomeDotDirectory,
            path: "\(legacyHome)/config",
            exists: legacyHomeConfigPresent
        )
        if let legacyApplicationSupport {
            append(
                kind: .config,
                source: .legacyApplicationSupport,
                path: "\(legacyApplicationSupport)/config",
                exists: legacyApplicationSupportConfigPresent
            )
        }

        append(kind: .cache, source: .standard, path: standardCache, exists: standardCachePresent)
        append(
            kind: .cache,
            source: .legacyHomeDotDirectory,
            path: "\(legacyHome)/cache",
            exists: legacyHomeCachePresent
        )
        if let legacyApplicationSupport {
            append(
                kind: .cache,
                source: .legacyApplicationSupport,
                path: "\(legacyApplicationSupport)/cache",
                exists: legacyApplicationSupportCachePresent
            )
        }

        return candidates
    }

    private func pathForData(
        source: AppDataLocationResolver.LocationSource,
        standard: String,
        legacyHome: String,
        legacyApplicationSupport: String?
    ) -> String {
        switch source {
        case .standard:
            return standard
        case .legacyHomeDotDirectory:
            return legacyHome
        case .legacyApplicationSupport:
            return legacyApplicationSupport ?? standard
        case .testOverride:
            return "/tmp/osaurus-test-root"
        case .environmentOverride:
            return "/tmp/osaurus-env-root"
        }
    }

    private func pathForConfig(
        source: AppDataLocationResolver.LocationSource,
        standard: String,
        legacyHome: String,
        legacyApplicationSupport: String?
    ) -> String {
        switch source {
        case .standard:
            return standard
        case .legacyHomeDotDirectory:
            return "\(legacyHome)/config"
        case .legacyApplicationSupport:
            return legacyApplicationSupport.map { "\($0)/config" } ?? standard
        case .testOverride:
            return "/tmp/osaurus-test-root/config"
        case .environmentOverride:
            return "/tmp/osaurus-env-root/config"
        }
    }

    private func pathForCache(
        source: AppDataLocationResolver.LocationSource,
        standard: String,
        legacyHome: String,
        legacyApplicationSupport: String?
    ) -> String {
        switch source {
        case .standard:
            return standard
        case .legacyHomeDotDirectory:
            return "\(legacyHome)/cache"
        case .legacyApplicationSupport:
            return legacyApplicationSupport.map { "\($0)/cache" } ?? standard
        case .testOverride:
            return "/tmp/osaurus-test-root/cache"
        case .environmentOverride:
            return "/tmp/osaurus-env-root/cache"
        }
    }

    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }
}
