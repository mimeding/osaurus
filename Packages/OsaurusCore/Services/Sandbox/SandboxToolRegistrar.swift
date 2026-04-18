//
//  SandboxToolRegistrar.swift
//  osaurus
//
//  Bridges the sandbox infrastructure with the ToolRegistry by
//  registering/unregistering sandbox tools in response to plugin
//  installs, and container lifecycle events.
//
//  Plugin tools are registered globally (agent-agnostic). Agent
//  identity is resolved at execution time via WorkExecutionContext.
//  Builtin sandbox tools remain per-agent.
//

import Combine
import Foundation

@MainActor
public final class SandboxToolRegistrar {
    public static let shared = SandboxToolRegistrar()

    private var observers: [NSObjectProtocol] = []
    private var statusCancellable: AnyCancellable?
    var provisionAgentOverride: ((UUID) async throws -> Void)?

    /// Per-agent record of why sandbox tools are not currently available.
    /// Used by `SystemPromptComposer` to inject a "sandbox unavailable" notice
    /// into the system prompt so the model doesn't hallucinate sandbox calls.
    public struct UnavailabilityReason: Sendable, Equatable {
        public enum Kind: String, Sendable, Equatable {
            case containerUnavailable
            case provisioningFailed
            case startupFailed
        }
        public let kind: Kind
        public let message: String
    }

    private var unavailability: [UUID: UnavailabilityReason] = [:]

    /// Coalesces concurrent `startContainer()` attempts so multiple Work
    /// sessions / Chat sends don't pile up duplicate provision tasks (which
    /// caused vmnet "address already in use" thrashing).
    private var startupTask: Task<Void, Error>?

    /// Earliest wall-clock time at which a fresh `startContainer()` retry is
    /// allowed after a failed attempt. We back off so a misconfigured host
    /// (vmnet collision, port conflict, missing entitlement) doesn't generate
    /// log spam on every chat send.
    private var nextStartupRetryAfter: Date?

    /// Number of `startContainer()` attempts since process launch that have
    /// failed. After `maxStartupFailures` we stop trying entirely until the
    /// user takes explicit action (toggling autonomous off/on, restarting
    /// the app, or hitting "Start" in the Sandbox settings panel).
    private var startupFailureCount: Int = 0

    /// Cool-down between failed `startContainer()` attempts.
    private static let startupRetryCooldown: TimeInterval = 120

    /// Hard cap on automatic startup attempts per app launch.
    private static let maxStartupFailures: Int = 3

    /// Returns the current unavailability reason for an agent, if any.
    public func unavailabilityReason(for agentId: UUID) -> UnavailabilityReason? {
        unavailability[agentId]
    }

    private init() {}

    // MARK: - Lifecycle

    /// Call once at app startup (after sandbox auto-start attempt).
    /// Sets up all notification observers and performs initial registration.
    public func start() {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .activeAgentChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in Task { @MainActor in await self?.handleAgentChanged() } }
        )

        observers.append(
            NotificationCenter.default.addObserver(
                forName: .sandboxPluginInstalled,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let pluginId = note.userInfo?["pluginId"] as? String
                Task { @MainActor in await self?.handlePluginInstalled(pluginId: pluginId) }
            }
        )

        observers.append(
            NotificationCenter.default.addObserver(
                forName: .sandboxPluginUninstalled,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let pluginId = note.userInfo?["pluginId"] as? String
                Task { @MainActor in await self?.handlePluginUninstalled(pluginId: pluginId) }
            }
        )

        statusCancellable = SandboxManager.State.shared.$status
            .removeDuplicates()
            .sink { [weak self] newStatus in
                Task { @MainActor in await self?.handleContainerStatusChanged(newStatus) }
            }

        observers.append(
            NotificationCenter.default.addObserver(
                forName: .agentUpdated,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let agentId = note.object as? UUID
                Task { @MainActor in await self?.handleAgentUpdated(agentId: agentId) }
            }
        )

        Task { @MainActor in
            registerAllPluginTools()
            await registerTools(for: AgentManager.shared.activeAgent.id)
        }
    }

    // MARK: - Plugin Tools (Global)

    /// Register all sandbox plugin tools globally (agent-agnostic).
    /// Plugin tools are available to any agent and resolved at execution time.
    public func registerAllPluginTools() {
        let allPlugins = SandboxPluginManager.shared.allUniquePlugins()
        for plugin in allPlugins {
            ToolRegistry.shared.registerSandboxPluginTools(plugin: plugin)
        }
    }

    // MARK: - Builtin Tools (Per-Agent)

    /// Re-register builtin sandbox tools for a specific agent.
    /// This is the per-agent concern: provisioning + builtin tool registration.
    ///
    /// When the agent has autonomous execution enabled but the container is
    /// not running, this method will attempt to start the container before
    /// provisioning. Failures are recorded in `unavailability[agentId]` so the
    /// system prompt can surface a clear message to the model instead of the
    /// model silently losing access to its sandbox tools.
    public func registerTools(for agentId: UUID) async {
        ToolRegistry.shared.unregisterAllBuiltinSandboxTools()

        let agent = AgentManager.shared.agent(for: agentId) ?? Agent.default
        let agentIdStr = agent.id.uuidString
        let agentName = SandboxAgentProvisioner.linuxName(for: agentIdStr)
        let execConfig = AgentManager.shared.effectiveAutonomousExec(for: agent.id)
        let autonomousEnabled = execConfig?.enabled == true
        let needsProvisioning =
            autonomousEnabled
            || SandboxPluginManager.shared.plugins(for: agentIdStr).contains { $0.status == .ready }

        let containerStatus = SandboxManager.State.shared.status
        if containerStatus != .running {
            // Without autonomous execution there's no expectation of sandbox
            // tools — clear any prior unavailability and bail.
            guard autonomousEnabled else {
                unavailability.removeValue(forKey: agent.id)
                return
            }

            // After `maxStartupFailures` give up entirely until the user
            // takes explicit action (toggling autonomous off/on, restarting
            // the app, or hitting "Start" in the Sandbox settings panel).
            // The recorded unavailability tells the model what happened.
            if startupFailureCount >= Self.maxStartupFailures {
                if unavailability[agent.id] == nil {
                    recordUnavailability(
                        for: agent.id,
                        kind: containerStatus == .notProvisioned ? .containerUnavailable : .startupFailed,
                        message:
                            "Sandbox start has failed \(startupFailureCount) times this session — automatic retries disabled. Open the Sandbox settings panel to start it manually or check ~/.osaurus/container/containers/osaurus-sandbox for stale state."
                    )
                }
                return
            }

            // Honor the failure cool-down so a misconfigured host (vmnet
            // collision, port-in-use, missing entitlement) doesn't get
            // hammered with a fresh provision attempt on every chat/work
            // send. The previous failure reason is still in `unavailability`
            // so the model gets the same notice without us re-trying.
            if let retryAfter = nextStartupRetryAfter, retryAfter > Date() {
                if unavailability[agent.id] == nil {
                    recordUnavailability(
                        for: agent.id,
                        kind: containerStatus == .notProvisioned ? .containerUnavailable : .startupFailed,
                        message: "Sandbox container start is in cool-down after a recent failure"
                    )
                }
                return
            }

            do {
                try await ensureContainerStartedCoalesced()
            } catch {
                startupFailureCount += 1
                nextStartupRetryAfter = Date().addingTimeInterval(Self.startupRetryCooldown)
                // Clear any leftover container/bridge state so the next
                // attempt starts from a clean slate. The SDK's own cleanup
                // sometimes leaves the on-disk container directory behind
                // (the source of "file ... already exists" errors).
                await SandboxManager.shared.cleanupAfterFailure()
                recordUnavailability(
                    for: agent.id,
                    kind: containerStatus == .notProvisioned ? .containerUnavailable : .startupFailed,
                    message: "Sandbox container could not be started: \(error.localizedDescription)"
                )
                return
            }

            guard SandboxManager.State.shared.status == .running else {
                startupFailureCount += 1
                nextStartupRetryAfter = Date().addingTimeInterval(Self.startupRetryCooldown)
                await SandboxManager.shared.cleanupAfterFailure()
                recordUnavailability(
                    for: agent.id,
                    kind: .startupFailed,
                    message: "Sandbox container did not reach running state"
                )
                return
            }

            // Successful start resets failure tracking.
            nextStartupRetryAfter = nil
            startupFailureCount = 0
        }

        if needsProvisioning {
            do {
                try await ensureProvisioned(agentId: agent.id)
            } catch {
                recordUnavailability(
                    for: agent.id,
                    kind: .provisioningFailed,
                    message: "Failed to provision agent sandbox: \(error.localizedDescription)"
                )
                return
            }
        }

        unavailability.removeValue(forKey: agent.id)
        BuiltinSandboxTools.register(
            agentId: agentIdStr,
            agentName: agentName,
            config: execConfig
        )
    }

    private func recordUnavailability(
        for agentId: UUID,
        kind: UnavailabilityReason.Kind,
        message: String
    ) {
        // Only log when this is a NEW failure (kind+message changed). Without
        // this, every chat send / work iteration produces another identical
        // line in the system log.
        let prev = unavailability[agentId]
        let next = UnavailabilityReason(kind: kind, message: message)
        unavailability[agentId] = next
        if prev != next {
            NSLog("[SandboxToolRegistrar] \(message)")
        }
    }

    /// Coalesce concurrent `startContainer()` attempts so multiple sessions
    /// firing `registerTools` in parallel share one provision task instead
    /// of racing each other into "address already in use" / vmnet failures.
    private func ensureContainerStartedCoalesced() async throws {
        if let inFlight = startupTask {
            try await inFlight.value
            return
        }
        let task = Task<Void, Error> {
            try await SandboxManager.shared.startContainer()
        }
        startupTask = task
        defer { startupTask = nil }
        try await task.value
    }

    private func ensureProvisioned(agentId: UUID) async throws {
        if let provisionAgentOverride {
            try await provisionAgentOverride(agentId)
            return
        }
        try await SandboxAgentProvisioner.shared.ensureProvisioned(agentId: agentId)
    }

    // MARK: - Event Handlers

    private func handleAgentChanged() async {
        await registerTools(for: AgentManager.shared.activeAgent.id)
    }

    private func handleAgentUpdated(agentId: UUID?) async {
        guard agentId == nil || agentId == AgentManager.shared.activeAgent.id else { return }
        await registerTools(for: AgentManager.shared.activeAgent.id)
    }

    private func handlePluginInstalled(pluginId: String?) async {
        guard let pluginId else { return }
        guard let plugin = SandboxPluginLibrary.shared.plugin(id: pluginId) else { return }
        ToolRegistry.shared.registerSandboxPluginTools(plugin: plugin)
    }

    private func handlePluginUninstalled(pluginId: String?) async {
        guard let pluginId else { return }
        ToolRegistry.shared.unregisterSandboxPluginTools(pluginId: pluginId)
    }

    private func handleContainerStatusChanged(_ newStatus: ContainerStatus) async {
        if newStatus == .running {
            // Someone (UI, autoStart, agent provisioner) successfully
            // started the container — clear any prior failure tracking so
            // future hiccups can retry from scratch.
            startupFailureCount = 0
            nextStartupRetryAfter = nil
            await SandboxPluginManager.shared.verifyAndRepairAllPlugins()
        }
        registerAllPluginTools()
        await registerTools(for: AgentManager.shared.activeAgent.id)
    }

    /// Reset the failure tracking so the next `registerTools` call is
    /// allowed to attempt startup again. Called when the user takes an
    /// explicit action that should bypass the cool-down: toggling
    /// autonomous execution off/on, or hitting "Start" in the Sandbox
    /// settings panel.
    public func resetStartupFailures() {
        startupFailureCount = 0
        nextStartupRetryAfter = nil
    }
}
