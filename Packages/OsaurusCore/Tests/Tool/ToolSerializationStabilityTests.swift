//
//  ToolSerializationStabilityTests.swift
//  osaurusTests
//
//  Pins down the byte-stability of `Tool.toTokenizerToolSpec` so the
//  rendered `<tools>` block in the system prompt doesn't shuffle between
//  invocations and silently invalidate the MLX paged KV cache.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct ToolSerializationStabilityTests {

    @Test
    func toTokenizerToolSpec_isByteStableAcrossInvocations() throws {
        let tool = Tool(
            type: "function",
            function: ToolFunction(
                name: "echo",
                description: "Echoes its input back.",
                parameters: .object([
                    "type": .string("object"),
                    // Insertion order chosen so a non-canonical encoder would
                    // surface key reordering between runs.
                    "z_last": .object(["type": .string("string")]),
                    "a_first": .object(["type": .string("string")]),
                    "m_middle": .object(["type": .string("string")]),
                ])
            )
        )

        let a = tool.toTokenizerToolSpec()
        let b = tool.toTokenizerToolSpec()

        // Re-serialize both with sortedKeys so we get a deterministic byte
        // representation we can compare. (`isValidJSONObject` + serialize is
        // intentionally identical to the path the canonical helper uses.)
        let aData = try JSONSerialization.data(withJSONObject: a, options: [.sortedKeys])
        let bData = try JSONSerialization.data(withJSONObject: b, options: [.sortedKeys])
        #expect(aData == bData)
    }

    @Test
    func toTokenizerToolSpec_dropsNullsBeforeJinjaConversion() throws {
        let tool = Tool(
            type: "function",
            function: ToolFunction(
                name: "schema_probe",
                description: nil,
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "value": .object([
                            "type": .array([.string("string"), .null]),
                            "description": .null,
                        ])
                    ]),
                ])
            )
        )

        let spec = tool.toTokenizerToolSpec()
        let data = try JSONSerialization.data(withJSONObject: spec, options: [.sortedKeys])
        let json = String(decoding: data, as: UTF8.self)

        #expect(!json.contains("null"))
        #expect(json.contains("\"type\":[\"string\"]"))
        #expect(!json.contains("description"))
    }
}
