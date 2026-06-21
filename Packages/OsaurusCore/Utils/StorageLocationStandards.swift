//
//  StorageLocationStandards.swift
//  osaurus
//
//  Storage-location standards audit for issue #1422.
//

import Foundation
import OsaurusRepository

/// Read-only storage-location audit. Path resolution lives in
/// `AppDataLocationResolver`; this module turns the resolved data/config/cache
/// roots into a stable diagnostic surface for `/admin/cache-stats`.
public enum StorageLocationStandards {

    // MARK: - Model

    public enum RootClassification: String, Sendable {
        case appleApplicationSupport = "apple_application_support"
        case xdgBaseDirectory = "xdg_base_directory"
        case homeDotDirectory = "home_dot_directory"
        case legacyApplicationSupport = "legacy_application_support"
        case testOverride = "test_override"
        case environmentOverride = "environment_override"
        case custom
    }

    /// Classification of the model-weights root, reported separately from
    /// app data because user-managed weights remain home-visible by design.
    public enum ModelsRootClassification: String, Sendable {
        case applicationSupport = "application_support"
        case homeVisible = "home_visible"
        case externalOrCustom = "external_or_custom"
    }

    /// Stable, machine-readable reason codes. These are part of the
    /// diagnostic surface; avoid renaming existing raw values.
    public enum ReasonCode: String, CaseIterable, Sendable {
        case rootHomeDotDirectoryNotAppleSpec = "root_home_dot_directory_not_apple_spec"
        case dataRootLegacyApplicationSupportFallback =
            "data_root_legacy_application_support_fallback"
        case rootOverriddenForTests = "root_overridden_for_tests"
        case rootEnvironmentOverride = "root_environment_override"
        case rootCustomLocation = "root_custom_location"
        case standardLocationAvailableLegacyActive = "standard_location_available_legacy_active"
        case legacyApplicationSupportRootPresent = "legacy_application_support_root_present"
        case configRootLegacyFallback = "config_root_legacy_fallback"
        case cacheRootLegacyFallback = "cache_root_legacy_fallback"
        case migrationRequiredManual = "migration_required_manual"
        case modelsRootHomeVisibleByDesign = "models_root_home_visible_by_design"
    }

    public enum Severity: String, Sendable {
        case info
        case warning
    }

    /// One audited fact with a stable code and a human-readable explanation.
    public struct Finding: Equatable, Sendable {
        public let code: ReasonCode
        public let severity: Severity
        public let message: String

        public init(code: ReasonCode, severity: Severity, message: String) {
            self.code = code
            self.severity = severity
            self.message = message
        }
    }

    /// Everything the pure classifier needs. Built by `currentInputs()` in
    /// production; built by hand in tests.
    public struct Inputs: Equatable, Sendable {
        public let locations: AppDataLocationResolver.ResolvedLocations
        public let homeDirectoryPath: String
        public let applicationSupportPath: String?
        public let legacyApplicationSupportMergeMarkerPath: String?
        public let legacyApplicationSupportMergeMarked: Bool
        public let modelsRootPath: String

        public init(
            locations: AppDataLocationResolver.ResolvedLocations,
            homeDirectoryPath: String,
            applicationSupportPath: String?,
            legacyApplicationSupportMergeMarkerPath: String? = nil,
            legacyApplicationSupportMergeMarked: Bool = false,
            modelsRootPath: String
        ) {
            self.locations = locations
            self.homeDirectoryPath = homeDirectoryPath
            self.applicationSupportPath = applicationSupportPath
            self.legacyApplicationSupportMergeMarkerPath = legacyApplicationSupportMergeMarkerPath
            self.legacyApplicationSupportMergeMarked = legacyApplicationSupportMergeMarked
            self.modelsRootPath = modelsRootPath
        }
    }

    /// Audit result. `reasonCodes` mirrors `findings` for compact consumers.
    public struct Report: Equatable, Sendable {
        public let classification: RootClassification
        public let specCompliant: Bool
        public let dataRootPath: String
        public let dataSource: AppDataLocationResolver.LocationSource
        public let configRootPath: String
        public let configSource: AppDataLocationResolver.LocationSource
        public let cacheRootPath: String
        public let cacheSource: AppDataLocationResolver.LocationSource
        public let standardDataRootPath: String
        public let standardConfigRootPath: String
        public let standardCacheRootPath: String
        public let appleSpecCandidateRootPath: String?
        public let appleSpecCandidateRootPresent: Bool
        public let legacyHomeRootPath: String
        public let legacyHomeRootPresent: Bool
        public let legacyApplicationSupportRootPath: String?
        public let legacyApplicationSupportRootPresent: Bool
        public let legacyApplicationSupportMergeMarkerPath: String?
        public let legacyApplicationSupportMergeMarked: Bool
        public let migrationRequired: Bool
        public let candidateLocations: [AppDataLocationResolver.Candidate]
        public let modelsRootPath: String
        public let modelsRootClassification: ModelsRootClassification
        public let findings: [Finding]

        /// Backward-compatible alias for the active data root.
        public var activeRootPath: String { dataRootPath }

        public var reasonCodes: [String] {
            findings.map { $0.code.rawValue }
        }

        public var summary: String {
            let compliance = specCompliant ? "spec-compliant" : "needs-attention"
            let migration = migrationRequired ? "required" : "not_required"
            return "data=\(dataSource.rawValue); "
                + "config=\(configSource.rawValue); "
                + "cache=\(cacheSource.rawValue); "
                + "\(compliance); migration=\(migration); "
                + "models_root=\(modelsRootClassification.rawValue)"
        }

        public init(
            classification: RootClassification,
            specCompliant: Bool,
            dataRootPath: String,
            dataSource: AppDataLocationResolver.LocationSource,
            configRootPath: String,
            configSource: AppDataLocationResolver.LocationSource,
            cacheRootPath: String,
            cacheSource: AppDataLocationResolver.LocationSource,
            standardDataRootPath: String,
            standardConfigRootPath: String,
            standardCacheRootPath: String,
            appleSpecCandidateRootPath: String?,
            appleSpecCandidateRootPresent: Bool,
            legacyHomeRootPath: String,
            legacyHomeRootPresent: Bool,
            legacyApplicationSupportRootPath: String?,
            legacyApplicationSupportRootPresent: Bool,
            legacyApplicationSupportMergeMarkerPath: String?,
            legacyApplicationSupportMergeMarked: Bool,
            migrationRequired: Bool,
            candidateLocations: [AppDataLocationResolver.Candidate],
            modelsRootPath: String,
            modelsRootClassification: ModelsRootClassification,
            findings: [Finding]
        ) {
            self.classification = classification
            self.specCompliant = specCompliant
            self.dataRootPath = dataRootPath
            self.dataSource = dataSource
            self.configRootPath = configRootPath
            self.configSource = configSource
            self.cacheRootPath = cacheRootPath
            self.cacheSource = cacheSource
            self.standardDataRootPath = standardDataRootPath
            self.standardConfigRootPath = standardConfigRootPath
            self.standardCacheRootPath = standardCacheRootPath
            self.appleSpecCandidateRootPath = appleSpecCandidateRootPath
            self.appleSpecCandidateRootPresent = appleSpecCandidateRootPresent
            self.legacyHomeRootPath = legacyHomeRootPath
            self.legacyHomeRootPresent = legacyHomeRootPresent
            self.legacyApplicationSupportRootPath = legacyApplicationSupportRootPath
            self.legacyApplicationSupportRootPresent = legacyApplicationSupportRootPresent
            self.legacyApplicationSupportMergeMarkerPath = legacyApplicationSupportMergeMarkerPath
            self.legacyApplicationSupportMergeMarked = legacyApplicationSupportMergeMarked
            self.migrationRequired = migrationRequired
            self.candidateLocations = candidateLocations
            self.modelsRootPath = modelsRootPath
            self.modelsRootClassification = modelsRootClassification
            self.findings = findings
        }
    }

    // MARK: - Live probe (read-only)

    public static let legacyApplicationSupportFolderName =
        AppDataLocationResolver.legacyApplicationSupportFolderName
    public static let appleSpecCandidateFolderName =
        AppDataLocationResolver.standardApplicationSupportFolderName

    /// Gather live inputs. Read-only: reports the same resolved locations used
    /// by `OsaurusPaths` and never creates, copies, moves, or deletes anything.
    public static func currentInputs(fileManager fm: FileManager = .default) -> Inputs {
        let locations = OsaurusPaths.resolvedLocations()
        let mergeMarker = OsaurusPaths.legacyApplicationSupportMergeMarker(
            for: locations.dataRoot
        )
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return Inputs(
            locations: locations,
            homeDirectoryPath: fm.homeDirectoryForCurrentUser.path,
            applicationSupportPath: support?.path,
            legacyApplicationSupportMergeMarkerPath: mergeMarker.path,
            legacyApplicationSupportMergeMarked: fm.fileExists(atPath: mergeMarker.path),
            modelsRootPath: DirectoryPickerService.effectiveModelsDirectory().path
        )
    }

    /// Convenience: live probe + pure classification.
    public static func currentReport(fileManager: FileManager = .default) -> Report {
        audit(currentInputs(fileManager: fileManager))
    }

    // MARK: - Pure classification

    public static func audit(_ inputs: Inputs) -> Report {
        let locations = inputs.locations
        let classification = classifyRoot(inputs)
        let modelsClassification = classifyModelsRoot(inputs)
        let migrationRequired = requiresManualMigration(locations)
        var findings: [Finding] = []

        switch classification {
        case .appleApplicationSupport, .xdgBaseDirectory:
            break
        case .homeDotDirectory:
            findings.append(
                Finding(
                    code: .rootHomeDotDirectoryNotAppleSpec,
                    severity: .warning,
                    message:
                        "Using legacy app data root \(locations.dataRoot.path) because it "
                        + "already exists. New installs use "
                        + "\(locations.standardDataRoot.path). No data is moved automatically; "
                        + "back up or export data before a manual migration."
                )
            )
        case .legacyApplicationSupport:
            findings.append(
                Finding(
                    code: .dataRootLegacyApplicationSupportFallback,
                    severity: .warning,
                    message:
                        "Using retired Application Support root \(locations.dataRoot.path) "
                        + "because it already exists and no newer data root was selected. "
                        + "No data is moved automatically."
                )
            )
        case .testOverride:
            findings.append(
                Finding(
                    code: .rootOverriddenForTests,
                    severity: .info,
                    message:
                        "Storage root is overridden via OsaurusPaths.overrideRoot for tests; "
                        + "spec compliance was not assessed."
                )
            )
        case .environmentOverride:
            findings.append(
                Finding(
                    code: .rootEnvironmentOverride,
                    severity: .info,
                    message:
                        "Storage root is overridden via OSAURUS_TEST_ROOT; "
                        + "spec compliance was not assessed."
                )
            )
        case .custom:
            findings.append(
                Finding(
                    code: .rootCustomLocation,
                    severity: .info,
                    message:
                        "Storage root \(locations.dataRoot.path) is neither a standard "
                        + "Apple/XDG location nor a known legacy location."
                )
            )
        }

        if locations.usesLegacyDataRoot && candidateExists(locations, kind: .data, source: .standard) {
            findings.append(
                Finding(
                    code: .standardLocationAvailableLegacyActive,
                    severity: .info,
                    message:
                        "Standard data root \(locations.standardDataRoot.path) exists, but "
                        + "legacy root \(locations.dataRoot.path) remains active to avoid "
                        + "silently switching away from existing user data."
                )
            )
        }

        let legacySupportPresent = candidateExists(
            locations,
            kind: .data,
            source: .legacyApplicationSupport
        )
        if legacySupportPresent {
            findings.append(
                Finding(
                    code: .legacyApplicationSupportRootPresent,
                    severity: locations.data.source == .legacyApplicationSupport ? .warning : .info,
                    message:
                        "Retired Application Support root "
                        + "\(locations.legacyApplicationSupportRoot?.path ?? legacyApplicationSupportFolderName) "
                        + "still exists. The resolver reports it as a legacy fallback and "
                        + "does not copy, merge, or delete it."
                )
            )
        }

        if isLegacy(locations.config.source) {
            findings.append(
                Finding(
                    code: .configRootLegacyFallback,
                    severity: .warning,
                    message:
                        "Configuration root \(locations.configRoot.path) is a legacy "
                        + "location selected for compatibility with existing files."
                )
            )
        }

        if isLegacy(locations.cache.source) {
            let cacheReason =
                locations.usesLegacyDataRoot
                ? "to stay with the resolved legacy data root family."
                : "because an existing cache directory was found."
            findings.append(
                Finding(
                    code: .cacheRootLegacyFallback,
                    severity: .info,
                    message:
                        "Cache root \(locations.cacheRoot.path) is a legacy location "
                        + cacheReason
                )
            )
        }

        if migrationRequired {
            findings.append(
                Finding(
                    code: .migrationRequiredManual,
                    severity: .info,
                    message:
                        "A manual migration is required before all app data can use "
                        + "standard Apple/XDG locations. The resolver only selects safe "
                        + "fallbacks and never moves user data."
                )
            )
        }

        let usesOverride =
            locations.data.source == .testOverride || locations.data.source == .environmentOverride
        if !usesOverride && modelsClassification == .homeVisible {
            findings.append(
                Finding(
                    code: .modelsRootHomeVisibleByDesign,
                    severity: .info,
                    message:
                        "Model weights root \(inputs.modelsRootPath) is a home-visible "
                        + "folder (user-managed weights by design); it is a separate "
                        + "decision from the app-data root."
                )
            )
        }

        let mergeMarkerPath = inputs.legacyApplicationSupportMergeMarkerPath
            ?? OsaurusPaths.legacyApplicationSupportMergeMarker(for: locations.dataRoot).path
        return Report(
            classification: classification,
            specCompliant: isSpecCompliant(classification, locations),
            dataRootPath: locations.dataRoot.path,
            dataSource: locations.data.source,
            configRootPath: locations.configRoot.path,
            configSource: locations.config.source,
            cacheRootPath: locations.cacheRoot.path,
            cacheSource: locations.cache.source,
            standardDataRootPath: locations.standardDataRoot.path,
            standardConfigRootPath: locations.standardConfigRoot.path,
            standardCacheRootPath: locations.standardCacheRoot.path,
            appleSpecCandidateRootPath: appleCandidatePath(inputs, locations: locations),
            appleSpecCandidateRootPresent: candidateExists(
                locations,
                kind: .data,
                source: .standard
            ),
            legacyHomeRootPath: locations.legacyHomeRoot.path,
            legacyHomeRootPresent: candidateExists(
                locations,
                kind: .data,
                source: .legacyHomeDotDirectory
            ),
            legacyApplicationSupportRootPath: locations.legacyApplicationSupportRoot?.path,
            legacyApplicationSupportRootPresent: legacySupportPresent,
            legacyApplicationSupportMergeMarkerPath: mergeMarkerPath,
            legacyApplicationSupportMergeMarked: inputs.legacyApplicationSupportMergeMarked,
            migrationRequired: migrationRequired,
            candidateLocations: locations.candidates,
            modelsRootPath: inputs.modelsRootPath,
            modelsRootClassification: modelsClassification,
            findings: findings
        )
    }

    // MARK: - JSON

    /// Snake-case JSON object for `/admin/cache-stats`. Mirrors the
    /// `memory_safety` block conventions (NSNull for absent optionals).
    public static func jsonObject(for report: Report) -> [String: Any] {
        [
            "classification": report.classification.rawValue,
            "spec_compliant": report.specCompliant,
            "active_root": report.activeRootPath,
            "data_root": report.dataRootPath,
            "data_source": report.dataSource.rawValue,
            "config_root": report.configRootPath,
            "config_source": report.configSource.rawValue,
            "cache_root": report.cacheRootPath,
            "cache_source": report.cacheSource.rawValue,
            "standard_data_root": report.standardDataRootPath,
            "standard_config_root": report.standardConfigRootPath,
            "standard_cache_root": report.standardCacheRootPath,
            "apple_spec_candidate_root": report.appleSpecCandidateRootPath as Any? ?? NSNull(),
            "apple_spec_candidate_root_present": report.appleSpecCandidateRootPresent,
            "legacy_home_root": report.legacyHomeRootPath,
            "legacy_home_root_present": report.legacyHomeRootPresent,
            "legacy_application_support_root": report.legacyApplicationSupportRootPath as Any?
                ?? NSNull(),
            "legacy_application_support_root_present": report.legacyApplicationSupportRootPresent,
            "legacy_application_support_merge_marker":
                report.legacyApplicationSupportMergeMarkerPath as Any? ?? NSNull(),
            "legacy_application_support_merge_marked": report.legacyApplicationSupportMergeMarked,
            "migration_required": report.migrationRequired,
            "candidate_locations": report.candidateLocations.map { candidate in
                [
                    "kind": candidate.kind.rawValue,
                    "source": candidate.source.rawValue,
                    "path": candidate.url.path,
                    "exists": candidate.exists,
                    "selected": candidate.isSelected,
                ]
            },
            "models_root": report.modelsRootPath,
            "models_root_classification": report.modelsRootClassification.rawValue,
            "reason_codes": report.reasonCodes,
            "findings": report.findings.map { finding in
                [
                    "code": finding.code.rawValue,
                    "severity": finding.severity.rawValue,
                    "message": finding.message,
                ]
            },
            "summary": report.summary,
        ]
    }

    // MARK: - Helpers

    private static func classifyRoot(_ inputs: Inputs) -> RootClassification {
        let locations = inputs.locations
        switch locations.data.source {
        case .testOverride:
            return .testOverride
        case .environmentOverride:
            return .environmentOverride
        case .legacyHomeDotDirectory:
            return .homeDotDirectory
        case .legacyApplicationSupport:
            return .legacyApplicationSupport
        case .standard:
            if let support = inputs.applicationSupportPath,
                isSubpath(locations.dataRoot.path, of: support) {
                return .appleApplicationSupport
            }
            if samePath(locations.dataRoot.path, locations.standardDataRoot.path) {
                return .xdgBaseDirectory
            }
            return .custom
        }
    }

    private static func classifyModelsRoot(_ inputs: Inputs) -> ModelsRootClassification {
        if let support = inputs.applicationSupportPath,
            isSubpath(inputs.modelsRootPath, of: support) {
            return .applicationSupport
        }
        if isSubpath(inputs.modelsRootPath, of: inputs.homeDirectoryPath) {
            return .homeVisible
        }
        return .externalOrCustom
    }

    private static func isSpecCompliant(
        _ classification: RootClassification,
        _ locations: AppDataLocationResolver.ResolvedLocations
    ) -> Bool {
        switch classification {
        case .appleApplicationSupport, .xdgBaseDirectory:
            return locations.data.source == .standard
                && locations.config.source == .standard
                && locations.cache.source == .standard
        case .homeDotDirectory,
             .legacyApplicationSupport,
             .testOverride,
             .environmentOverride,
             .custom:
            return false
        }
    }

    private static func requiresManualMigration(
        _ locations: AppDataLocationResolver.ResolvedLocations
    ) -> Bool {
        locations.usesLegacyDataRoot
            || isLegacy(locations.config.source)
            || isLegacy(locations.cache.source)
    }

    private static func candidateExists(
        _ locations: AppDataLocationResolver.ResolvedLocations,
        kind: AppDataLocationResolver.LocationKind,
        source: AppDataLocationResolver.LocationSource
    ) -> Bool {
        locations.candidates.contains {
            $0.kind == kind && $0.source == source && $0.exists
        }
    }

    private static func isLegacy(_ source: AppDataLocationResolver.LocationSource) -> Bool {
        source == .legacyHomeDotDirectory || source == .legacyApplicationSupport
    }

    private static func appleCandidatePath(
        _ inputs: Inputs,
        locations: AppDataLocationResolver.ResolvedLocations
    ) -> String? {
        guard inputs.applicationSupportPath != nil else { return nil }
        return locations.standardDataRoot.path
    }

    private static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).standardizedFileURL.path
            == URL(fileURLWithPath: rhs).standardizedFileURL.path
    }

    private static func isSubpath(_ path: String, of parent: String) -> Bool {
        let child = URL(fileURLWithPath: path).standardizedFileURL.path
        let base = URL(fileURLWithPath: parent).standardizedFileURL.path
        if child == base {
            return true
        }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return child.hasPrefix(prefix)
    }
}
