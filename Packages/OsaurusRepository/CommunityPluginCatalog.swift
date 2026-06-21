//
//  CommunityPluginCatalog.swift
//  osaurus
//
//  Trusted community plugin catalog metadata and install-preview helpers.
//

import Foundation

public struct CommunityPluginTrust: Codable, Equatable, Sendable {
    public let trusted: Bool
    public let source: String?
    public let reviewed_by: String?
    public let notes: String?

    public init(
        trusted: Bool = true,
        source: String? = nil,
        reviewed_by: String? = nil,
        notes: String? = nil
    ) {
        self.trusted = trusted
        self.source = source
        self.reviewed_by = reviewed_by
        self.notes = notes
    }
}

public struct CommunityPluginCatalogEntry: Codable, Equatable, Identifiable, Sendable {
    public let plugin_id: String
    public let name: String?
    public let summary: String?
    public let category: String?
    public let tags: [String]
    public let highlight: String?
    public let install_note: String?
    public let homepage: String?
    public let featured: Bool
    public let sort_rank: Int?
    public let trust: CommunityPluginTrust?

    public var id: String { plugin_id }

    public init(
        plugin_id: String,
        name: String? = nil,
        summary: String? = nil,
        category: String? = nil,
        tags: [String] = [],
        highlight: String? = nil,
        install_note: String? = nil,
        homepage: String? = nil,
        featured: Bool = false,
        sort_rank: Int? = nil,
        trust: CommunityPluginTrust? = nil
    ) {
        self.plugin_id = plugin_id
        self.name = name
        self.summary = summary
        self.category = category
        self.tags = tags
        self.highlight = highlight
        self.install_note = install_note
        self.homepage = homepage
        self.featured = featured
        self.sort_rank = sort_rank
        self.trust = trust
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plugin_id = try container.decode(String.self, forKey: .plugin_id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        highlight = try container.decodeIfPresent(String.self, forKey: .highlight)
        install_note = try container.decodeIfPresent(String.self, forKey: .install_note)
        homepage = try container.decodeIfPresent(String.self, forKey: .homepage)
        featured = try container.decodeIfPresent(Bool.self, forKey: .featured) ?? false
        sort_rank = try container.decodeIfPresent(Int.self, forKey: .sort_rank)
        trust = try container.decodeIfPresent(CommunityPluginTrust.self, forKey: .trust)
    }
}

public struct CommunityPluginCatalog: Codable, Equatable, Sendable {
    public let schema_version: Int
    public let source_name: String?
    public let source_url: String?
    public let trusted_registry_url: String?
    public let generated_at: String?
    public let plugins: [CommunityPluginCatalogEntry]

    public static let empty = CommunityPluginCatalog(schema_version: 1, plugins: [])

    public init(
        schema_version: Int,
        source_name: String? = nil,
        source_url: String? = nil,
        trusted_registry_url: String? = nil,
        generated_at: String? = nil,
        plugins: [CommunityPluginCatalogEntry]
    ) {
        self.schema_version = schema_version
        self.source_name = source_name
        self.source_url = source_url
        self.trusted_registry_url = trusted_registry_url
        self.generated_at = generated_at
        self.plugins = plugins
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema_version = try container.decodeIfPresent(Int.self, forKey: .schema_version) ?? 1
        source_name = try container.decodeIfPresent(String.self, forKey: .source_name)
        source_url = try container.decodeIfPresent(String.self, forKey: .source_url)
        trusted_registry_url = try container.decodeIfPresent(String.self, forKey: .trusted_registry_url)
        generated_at = try container.decodeIfPresent(String.self, forKey: .generated_at)
        plugins = try container.decodeIfPresent([CommunityPluginCatalogEntry].self, forKey: .plugins) ?? []
    }

    public var entriesByPluginId: [String: CommunityPluginCatalogEntry] {
        plugins.reduce(into: [:]) { result, entry in
            result[entry.plugin_id] = entry
        }
    }

    public func entry(for pluginId: String) -> CommunityPluginCatalogEntry? {
        entriesByPluginId[pluginId]
    }
}

public struct CommunityPluginCategory: Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let count: Int

    public init(id: String, displayName: String, count: Int) {
        self.id = id
        self.displayName = displayName
        self.count = count
    }
}

public enum CommunityPluginInstallFilter: Equatable, Sendable {
    case all
    case installed
    case available
    case updates
}

public struct CommunityPluginBrowserItem: Equatable, Identifiable, Sendable {
    public let spec: PluginSpec
    public let catalogEntry: CommunityPluginCatalogEntry?
    public let installedVersion: SemanticVersion?

    public var id: String { pluginId }
    public var pluginId: String { spec.plugin_id }
    public var displayName: String { spec.name ?? catalogEntry?.name ?? pluginId }
    public var summary: String? { spec.description ?? catalogEntry?.summary }
    public var latestVersion: SemanticVersion? { spec.versions.map(\.version).max() }
    public var isInstalled: Bool { installedVersion != nil }
    public var isFeatured: Bool { catalogEntry?.featured ?? false }
    public var tags: [String] { catalogEntry?.tags ?? [] }

    public var categoryKey: String {
        Self.categoryKey(for: catalogEntry?.category)
    }

    public var categoryDisplayName: String {
        Self.displayName(forCategoryKey: categoryKey)
    }

    public init(
        spec: PluginSpec,
        catalogEntry: CommunityPluginCatalogEntry?,
        installedVersion: SemanticVersion? = nil
    ) {
        self.spec = spec
        self.catalogEntry = catalogEntry
        self.installedVersion = installedVersion
    }

    public static func categoryKey(for raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let trimmed, !trimmed.isEmpty else { return "registry" }
        return trimmed
            .split(whereSeparator: { $0 == " " || $0 == "_" })
            .joined(separator: "-")
    }

    public static func displayName(forCategoryKey key: String) -> String {
        key.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

public struct CommunityPluginCatalogIndex: Sendable {
    public let catalog: CommunityPluginCatalog
    public let items: [CommunityPluginBrowserItem]

    public init(
        catalog: CommunityPluginCatalog,
        items: [CommunityPluginBrowserItem]
    ) {
        self.catalog = catalog
        self.items = items.sorted(by: Self.sortItems)
    }

    public init(
        catalog: CommunityPluginCatalog,
        specs: [PluginSpec],
        installedVersionsByPluginId: [String: SemanticVersion] = [:],
        includeUncatalogedSpecs: Bool = true
    ) {
        let catalogById = catalog.entriesByPluginId
        let filteredSpecs = includeUncatalogedSpecs
            ? specs
            : specs.filter { catalogById[$0.plugin_id] != nil }
        self.init(
            catalog: catalog,
            items: filteredSpecs.map {
                CommunityPluginBrowserItem(
                    spec: $0,
                    catalogEntry: catalogById[$0.plugin_id],
                    installedVersion: installedVersionsByPluginId[$0.plugin_id]
                )
            }
        )
    }

    public var categories: [CommunityPluginCategory] {
        let counts = Dictionary(grouping: items, by: \.categoryKey).mapValues(\.count)
        return counts.map { key, count in
            CommunityPluginCategory(
                id: key,
                displayName: CommunityPluginBrowserItem.displayName(forCategoryKey: key),
                count: count
            )
        }
        .sorted { lhs, rhs in
            if lhs.id == "registry" { return false }
            if rhs.id == "registry" { return true }
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.displayName.lowercased() < rhs.displayName.lowercased()
        }
    }

    public func filtered(
        query: String = "",
        category: String? = nil,
        installFilter: CommunityPluginInstallFilter = .all,
        queryMatcher: @Sendable (_ normalizedQuery: String, _ candidate: String) -> Bool = { query, candidate in
            candidate.contains(query)
        }
    ) -> [CommunityPluginBrowserItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedCategory = category.map { CommunityPluginBrowserItem.categoryKey(for: $0) }
        return items.filter { item in
            if let normalizedCategory, item.categoryKey != normalizedCategory { return false }
            if !matchesInstallFilter(item, installFilter: installFilter) { return false }
            guard !normalizedQuery.isEmpty else { return true }
            return item.searchCandidates.contains { queryMatcher(normalizedQuery, $0) }
        }
    }

    private static func sortItems(
        _ lhs: CommunityPluginBrowserItem,
        _ rhs: CommunityPluginBrowserItem
    ) -> Bool {
        let lhsRank = lhs.catalogEntry?.sort_rank ?? Int.max
        let rhsRank = rhs.catalogEntry?.sort_rank ?? Int.max
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        if lhs.isFeatured != rhs.isFeatured { return lhs.isFeatured && !rhs.isFeatured }
        return lhs.displayName.lowercased() < rhs.displayName.lowercased()
    }

    private func matchesInstallFilter(
        _ item: CommunityPluginBrowserItem,
        installFilter: CommunityPluginInstallFilter
    ) -> Bool {
        switch installFilter {
        case .all:
            return true
        case .installed:
            return item.isInstalled
        case .available:
            return !item.isInstalled
        case .updates:
            guard let installed = item.installedVersion,
                let latest = item.latestVersion
            else { return false }
            return latest > installed
        }
    }
}

public enum PluginInstallPreviewState: String, Equatable, Sendable {
    case installable
    case updateAvailable
    case installed
    case unavailable
}

public enum PluginInstallPreviewSeverity: String, Equatable, Sendable {
    case info
    case warning
    case blocking
}

public struct PluginInstallPreviewMessage: Equatable, Sendable {
    public let severity: PluginInstallPreviewSeverity
    public let message: String

    public init(severity: PluginInstallPreviewSeverity, message: String) {
        self.severity = severity
        self.message = message
    }
}

public struct PluginInstallPreview: Equatable, Sendable {
    public let pluginId: String
    public let displayName: String
    public let state: PluginInstallPreviewState
    public let targetVersion: SemanticVersion?
    public let installedVersion: SemanticVersion?
    public let artifactURL: String?
    public let artifactSize: Int?
    public let releaseNotes: String?
    public let category: String?
    public let tags: [String]
    public let installNote: String?
    public let toolCount: Int
    public let skillCount: Int
    public let messages: [PluginInstallPreviewMessage]

    public var canInstall: Bool {
        state == .installable || state == .updateAvailable
    }

    public init(
        spec: PluginSpec,
        catalogEntry: CommunityPluginCatalogEntry? = nil,
        installedVersion: SemanticVersion? = nil,
        preferredVersion: SemanticVersion? = nil,
        targetPlatform: Platform = .macos,
        targetArch: CPUArch = .arm64
    ) {
        pluginId = spec.plugin_id
        displayName = spec.name ?? catalogEntry?.name ?? spec.plugin_id
        self.installedVersion = installedVersion
        category = catalogEntry?.category
        tags = catalogEntry?.tags ?? []
        installNote = catalogEntry?.install_note
        toolCount = spec.capabilities?.tools?.count ?? 0
        skillCount = spec.capabilities?.skills?.count ?? 0

        var previewMessages: [PluginInstallPreviewMessage] = []
        if catalogEntry?.trust?.trusted == true {
            previewMessages.append(
                PluginInstallPreviewMessage(
                    severity: .info,
                    message: "Listed by the trusted community catalog."
                )
            )
        }

        do {
            let resolution = try spec.resolveBestVersion(
                targetPlatform: targetPlatform,
                targetArch: targetArch,
                minimumOsaurusVersion: nil,
                preferredVersion: preferredVersion
            )
            targetVersion = resolution.version.version
            artifactURL = resolution.artifact.url
            artifactSize = resolution.artifact.size
            releaseNotes = resolution.version.notes

            if resolution.artifact.minisign == nil || spec.public_keys?["minisign"] == nil {
                previewMessages.append(
                    PluginInstallPreviewMessage(
                        severity: .blocking,
                        message: "A signed release is required before this plugin can be installed."
                    )
                )
                messages = previewMessages
                state = .unavailable
                return
            }

            if let size = resolution.artifact.size,
                Int64(size) > PluginInstallManager.maximumArtifactArchiveBytes {
                previewMessages.append(
                    PluginInstallPreviewMessage(
                        severity: .blocking,
                        message: "The release archive exceeds the installer size limit."
                    )
                )
                messages = previewMessages
                state = .unavailable
                return
            }

            if let installedVersion {
                if installedVersion < resolution.version.version {
                    state = .updateAvailable
                } else {
                    state = .installed
                }
            } else {
                state = .installable
            }
            messages = previewMessages
        } catch {
            targetVersion = nil
            artifactURL = nil
            artifactSize = nil
            releaseNotes = nil
            previewMessages.append(
                PluginInstallPreviewMessage(
                    severity: .blocking,
                    message: "No compatible macOS arm64 release is available."
                )
            )
            messages = previewMessages
            state = .unavailable
        }
    }
}

private extension CommunityPluginBrowserItem {
    var searchCandidates: [String] {
        var candidates = [
            pluginId,
            displayName,
            summary ?? "",
            categoryDisplayName,
        ]
        candidates.append(contentsOf: tags)
        candidates.append(contentsOf: spec.authors ?? [])
        candidates.append(spec.license ?? "")
        return candidates.map { $0.lowercased() }
    }
}
