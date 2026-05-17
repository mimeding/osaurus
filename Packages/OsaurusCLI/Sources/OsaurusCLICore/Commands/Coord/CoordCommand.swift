import Foundation

public struct CoordCommand: Command {
    public static let name = "coord"

    public static func execute(args: [String]) async {
        do {
            try run(args: args)
        } catch {
            fputs("coord: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    static func run(args: [String]) throws {
        let parsed = try parseRoot(args)
        guard let subcommand = parsed.args.first else {
            printUsage()
            return
        }
        let rest = Array(parsed.args.dropFirst())
        switch subcommand {
        case "help", "-h", "--help":
            printUsage()
        case "init":
            try runInit(paths: parsed.paths)
        case "status":
            try runStatus(paths: parsed.paths, args: rest)
        case "feature-flags":
            try runFeatureFlags(paths: parsed.paths, args: rest)
        case "lock":
            try runLock(paths: parsed.paths, args: rest)
        case "preflight":
            try runPreflight(args: rest)
        case "gate-main":
            try runGateMain(paths: parsed.paths, args: rest)
        case "heartbeat":
            try runHeartbeat(paths: parsed.paths, args: rest)
        case "tick-report":
            try runTickReport(paths: parsed.paths, args: rest)
        case "pause":
            try runPause(paths: parsed.paths, args: rest)
        case "resume":
            try runResume(paths: parsed.paths)
        case "stop":
            try runStop(paths: parsed.paths, args: rest)
        case "clear-stop":
            try runClearStop(paths: parsed.paths)
        case "lane", "nudge", "promote", "agent-abort", "conflict-proof", "reviewer-summary":
            fputs("coord \(subcommand) is not available in this coordinator slice.\n\n", stderr)
            printUsage()
            exit(EXIT_FAILURE)
        default:
            fputs("Unknown coord subcommand: \(subcommand)\n\n", stderr)
            printUsage()
            exit(EXIT_FAILURE)
        }
    }

    static func parseRoot(_ args: [String]) throws -> (paths: CoordinatorPaths, args: [String]) {
        var remaining: [String] = []
        var cliRoot: String?
        var index = 0
        while index < args.count {
            if args[index] == "--root" {
                let valueIndex = index + 1
                guard valueIndex < args.count else { throw CoordCommandError.missingRootValue }
                cliRoot = args[valueIndex]
                index += 2
            } else {
                remaining.append(args[index])
                index += 1
            }
        }
        return (try CoordinatorPaths.resolve(cliRoot: cliRoot), remaining)
    }

    private static func runInit(paths: CoordinatorPaths) throws {
        let result = try CoordinatorBootstrap(paths: paths).initialize()
        print("Initialized coordinator root: \(result.root.path)")
        if !result.createdDirectories.isEmpty {
            print("Created directories: \(result.createdDirectories.count)")
        }
        if !result.seededFiles.isEmpty {
            print("Seeded files: \(result.seededFiles.count)")
        }
    }

    private static func runPreflight(args: [String]) throws {
        let report = CoordinatorPreflightService().run()
        if args.contains("--json") {
            try printJSON(report)
        } else {
            printPreflight(report)
        }
        if !report.ok { exit(EXIT_FAILURE) }
    }

    private static func runGateMain(paths: CoordinatorPaths, args: [String]) throws {
        let report = try CoordinatorMainGateService(paths: paths).run(forceRebuild: args.contains("--force"))
        if args.contains("--json") {
            try printJSON(report)
        } else {
            printMainGate(report)
        }
        if !report.ok { exit(EXIT_FAILURE) }
    }

    private static func runHeartbeat(paths: CoordinatorPaths, args: [String]) throws {
        let report = try CoordinatorHeartbeatService(paths: paths).tick()
        if args.contains("--json") {
            try printJSON(report)
        } else {
            printHeartbeat(report)
        }
        if !report.ok { exit(EXIT_FAILURE) }
    }

    private static func runTickReport(paths: CoordinatorPaths, args: [String]) throws {
        let output = try parseOutputURL(args)
        let snapshot = try CoordinatorStatusService(paths: paths).snapshot()
        let artifact = try CoordinatorTickReportService(paths: paths).writeStatusReport(snapshot, output: output)
        if args.contains("--json") {
            try printJSON(artifact)
        } else {
            print("Wrote coordinator tick report: \(artifact.path)")
        }
    }

    private static func runPause(paths: CoordinatorPaths, args: [String]) throws {
        let reason = parseReason(args, fallback: "manual pause")
        let marker = try CoordinatorControlService(paths: paths).pause(reason: reason)
        print("Paused coordinator: \(marker.reason)")
    }

    private static func runResume(paths: CoordinatorPaths) throws {
        try CoordinatorControlService(paths: paths).resume()
        print("Resumed coordinator")
    }

    private static func runStop(paths: CoordinatorPaths, args: [String]) throws {
        let reason = parseReason(args, fallback: "manual stop")
        let marker = try CoordinatorControlService(paths: paths).stop(reason: reason)
        print("Stopped coordinator: \(marker.reason)")
    }

    private static func runClearStop(paths: CoordinatorPaths) throws {
        try CoordinatorControlService(paths: paths).clearStop()
        print("Cleared coordinator stop")
    }

    private static func runStatus(paths: CoordinatorPaths, args: [String]) throws {
        let snapshot = try CoordinatorStatusService(paths: paths).snapshot()
        if args.contains("--json") {
            try printJSON(snapshot)
            return
        }
        print("Coordinator root: \(snapshot.root)")
        print("Initialized: \(snapshot.initialized ? "yes" : "no")")
        print("Active locks: \(snapshot.activeLocks.count)")
        print("Expired locks: \(snapshot.expiredLocks.count)")
        print("Paused: \(snapshot.paused ? "yes" : "no")")
        print("Stopped: \(snapshot.stopped ? "yes" : "no")")
    }

    private static func runFeatureFlags(paths: CoordinatorPaths, args: [String]) throws {
        let store = CoordinatorFeatureFlagsStore(paths: paths)
        let action = args.first ?? "list"
        switch action {
        case "list":
            let flags = try store.load().flags.sorted { $0.key < $1.key }
            for (name, enabled) in flags {
                print("\(name)=\(enabled)")
            }
        case "get":
            guard args.count == 2 else { throw CoordCommandError.invalidFeatureFlagsUsage }
            let flags = try store.load().flags
            print("\(args[1])=\(flags[args[1]] ?? false)")
        case "set":
            guard args.count == 3, let enabled = Bool(coordFlagValue: args[2]) else {
                throw CoordCommandError.invalidFeatureFlagsUsage
            }
            _ = try store.set(args[1], enabled: enabled)
            print("\(args[1])=\(enabled)")
        default:
            throw CoordCommandError.invalidFeatureFlagsUsage
        }
    }

    private static func runLock(paths: CoordinatorPaths, args: [String]) throws {
        guard let action = args.first else { throw CoordCommandError.invalidLockUsage }
        let service = CoordinatorLockService(paths: paths)
        let rest = Array(args.dropFirst())
        switch action {
        case "list":
            for lock in try service.list() {
                print("\(lock.resource) owner=\(lock.owner)")
            }
        case "acquire":
            guard let resource = rest.first else { throw CoordCommandError.invalidLockUsage }
            let options = parseLockOptions(Array(rest.dropFirst()))
            guard let owner = options.owner else { throw CoordCommandError.invalidLockUsage }
            switch try service.acquire(resource: resource, owner: owner, ttl: options.ttl) {
            case .acquired:
                print("acquired \(resource)")
            case .held(let current):
                print("held \(resource) owner=\(current.owner)")
                exit(EXIT_FAILURE)
            }
        case "release":
            guard let resource = rest.first else { throw CoordCommandError.invalidLockUsage }
            let options = parseLockOptions(Array(rest.dropFirst()))
            guard let owner = options.owner else { throw CoordCommandError.invalidLockUsage }
            switch try service.release(resource: resource, owner: owner, force: options.force) {
            case .released:
                print("released \(resource)")
            case .notFound:
                print("not-found \(resource)")
                exit(EXIT_FAILURE)
            case .ownerMismatch(let current):
                print("owner-mismatch \(resource) owner=\(current.owner)")
                exit(EXIT_FAILURE)
            }
        case "reap":
            let reaped = try service.reapExpired()
            print("reaped \(reaped.count)")
        default:
            throw CoordCommandError.invalidLockUsage
        }
    }

    private static func parseLockOptions(_ args: [String]) -> (owner: String?, ttl: TimeInterval?, force: Bool) {
        var owner: String?
        var ttl: TimeInterval?
        var force = false
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--owner":
                if index + 1 < args.count {
                    owner = args[index + 1]
                    index += 2
                } else {
                    index += 1
                }
            case "--ttl":
                if index + 1 < args.count {
                    ttl = TimeInterval(args[index + 1])
                    index += 2
                } else {
                    index += 1
                }
            case "--force":
                force = true
                index += 1
            default:
                index += 1
            }
        }
        return (owner, ttl, force)
    }

    private static func parseOutputURL(_ args: [String]) throws -> URL? {
        var index = 0
        while index < args.count {
            if args[index] == "--output" {
                guard index + 1 < args.count else { throw CoordCommandError.invalidTickReportUsage }
                return URL(fileURLWithPath: args[index + 1])
            }
            index += 1
        }
        return nil
    }

    private static func parseReason(_ args: [String], fallback: String) -> String {
        guard !args.isEmpty else { return fallback }
        if args.first == "--reason" {
            let reason = args.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return reason.isEmpty ? fallback : reason
        }
        let reason = args.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? fallback : reason
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        print(String(data: try CoordinatorJSON.encoder().encode(value), encoding: .utf8) ?? "{}")
    }

    private static func printPreflight(_ report: CoordinatorPreflightReport) {
        print("preflight \(report.ok ? "ok" : "failed")")
        for check in report.checks {
            print("[\(check.status.rawValue)] \(check.name): \(check.message)")
        }
        if let originMainSHA = report.originMainSHA {
            print("origin/main: \(originMainSHA)")
        }
        if let remaining = report.rateLimitRemaining, let limit = report.rateLimitLimit {
            print("gh rate limit: \(remaining)/\(limit)")
        }
    }

    private static func printMainGate(_ report: CoordinatorMainGateReport) {
        print("gate-main \(report.ok ? "ok" : "failed")")
        print("main: \(report.mainSHA)")
        print("action: \(report.action.rawValue)")
        print("evidence: \(report.evidenceDirectory)")
        print(report.message)
    }

    private static func printHeartbeat(_ report: CoordinatorHeartbeatReport) {
        print("heartbeat \(report.ok ? "ok" : "blocked")")
        print("preflight: \(report.preflight.ok ? "pass" : "fail")")
        print("plan drift: \(report.planDrift.status.rawValue)")
        print("reaped locks: \(report.reapedLocks.count)")
        print("gate-main: \(report.gate.action) \(report.gate.status)")
        print("tick report: \(report.tickReportPath)")
    }

    private static func printUsage() {
        let usage = """
            osaurus coord <subcommand> [--root PATH]

            Foundation subcommands:
              init                         Create coordinator directories and seed state
              status [--json]              Show coordinator root, initialization, locks, and flags
              feature-flags list|get|set   Read or update JSON-backed feature flags
              lock list|acquire|release|reap
                                           Manage file-scoped coordinator locks

            Gate subcommands:
              preflight [--json]           Check gh auth, rate limit, origin/main, and SHA drift
              gate-main [--json] [--force] Validate or run exact-main local release build
              heartbeat [--json]           Run one idempotent coordinator orchestration tick
              tick-report [--json]         Write a deterministic Markdown status artifact
              pause|resume|stop|clear-stop Manage local heartbeat controls

            Later PR hygiene subcommands are registered but unsupported in this slice.

            """
        print(usage)
    }
}

enum CoordCommandError: LocalizedError, Equatable {
    case missingRootValue
    case invalidFeatureFlagsUsage
    case invalidLockUsage
    case invalidTickReportUsage

    var errorDescription: String? {
        switch self {
        case .missingRootValue:
            return "--root requires a path."
        case .invalidFeatureFlagsUsage:
            return "Usage: osaurus coord feature-flags [list|get <name>|set <name> <true|false>]"
        case .invalidLockUsage:
            return
                "Usage: osaurus coord lock [list|acquire <resource> --owner <owner> [--ttl seconds]|release <resource> --owner <owner> [--force]|reap]"
        case .invalidTickReportUsage:
            return "Usage: osaurus coord tick-report [--json] [--output path]"
        }
    }
}

private extension Bool {
    init?(coordFlagValue value: String) {
        switch value.lowercased() {
        case "1", "true", "yes", "on", "enabled":
            self = true
        case "0", "false", "no", "off", "disabled":
            self = false
        default:
            return nil
        }
    }
}
