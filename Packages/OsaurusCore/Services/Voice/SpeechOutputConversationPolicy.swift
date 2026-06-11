//
//  SpeechOutputConversationPolicy.swift
//  osaurus
//
//  Testable turn-selection policy for opt-in spoken conversations.
//

import Foundation

public enum SpeechOutputConversationRole: String, Codable, Equatable, Sendable {
    case system
    case user
    case assistant
    case tool
}

public struct SpeechOutputConversationTurn: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var role: SpeechOutputConversationRole
    public var text: String
    public var isComplete: Bool

    public init(
        id: UUID,
        role: SpeechOutputConversationRole,
        text: String,
        isComplete: Bool = true
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.isComplete = isComplete
    }
}

public enum SpeechOutputConversationSkipReason: Codable, Equatable, Sendable {
    case disabled
    case modelNotReady
    case alreadyPlaying(UUID)
    case noEligibleTurn
    case nonAssistantTurn
    case incompleteTurn
    case blankTurn
}

public enum SpeechOutputConversationDecision: Equatable, Sendable {
    case speak(SpeechOutputConversationTurn)
    case stop(UUID)
    case skip(SpeechOutputConversationSkipReason)
}

public enum SpeechOutputConversationPolicy {
    public static func explicitTurnDecision(
        _ turn: SpeechOutputConversationTurn,
        currentPlayingTurnId: UUID?
    ) -> SpeechOutputConversationDecision {
        if currentPlayingTurnId == turn.id {
            return .stop(turn.id)
        }
        if let currentPlayingTurnId {
            return .skip(.alreadyPlaying(currentPlayingTurnId))
        }
        return eligibilityDecision(for: turn)
    }

    public static func nextAssistantTurn(
        in turns: [SpeechOutputConversationTurn],
        after lastSpokenTurnId: UUID?,
        currentPlayingTurnId: UUID?
    ) -> SpeechOutputConversationDecision {
        if let currentPlayingTurnId {
            return .skip(.alreadyPlaying(currentPlayingTurnId))
        }

        let lastSpokenIndex = lastSpokenTurnId.flatMap { id in
            turns.firstIndex { $0.id == id }
        }

        let startIndex: Int
        if let lastSpokenIndex {
            startIndex = turns.index(after: lastSpokenIndex)
        } else {
            startIndex = turns.startIndex
        }

        guard startIndex < turns.endIndex else {
            return .skip(.noEligibleTurn)
        }

        for turn in turns[startIndex...] {
            if case .speak = eligibilityDecision(for: turn) {
                return .speak(turn)
            }
        }
        return .skip(.noEligibleTurn)
    }

    private static func eligibilityDecision(
        for turn: SpeechOutputConversationTurn
    ) -> SpeechOutputConversationDecision {
        guard turn.role == .assistant else {
            return .skip(.nonAssistantTurn)
        }
        guard turn.isComplete else {
            return .skip(.incompleteTurn)
        }
        let plain = MarkdownStripper.plainText(from: turn.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else {
            return .skip(.blankTurn)
        }
        return .speak(turn)
    }
}
