//
//  AgentLoopSessionState.swift
//  osaurus
//
//  Minimal durable state for the chat-native agent loop.
//

import Foundation

public struct AgentLoopSessionState: Codable, Equatable, Sendable {
    public var todoMarkdown: String?
    public var completionSummary: String?
    public var clarifyQuestion: String?

    public init(
        todoMarkdown: String? = nil,
        completionSummary: String? = nil,
        clarifyQuestion: String? = nil
    ) {
        self.todoMarkdown = Self.normalizedString(todoMarkdown)
        self.completionSummary = Self.normalizedString(completionSummary)
        self.clarifyQuestion = Self.normalizedString(clarifyQuestion)
    }

    public var isEmpty: Bool {
        todoMarkdown == nil && completionSummary == nil && clarifyQuestion == nil
    }

    public var nilIfEmpty: AgentLoopSessionState? {
        isEmpty ? nil : self
    }

    /// Rebuild loop state from the chat transcript when older session files
    /// do not yet contain explicit metadata. User follow-ups clear terminal
    /// `complete` / `clarify` banners; todo survives until replaced.
    public static func derived(from turns: [ChatTurnData]) -> AgentLoopSessionState? {
        var state = AgentLoopSessionState()
        for turn in turns {
            if turn.role == .user {
                state.completionSummary = nil
                state.clarifyQuestion = nil
            }
            guard turn.role == .assistant, let toolCalls = turn.toolCalls else { continue }
            for call in toolCalls {
                state.applyToolCall(name: call.function.name, argumentsJSON: call.function.arguments)
            }
        }
        return state.nilIfEmpty
    }

    @discardableResult
    mutating func applyToolCall(name: String, argumentsJSON: String) -> Bool {
        switch name {
        case "todo":
            guard let markdown = Self.stringArgument("markdown", from: argumentsJSON) else { return false }
            todoMarkdown = markdown
            return true
        case "complete":
            guard let summary = Self.completeSummary(from: argumentsJSON) else { return false }
            completionSummary = summary
            clarifyQuestion = nil
            return true
        case "clarify":
            guard let question = Self.clarifyQuestion(from: argumentsJSON) else { return false }
            clarifyQuestion = question
            completionSummary = nil
            return true
        default:
            return false
        }
    }

    public static func todoMarkdown(from argumentsJSON: String) -> String? {
        stringArgument("markdown", from: argumentsJSON)
    }

    public static func completeSummary(from argumentsJSON: String) -> String? {
        guard let summary = stringArgument("summary", from: argumentsJSON),
            CompleteTool.validate(summary: summary) == nil
        else { return nil }
        return summary
    }

    public static func clarifyQuestion(from argumentsJSON: String) -> String? {
        stringArgument("question", from: argumentsJSON)
    }

    private static func stringArgument(_ name: String, from argumentsJSON: String) -> String? {
        guard let data = argumentsJSON.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let raw = dict[name] as? String
        else { return nil }
        return normalizedString(raw)
    }

    private static func normalizedString(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
