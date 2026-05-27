//
//  PairingReplayGuardTests.swift
//  osaurusTests
//
//  Behavioural tests for the /pair endpoint's rate-limit + nonce-replay
//  shared state. The HTTP handler consults this guard before doing any
//  signature work, and again after signature verification, so its
//  correctness directly affects whether replay and flood attempts are
//  rejected.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct PairingReplayGuardTests {

    @Test func allowsFirstAttemptFromIP() {
        PairingReplayGuard.shared._reset()
        #expect(PairingReplayGuard.shared.allowAttempt(ip: "203.0.113.1"))
    }

    @Test func enforcesRateLimitWindow() {
        PairingReplayGuard.shared._reset()
        let ip = "203.0.113.2"
        var allowed = 0
        // Try one more than the configured maximum so we observe the
        // transition from "ok" to "rate-limited".
        for _ in 0..<(PairingReplayGuard.rateLimitMax + 1) {
            if PairingReplayGuard.shared.allowAttempt(ip: ip) {
                allowed += 1
            }
        }
        #expect(allowed == PairingReplayGuard.rateLimitMax)
    }

    @Test func rateLimitIsPerIP() {
        PairingReplayGuard.shared._reset()
        let ipA = "203.0.113.3"
        let ipB = "203.0.113.4"
        for _ in 0..<PairingReplayGuard.rateLimitMax {
            _ = PairingReplayGuard.shared.allowAttempt(ip: ipA)
        }
        // ipA is now saturated; ipB must still be allowed.
        #expect(PairingReplayGuard.shared.allowAttempt(ip: ipA) == false)
        #expect(PairingReplayGuard.shared.allowAttempt(ip: ipB) == true)
    }

    @Test func consumeNonceAcceptsFirstUseAndRejectsReplay() {
        PairingReplayGuard.shared._reset()
        let connector = "0xabc"
        let nonce = "challenge-\(UUID().uuidString)"
        #expect(PairingReplayGuard.shared.consumeNonce(connector: connector, nonce: nonce))
        #expect(PairingReplayGuard.shared.consumeNonce(connector: connector, nonce: nonce) == false)
    }

    @Test func consumeNonceIsKeyedOnConnectorAddress() {
        PairingReplayGuard.shared._reset()
        let connectorA = "0xaaa"
        let connectorB = "0xbbb"
        let nonce = "shared-nonce"
        #expect(PairingReplayGuard.shared.consumeNonce(connector: connectorA, nonce: nonce))
        // The same nonce string under a different connector address is a
        // distinct pair — should not be treated as a replay.
        #expect(PairingReplayGuard.shared.consumeNonce(connector: connectorB, nonce: nonce))
    }

    @Test func resetClearsBothStates() {
        PairingReplayGuard.shared._reset()
        let ip = "203.0.113.5"
        for _ in 0..<PairingReplayGuard.rateLimitMax {
            _ = PairingReplayGuard.shared.allowAttempt(ip: ip)
        }
        _ = PairingReplayGuard.shared.consumeNonce(connector: "x", nonce: "y")

        PairingReplayGuard.shared._reset()

        #expect(PairingReplayGuard.shared.allowAttempt(ip: ip) == true)
        #expect(PairingReplayGuard.shared.consumeNonce(connector: "x", nonce: "y") == true)
    }
}
