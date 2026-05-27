//
//  PairingReplayGuard.swift
//  osaurus
//
//  Shared state for /pair endpoint hardening:
//    * Per-(connectorAddress, nonce) replay store with a sliding 5-minute TTL.
//      A captured signed pairing request can no longer be replayed within the
//      window; outside it, the signature is irrelevant because the user must
//      re-approve the pop-up anyway, but rotating the nonce on every attempt
//      makes signature replay strictly impossible during the live window.
//
//    * Per-source-IP sliding-window rate limit. The /pair endpoint sits behind
//      no Bearer auth (it has to, by design, so an unpaired peer can initiate
//      pairing). That means a LAN peer can spam pairing attempts and either
//      annoy the user with prompts, or chew through event-loop cycles on
//      secp256k1 signature recovery. A small bucket of attempts per minute
//      per remote IP is sufficient — a real pairing flow uses 1 attempt.
//
//  All state is bounded: nonces expire after 5 minutes, and IP timestamp lists
//  are pruned on every access. Memory growth is proportional to the rate of
//  attempts, not to lifetime traffic.
//

import Foundation

/// Thread-safe singleton consulted by `HTTPHandler.handlePairEndpoint`.
public final class PairingReplayGuard: @unchecked Sendable {
    public static let shared = PairingReplayGuard()

    private let lock = NSLock()
    private var seenNonces: [String: Date] = [:]
    private var ipTimestamps: [String: [Date]] = [:]

    /// How long a (connectorAddress, nonce) pair is remembered. Real pairing
    /// flows finish in seconds; 5 minutes is comfortably above the slowest
    /// realistic user-approval round trip while keeping the replay window
    /// well below the time a real attacker would need to coordinate.
    public static let nonceTTL: TimeInterval = 300

    /// Maximum number of /pair attempts allowed from a single source IP
    /// within `rateLimitWindow`. A successful pairing uses exactly one
    /// attempt; a rejected approval typically uses one more after the user
    /// dismisses the prompt. Ten gives plenty of slack for retries while
    /// stopping flood/probe traffic cold.
    public static let rateLimitMax: Int = 10

    /// Sliding window for `rateLimitMax`.
    public static let rateLimitWindow: TimeInterval = 60

    // MARK: - Rate limit

    /// Record one /pair attempt from `ip`. Returns `true` if the attempt is
    /// allowed; `false` if the IP has exceeded `rateLimitMax` within the
    /// sliding `rateLimitWindow`. Called before signature verification so
    /// flooders can't spend our CPU.
    public func allowAttempt(ip: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        pruneExpired_locked(now: now)

        let recent = ipTimestamps[ip, default: []]
        if recent.count >= Self.rateLimitMax {
            return false
        }
        ipTimestamps[ip, default: []].append(now)
        return true
    }

    // MARK: - Nonce replay

    /// Reserve `(connector, nonce)` for the next `nonceTTL` seconds. Returns
    /// `true` if the pair has not been seen yet (i.e. consumption succeeded);
    /// `false` if it was already consumed within the window — that's a replay.
    public func consumeNonce(connector: String, nonce: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        pruneExpired_locked(now: now)

        let key = "\(connector)|\(nonce)"
        if seenNonces[key] != nil {
            return false
        }
        seenNonces[key] = now.addingTimeInterval(Self.nonceTTL)
        return true
    }

    // MARK: - Internals

    /// Drop expired nonces and trim old timestamps. Caller must hold `lock`.
    private func pruneExpired_locked(now: Date) {
        // Nonces: each entry stores its own expiration timestamp.
        seenNonces = seenNonces.filter { _, expires in expires > now }

        // Rate-limit window: drop timestamps older than the window. Entire
        // IP entries are removed when they become empty so the map doesn't
        // grow unbounded with one-shot attempts.
        let cutoff = now.addingTimeInterval(-Self.rateLimitWindow)
        for (ip, stamps) in ipTimestamps {
            let kept = stamps.filter { $0 > cutoff }
            if kept.isEmpty {
                ipTimestamps.removeValue(forKey: ip)
            } else {
                ipTimestamps[ip] = kept
            }
        }
    }

    // MARK: - Test helpers (internal)

    /// Reset all guard state. Used by tests so independent test cases don't
    /// inherit each other's nonces / rate counters.
    internal func _reset() {
        lock.lock()
        defer { lock.unlock() }
        seenNonces.removeAll()
        ipTimestamps.removeAll()
    }
}
