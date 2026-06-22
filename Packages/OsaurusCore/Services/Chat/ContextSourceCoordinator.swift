//
//  ContextSourceCoordinator.swift
//  osaurus
//
//  Shared contract for Osaurus-managed context sources. This keeps durable
//  workspace knowledge, memory, agent DB state, sandbox/local workspace state,
//  and screen context in distinct prompt lanes.
//

import Foundation

public enum ContextSourceKind: String, CaseIterable, Codable, Sendable {
    case memory
    case agentDatabase
    case agentWorkspace
    case hostWorkspace
    case sandboxLocal
    case screen
}

public enum ContextSourceOwner: String, Codable, Sendable {
    case user
    case agent
    case runtime
}

public enum ContextInjectionSlot: String, Codable, Sendable {
    case systemPromptStatic
    case systemPromptDynamic
    case latestUserMessagePrefix
}

public enum ContextPrivacyPath: String, Codable, Sendable {
    case localSystemPrompt
    case localUserMessage
    case privacyFilteredUserMessage
}

public struct ContextSourceDescriptor: Codable, Sendable, Equatable {
    public let kind: ContextSourceKind
    public let owner: ContextSourceOwner
    public let provenance: String
    public let injectionSlot: ContextInjectionSlot
    public let dedupeKey: String
    public let privacyPath: ContextPrivacyPath
    public let precedence: Int

    public init(
        kind: ContextSourceKind,
        owner: ContextSourceOwner,
        provenance: String,
        injectionSlot: ContextInjectionSlot,
        dedupeKey: String,
        privacyPath: ContextPrivacyPath,
        precedence: Int
    ) {
        self.kind = kind
        self.owner = owner
        self.provenance = provenance
        self.injectionSlot = injectionSlot
        self.dedupeKey = dedupeKey
        self.privacyPath = privacyPath
        self.precedence = precedence
    }
}

public struct ContextSourcePromptSection: Sendable, Equatable {
    public let id: String
    public let label: String
    public let descriptor: ContextSourceDescriptor
    public let content: String

    public init(
        id: String,
        label: String,
        descriptor: ContextSourceDescriptor,
        content: String
    ) {
        self.id = id
        self.label = label
        self.descriptor = descriptor
        self.content = content
    }
}

public enum ContextSourceCoordinator {
    public static func descriptor(
        kind: ContextSourceKind,
        owner: ContextSourceOwner,
        provenance: String,
        injectionSlot: ContextInjectionSlot,
        dedupeKey: String,
        privacyPath: ContextPrivacyPath,
        precedence: Int
    ) -> ContextSourceDescriptor {
        ContextSourceDescriptor(
            kind: kind,
            owner: owner,
            provenance: provenance,
            injectionSlot: injectionSlot,
            dedupeKey: dedupeKey,
            privacyPath: privacyPath,
            precedence: precedence
        )
    }

    public static func memory(agentId: UUID) -> ContextSourceDescriptor {
        descriptor(
            kind: .memory,
            owner: .agent,
            provenance: "Conversation-derived memory selected by the relevance gate.",
            injectionSlot: .latestUserMessagePrefix,
            dedupeKey: "agent:\(agentId.uuidString):memory",
            privacyPath: .localUserMessage,
            precedence: 10
        )
    }

    public static func screen() -> ContextSourceDescriptor {
        descriptor(
            kind: .screen,
            owner: .user,
            provenance: "Frozen on-screen text snapshot captured for the current turn.",
            injectionSlot: .latestUserMessagePrefix,
            dedupeKey: "screen:current-turn",
            privacyPath: .privacyFilteredUserMessage,
            precedence: 20
        )
    }

    public static func agentDatabase(agentId: UUID) -> ContextSourceDescriptor {
        descriptor(
            kind: .agentDatabase,
            owner: .agent,
            provenance: "Live per-agent SQLite schema and tables owned by the agent DB.",
            injectionSlot: .systemPromptDynamic,
            dedupeKey: "agent:\(agentId.uuidString):agent-db",
            privacyPath: .localSystemPrompt,
            precedence: 110
        )
    }

    public static func agentWorkspace(agentId: UUID) -> ContextSourceDescriptor {
        descriptor(
            kind: .agentWorkspace,
            owner: .agent,
            provenance: "Durable workspace metadata and bounded source summaries attached to this agent.",
            injectionSlot: .systemPromptDynamic,
            dedupeKey: "agent:\(agentId.uuidString):agent-workspaces",
            privacyPath: .localSystemPrompt,
            precedence: 100
        )
    }

    public static func hostWorkspace(rootPath: String) -> ContextSourceDescriptor {
        descriptor(
            kind: .hostWorkspace,
            owner: .user,
            provenance: "Live selected working-folder tree, manifests, project context, and git status.",
            injectionSlot: .systemPromptStatic,
            dedupeKey: "host-workspace:\(rootPath)",
            privacyPath: .localSystemPrompt,
            precedence: 60
        )
    }

    public static func sandboxLocal(agentId: UUID) -> ContextSourceDescriptor {
        descriptor(
            kind: .sandboxLocal,
            owner: .runtime,
            provenance: "Live sandbox runtime state such as installed packages and configured secret names.",
            injectionSlot: .systemPromptDynamic,
            dedupeKey: "agent:\(agentId.uuidString):sandbox-state",
            privacyPath: .localSystemPrompt,
            precedence: 120
        )
    }

    public static func coordinatedPromptSections(
        _ sections: [ContextSourcePromptSection],
        slot: ContextInjectionSlot
    ) -> [ContextSourcePromptSection] {
        let filtered = sections.filter { section in
            section.descriptor.injectionSlot == slot
                && !section.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var seen = Set<String>()
        let unique = filtered.enumerated().compactMap { index, section
            -> (index: Int, section: ContextSourcePromptSection)? in
            guard seen.insert(section.descriptor.dedupeKey).inserted else { return nil }
            return (index, section)
        }
        return unique
            .sorted {
                if $0.section.descriptor.precedence == $1.section.descriptor.precedence {
                    return $0.index < $1.index
                }
                return $0.section.descriptor.precedence < $1.section.descriptor.precedence
            }
            .map(\.section)
    }

    public static func boundaryLedger(agentId: UUID) -> [ContextSourceDescriptor] {
        [
            memory(agentId: agentId),
            screen(),
            hostWorkspace(rootPath: "<selected working folder>"),
            agentWorkspace(agentId: agentId),
            agentDatabase(agentId: agentId),
            sandboxLocal(agentId: agentId),
        ]
    }
}
