//
//  ToolErrorEnvelopeTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct ToolErrorEnvelopeTests {

    @Test func envelopeRoundTripsThroughJSON() throws {
        let envelope = ToolErrorEnvelope(
            kind: .timeout,
            reason: "Tool did not complete within 30 seconds.",
            toolName: "my_tool"
        )
        let json = envelope.toJSONString()
        let data = json.data(using: .utf8)!
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(parsed?["error"] as? String == "timeout")
        #expect(parsed?["tool"] as? String == "my_tool")
        #expect(parsed?["retryable"] as? Bool == true)
    }

    @Test func defaultRetryableMatchesKind() {
        let rejected = ToolErrorEnvelope(kind: .rejected, reason: "denied")
        #expect(rejected.retryable == false)

        let exec = ToolErrorEnvelope(kind: .executionError, reason: "boom")
        #expect(exec.retryable == true)

        let notFound = ToolErrorEnvelope(kind: .toolNotFound, reason: "no such tool")
        #expect(notFound.retryable == false)
    }

    @Test func explicitRetryableOverridesDefault() {
        let env = ToolErrorEnvelope(kind: .rejected, reason: "permission ask", retryable: true)
        #expect(env.retryable == true)
    }

    @Test func isErrorResultDetectsLegacyPrefixes() {
        #expect(ToolErrorEnvelope.isErrorResult("[REJECTED] permission denied") == true)
        #expect(ToolErrorEnvelope.isErrorResult("[TIMEOUT] timed out") == true)
        #expect(ToolErrorEnvelope.isErrorResult("ok") == false)
    }

    @Test func isErrorResultDetectsJSONEnvelope() {
        let env = ToolErrorEnvelope(kind: .executionError, reason: "boom").toJSONString()
        #expect(ToolErrorEnvelope.isErrorResult(env) == true)
    }

    @Test func isErrorResultDoesNotMisidentifyOrdinaryJSON() {
        #expect(ToolErrorEnvelope.isErrorResult("{\"value\": 42}") == false)
    }
}
