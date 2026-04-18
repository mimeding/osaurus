//
//  ToolNotFoundSelfHealTests.swift
//  osaurusTests
//
//  Verifies that ToolRegistry.execute does NOT throw on unknown tools.
//  Instead it returns a structured ToolErrorEnvelope so the agent loop
//  stays alive and the model can recover by calling capabilities_load.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ToolNotFoundSelfHealTests {

    @Test
    func unknownTool_returnsToolNotFoundEnvelopeWithoutThrowing() async throws {
        // Pick a name that no built-in / plugin / sandbox tool will ever
        // claim — we just need the registry to miss in `toolsByName`.
        let unknownName = "definitely_not_a_real_tool_\(UUID().uuidString.prefix(8))"

        let result = try await ToolRegistry.shared.execute(
            name: unknownName,
            argumentsJSON: "{}"
        )

        // Result must look like our error envelope and carry the toolNotFound kind.
        #expect(ToolErrorEnvelope.isErrorResult(result))
        let data = result.data(using: .utf8)!
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["error"] as? String == "toolNotFound")
        #expect(parsed?["tool"] as? String == unknownName)

        // Reason must mention the tool name so the model knows what failed.
        let reason = parsed?["reason"] as? String ?? ""
        #expect(reason.contains(unknownName))
    }
}
