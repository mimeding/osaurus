//
//  ToolErrorEnvelope.swift
//  osaurus
//
//  Standardized JSON error envelope returned to the model as the body of a
//  failed `tool` message. Local models often misinterpret unstructured prefix
//  strings like `[REJECTED]` as policy refusals and give up; a structured
//  envelope makes the failure mode unambiguous so the model can react
//  appropriately (retry, pivot, ask the user).
//

import Foundation

/// Serializable error returned to the model in a tool-result message.
public struct ToolErrorEnvelope: Sendable {
    public enum Kind: String, Sendable {
        case rejected
        case timeout
        case invalidArguments
        case executionError
        case toolNotFound
        case unavailable
    }

    public let kind: Kind
    public let reason: String
    public let toolName: String?
    public let retryable: Bool
    /// Optional list of `capabilities_load`-shaped IDs (e.g. `tool/sandbox_exec`,
    /// `skill/swift-best-practices`) the model can pass to `capabilities_load`
    /// to recover from a `toolNotFound` error. Surfaced both as the structured
    /// `suggested_tools` JSON field and appended to `reason` as plain text so
    /// models that ignore the structured field still get an actionable hint.
    public let suggestions: [String]

    public init(
        kind: Kind,
        reason: String,
        toolName: String? = nil,
        retryable: Bool? = nil,
        suggestions: [String] = []
    ) {
        self.kind = kind
        self.reason = reason
        self.toolName = toolName
        // Default `toolNotFound` to retryable iff we have something concrete
        // for the model to do — i.e. at least one capabilities_load suggestion.
        // Without suggestions there's no clear next step, so retryable=false
        // (matches the old behaviour).
        let retryDefault: Bool
        if let retryable {
            retryDefault = retryable
        } else if kind == .toolNotFound {
            retryDefault = !suggestions.isEmpty
        } else {
            retryDefault = Self.defaultRetryable(for: kind)
        }
        self.retryable = retryDefault
        self.suggestions = suggestions
    }

    /// Encode the envelope as a compact JSON string suitable for embedding in
    /// a `tool`-role message's `content` field. Falls back to a hand-built
    /// JSON string on encoding failure so we never return malformed output.
    public func toJSONString() -> String {
        var dict: [String: Any] = [
            "error": kind.rawValue,
            "reason": fullReason,
            "retryable": retryable,
        ]
        if let toolName { dict["tool"] = toolName }
        if !suggestions.isEmpty { dict["suggested_tools"] = suggestions }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        {
            return json
        }
        // Defensive fallback. JSONSerialization should never fail on this
        // shape, but if it somehow does, ensure the model still gets a
        // recognizable error envelope.
        let escapedReason = Self.escape(fullReason)
        let toolField = toolName.map { ",\"tool\":\"\(Self.escape($0))\"" } ?? ""
        let suggField =
            suggestions.isEmpty
            ? ""
            : ",\"suggested_tools\":[\(suggestions.map { "\"\(Self.escape($0))\"" }.joined(separator: ","))]"
        return
            "{\"error\":\"\(kind.rawValue)\",\"reason\":\"\(escapedReason)\",\"retryable\":\(retryable)\(toolField)\(suggField)}"
    }

    /// `reason` with a trailing `capabilities_load` hint when suggestions
    /// exist. Plain-text channel for models that don't pick up the
    /// structured `suggested_tools` field.
    private var fullReason: String {
        guard !suggestions.isEmpty else { return reason }
        let ids = suggestions.joined(separator: ", ")
        return "\(reason) Try: capabilities_load with \(ids)."
    }

    private static func defaultRetryable(for kind: Kind) -> Bool {
        switch kind {
        case .rejected, .toolNotFound: return false
        case .timeout, .invalidArguments, .executionError, .unavailable: return true
        }
    }

    /// Detect either the legacy `[REJECTED] ...` / `[TIMEOUT] ...` string
    /// prefix OR the new JSON envelope shape. Used by UI / accounting code
    /// that needs to distinguish failed tool results from successful ones
    /// without parsing the full envelope.
    public static func isErrorResult(_ result: String) -> Bool {
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[REJECTED]") || trimmed.hasPrefix("[TIMEOUT]") {
            return true
        }
        // Cheap structural sniff: does this look like the JSON envelope?
        // (Avoids a full JSON parse on every UI redraw.)
        guard trimmed.first == "{" else { return false }
        return trimmed.contains("\"error\":") && trimmed.contains("\"retryable\":")
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 2)
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out
    }
}
