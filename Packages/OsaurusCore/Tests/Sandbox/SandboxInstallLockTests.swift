//
//  SandboxInstallLockTests.swift
//  osaurusTests
//
//  Pins the per-agent serialization semantics of `SandboxInstallLock`.
//  Two install operations on the same agent must run sequentially —
//  that's what prevents npm/pip/apk from racing on the same
//  `node_modules/` / venv / apk db. Two operations on DIFFERENT agents
//  must still run concurrently.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct SandboxInstallLockTests {

    /// Two `serialize(agentName:)` calls on the same key run one after
    /// the other: the second body must not start while the first body is
    /// still inside the lock.
    @Test
    func sameAgent_runsSequentially() async throws {
        let lock = SandboxInstallLock()
        let gate = SameAgentGate()
        let agentName = "agent-A"

        let first = Task {
            try await lock.serialize(agentName: agentName) {
                await gate.markFirstStarted()
                await gate.waitForRelease()
            }
        }

        await gate.waitUntilFirstStarted()

        let second = Task {
            try await lock.serialize(agentName: agentName) {
                await gate.markSecondStarted()
            }
        }

        try await Task.sleep(nanoseconds: 20_000_000) // Give a broken lock time to admit the second body.
        #expect(await !gate.hasSecondStarted, "second op started while first still held the lock")

        await gate.releaseFirst()
        _ = try await (first.value, second.value)
        #expect(await gate.hasSecondStarted, "second op never ran after first released the lock")
    }

    /// Two `serialize(agentName:)` calls on DIFFERENT keys must run
    /// concurrently. Wall-clock comparisons are flaky under CI load,
    /// so we instead observe overlap directly: each body increments a
    /// shared counter on entry and decrements on exit; if both bodies
    /// are inside the lock at the same moment the counter hits 2.
    /// A serialized lock would never let it climb above 1.
    @Test
    func differentAgents_runConcurrently() async throws {
        let lock = SandboxInstallLock()
        let observer = OverlapObserver()

        // Each body yields 50× so the cooperative scheduler interleaves
        // the two tasks reliably on every Apple Silicon Mac we've run
        // this on. The assumption is that `Task.yield()` always gives
        // the runtime a chance to pick another ready task — which is
        // the documented contract today. If a future Swift runtime
        // optimises `yield()` into a no-op when only one task is
        // ready (it currently doesn't), this test would need to swap
        // to an explicit two-way handshake (continuation each side
        // resumes after entering). Calling out the assumption here so
        // a future failure has the right context.
        async let a: Void = lock.serialize(agentName: "agent-A") {
            await observer.enter()
            for _ in 0 ..< 50 { await Task.yield() }
            await observer.exit()
        }
        async let b: Void = lock.serialize(agentName: "agent-B") {
            await observer.enter()
            for _ in 0 ..< 50 { await Task.yield() }
            await observer.exit()
        }
        _ = try await (a, b)

        let peak = await observer.peakConcurrent
        #expect(
            peak >= 2,
            "two different-agent ops never overlapped (peak=\(peak)) — serialization leaked across keys"
        )
    }

    /// Errors thrown by the body propagate to the caller, AND the lock
    /// queue advances so the next `serialize(agentName:)` call still
    /// runs. Without this, one failed install would wedge every
    /// subsequent install for the same agent.
    @Test
    func errorReleasesLock() async throws {
        struct Boom: Error {}
        let lock = SandboxInstallLock()

        // First op throws.
        do {
            try await lock.serialize(agentName: "agent-A") {
                throw Boom()
            }
            Issue.record("expected Boom to propagate")
        } catch is Boom {
            // ok
        }

        // Second op must still run.
        let didRun = ActorFlag()
        try await lock.serialize(agentName: "agent-A") {
            await didRun.set()
        }
        #expect(await didRun.value, "lock queue is wedged after a thrown body")
    }
}

// MARK: - Test helpers

/// Coordinates the same-agent serialization test without relying on
/// `async let` scheduling order or wall-clock timestamp comparisons.
private actor SameAgentGate {
    private var firstStarted = false
    private var secondStarted = false
    private var released = false
    private var firstStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    var hasSecondStarted: Bool { secondStarted }

    func markFirstStarted() {
        firstStarted = true
        let waiters = firstStartedWaiters
        firstStartedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilFirstStarted() async {
        if firstStarted { return }
        await withCheckedContinuation { continuation in
            firstStartedWaiters.append(continuation)
        }
    }

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func releaseFirst() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func markSecondStarted() {
        secondStarted = true
    }
}

/// One-shot Sendable bool flag. Lets a `@Sendable` closure mark
/// completion without tripping the captured-var concurrency checker.
private actor ActorFlag {
    private(set) var value: Bool = false
    func set() { value = true }
}

/// Tracks how many tasks are simultaneously inside an instrumented
/// section, recording the peak. The
/// `differentAgents_runConcurrently` test asserts the peak ≥ 2 to
/// prove the lock didn't serialize across keys.
private actor OverlapObserver {
    private(set) var peakConcurrent: Int = 0
    private var current: Int = 0

    func enter() {
        current += 1
        if current > peakConcurrent { peakConcurrent = current }
    }
    func exit() { current -= 1 }
}
