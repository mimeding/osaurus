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

    public init(
        kind: Kind,
        reason: String,
        toolName: String? = nil,
        retryable: Bool? = nil
    ) {
        self.kind = kind
        self.reason = reason
        self.toolName = toolName
        self.retryable = retryable ?? Self.defaultRetryable(for: kind)
    }

    /// Encode the envelope as a compact JSON string suitable for embedding in
    /// a `tool`-role message's `content` field. Falls back to a hand-built
    /// JSON string on encoding failure so we never return malformed output.
    ///
    /// We deliberately do NOT include any `suggested_tools` field — listing
    /// other tool names in an error response was the leading cause of
    /// hallucinated tool calls (the model treats the suggestion as proof
    /// the tool exists and starts inventing siblings).
    public func toJSONString() -> String {
        var dict: [String: Any] = [
            "error": kind.rawValue,
            "reason": reason,
            "retryable": retryable,
        ]
        if let toolName { dict["tool"] = toolName }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        {
            return json
        }
        // Defensive fallback. JSONSerialization should never fail on this
        // shape, but if it somehow does, ensure the model still gets a
        // recognizable error envelope.
        let escapedReason = Self.escape(reason)
        let toolField = toolName.map { ",\"tool\":\"\(Self.escape($0))\"" } ?? ""
        return
            "{\"error\":\"\(kind.rawValue)\",\"reason\":\"\(escapedReason)\",\"retryable\":\(retryable)\(toolField)}"
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
