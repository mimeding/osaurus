//
//  MCPProviderEndpointValidationTests.swift
//  osaurusTests
//
//  Pins the supported transport for remote MCP providers so command-based
//  stdio provider strings fail with a clear message instead of looking like
//  malformed HTTP endpoints.
//

import Foundation
import Testing

@testable import OsaurusCore

struct MCPProviderEndpointValidationTests {
    @Test func httpEndpointIsAccepted() throws {
        let url = try MCPProviderManager.validatedHTTPSEndpoint(from: "http://127.0.0.1:3000/mcp")
        #expect(url.absoluteString == "http://127.0.0.1:3000/mcp")
    }

    @Test func httpsSSEEndpointIsAccepted() throws {
        let url = try MCPProviderManager.validatedHTTPSEndpoint(from: " https://mcp.example.com/sse ")
        #expect(url.absoluteString == "https://mcp.example.com/sse")
    }

    @Test func stdioCommandIsRejectedWithTransportMessage() throws {
        expectUnsupportedTransport(from: "python -m some_mcp.server")
    }

    @Test func nonHTTPURLIsRejectedWithTransportMessage() throws {
        expectUnsupportedTransport(from: "stdio://some_mcp.server")
    }

    private func expectUnsupportedTransport(from endpoint: String) {
        do {
            _ = try MCPProviderManager.validatedHTTPSEndpoint(from: endpoint)
            Issue.record("Expected unsupported transport for \(endpoint)")
        } catch MCPProviderError.unsupportedTransport {
            // Expected.
        } catch {
            Issue.record("Expected unsupported transport, got \(error)")
        }
    }
}
