//
//  WorkspaceContextSourceWorkbenchPresenter.swift
//  osaurus
//
//  Presentation helpers for the workspace context source inventory. Kept
//  separate from SwiftUI so the proof layer can be tested without UI scope.
//

import Foundation

public struct WorkspaceContextSourceWorkbenchRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var kindLabel: String
    public var statusLabel: String
    public var badges: [String]
    public var warningText: String?
    public var isEffective: Bool

    public init(
        id: String,
        title: String,
        subtitle: String,
        kindLabel: String,
        statusLabel: String,
        badges: [String],
        warningText: String?,
        isEffective: Bool
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.kindLabel = kindLabel
        self.statusLabel = statusLabel
        self.badges = badges
        self.warningText = warningText
        self.isEffective = isEffective
    }
}

public struct WorkspaceContextSourceWorkbenchSummary: Equatable, Sendable {
    public var totalSources: Int
    public var effectiveSources: Int
    public var rejectedSources: Int
    public var duplicateSources: Int
    public var staleSources: Int
    public var missingSources: Int
    public var disabledSources: Int

    public init(
        totalSources: Int,
        effectiveSources: Int,
        rejectedSources: Int,
        duplicateSources: Int,
        staleSources: Int,
        missingSources: Int,
        disabledSources: Int
    ) {
        self.totalSources = totalSources
        self.effectiveSources = effectiveSources
        self.rejectedSources = rejectedSources
        self.duplicateSources = duplicateSources
        self.staleSources = staleSources
        self.missingSources = missingSources
        self.disabledSources = disabledSources
    }
}

public enum WorkspaceContextSourceWorkbenchPresenter {
    public static func rows(
        for inventory: WorkspaceContextSourceInventory
    ) -> [WorkspaceContextSourceWorkbenchRow] {
        inventory.records.map { record in
            let provenance = record.source.provenance
            let subtitle = provenance?.displayPath
                ?? provenance?.stableId
                ?? record.source.id
            var badges = [
                record.boundaryContract.authority.rawValue,
                record.boundaryContract.payloadPolicy.rawValue,
            ]
            if record.duplicateOf != nil {
                badges.append("duplicate")
            }
            if !record.enabledForAgent {
                badges.append("disabled")
            }

            return WorkspaceContextSourceWorkbenchRow(
                id: record.id,
                title: record.source.displayName,
                subtitle: subtitle,
                kindLabel: record.source.kind.displayName,
                statusLabel: statusLabel(for: record),
                badges: badges,
                warningText: record.warnings.first?.message,
                isEffective: record.isEffective
            )
        }
    }

    public static func summary(
        for inventory: WorkspaceContextSourceInventory
    ) -> WorkspaceContextSourceWorkbenchSummary {
        WorkspaceContextSourceWorkbenchSummary(
            totalSources: inventory.records.count,
            effectiveSources: inventory.effectiveSources.count,
            rejectedSources: inventory.rejectedSources.count,
            duplicateSources: inventory.records.filter { $0.duplicateOf != nil }.count,
            staleSources: inventory.records.filter { $0.state == .stale }.count,
            missingSources: inventory.records.filter { $0.state == .missing }.count,
            disabledSources: inventory.records.filter { $0.state == .disabled }.count
        )
    }

    private static func statusLabel(for record: WorkspaceContextSourceRecord) -> String {
        switch record.state {
        case .active:
            return "Current"
        case .disabled:
            return "Disabled"
        case .duplicate:
            return "Duplicate"
        case .stale:
            return record.staleness.status == .unindexed ? "Unindexed" : "Stale"
        case .missing:
            return "Missing"
        case .malformed:
            return "Malformed"
        }
    }
}
