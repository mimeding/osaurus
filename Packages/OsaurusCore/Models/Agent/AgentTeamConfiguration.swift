//
//  AgentTeamConfiguration.swift
//  osaurus
//
//  Named agent groups plus group-targeted creation defaults.
//

import Foundation

public struct AgentTeamConfiguration: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var memberAgentIds: [UUID]
    public var defaults: AgentCreationDefaults
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        name: String,
        description: String = "",
        memberAgentIds: [UUID] = [],
        defaults: AgentCreationDefaults = .default,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.memberAgentIds = memberAgentIds
        self.defaults = defaults
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

private struct AgentTeamConfigurationEnvelope: Codable, Equatable, Sendable {
    var teams: [AgentTeamConfiguration]

    static var empty: AgentTeamConfigurationEnvelope {
        AgentTeamConfigurationEnvelope(teams: [])
    }
}

@MainActor
public enum AgentTeamConfigurationStore {
    public static var overrideDirectory: URL?

    private static var cached: [AgentTeamConfiguration]?

    public static func load() -> [AgentTeamConfiguration] {
        if let cached { return cached }
        let loaded = loadFromDisk()
        cached = loaded
        return loaded
    }

    public static func save(_ teams: [AgentTeamConfiguration]) {
        let normalized = normalize(teams)
        cached = normalized
        saveToDisk(normalized)
        NotificationCenter.default.post(name: .appConfigurationChanged, object: nil)
    }

    public static func team(id: String) -> AgentTeamConfiguration? {
        load().first { $0.id == id }
    }

    public static func upsert(_ team: AgentTeamConfiguration) {
        var teams = load()
        if let index = teams.firstIndex(where: { $0.id == team.id }) {
            var updated = team
            updated.createdAt = teams[index].createdAt
            updated.updatedAt = Date()
            teams[index] = updated
        } else {
            teams.append(team)
        }
        save(teams)
    }

    public static func assign(agentId: UUID, toTeamId teamId: String) {
        var teams = load()
        guard let index = teams.firstIndex(where: { $0.id == teamId }) else { return }
        guard !teams[index].memberAgentIds.contains(agentId) else { return }
        teams[index].memberAgentIds.append(agentId)
        teams[index].updatedAt = Date()
        save(teams)
    }

    public static func teamIds(containing agentId: UUID) -> [String] {
        load()
            .filter { $0.memberAgentIds.contains(agentId) }
            .map(\.id)
            .sorted()
    }

    public static func setTeamIds(_ teamIds: [String], for agentId: UUID) {
        let requested = Set(teamIds)
        var teams = load()
        var changed = false
        for index in teams.indices {
            let shouldContain = requested.contains(teams[index].id)
            let contains = teams[index].memberAgentIds.contains(agentId)
            if shouldContain && !contains {
                teams[index].memberAgentIds.append(agentId)
                teams[index].updatedAt = Date()
                changed = true
            } else if !shouldContain && contains {
                teams[index].memberAgentIds.removeAll { $0 == agentId }
                teams[index].updatedAt = Date()
                changed = true
            }
        }
        if changed {
            save(teams)
        }
    }

    public static func resetCacheForTests() {
        cached = nil
    }

    nonisolated public static func isValidTeamId(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 64 else { return false }
        return id.allSatisfy { character in
            character.isASCII
                && (character.isLetter || character.isNumber || character == "-" || character == "_")
        }
    }

    private static func normalize(_ teams: [AgentTeamConfiguration]) -> [AgentTeamConfiguration] {
        var seen = Set<String>()
        return teams
            .filter { seen.insert($0.id).inserted }
            .map { team in
                var normalized = team
                normalized.memberAgentIds = Array(Set(team.memberAgentIds)).sorted {
                    $0.uuidString < $1.uuidString
                }
                return normalized
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func configFileURL() -> URL {
        if let dir = overrideDirectory {
            return dir.appendingPathComponent("agent-teams.json")
        }
        return OsaurusPaths.config().appendingPathComponent("agent-teams.json")
    }

    private static func loadFromDisk() -> [AgentTeamConfiguration] {
        let url = configFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let data = try? Data(contentsOf: url) else { return [] }

        if let envelope = try? JSONDecoder().decode(AgentTeamConfigurationEnvelope.self, from: data) {
            return normalize(envelope.teams)
        }
        if let legacyArray = try? JSONDecoder().decode([AgentTeamConfiguration].self, from: data) {
            return normalize(legacyArray)
        }

        print("[Osaurus] Failed to decode agent-teams.json - using empty teams (file preserved)")
        ToastManager.shared.warning(
            L("Agent teams unreadable"),
            message: L("Using no saved agent teams; your saved file was left untouched.")
        )
        return []
    }

    private static func saveToDisk(_ teams: [AgentTeamConfiguration]) {
        let url = configFileURL()
        do {
            let dir = url.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(AgentTeamConfigurationEnvelope(teams: teams))
                .write(to: url, options: .atomic)
        } catch {
            print("[Osaurus] Failed to save agent-teams.json: \(error)")
            ToastManager.shared.error(
                L("Couldn't save agent teams"),
                message: error.localizedDescription
            )
        }
    }
}
