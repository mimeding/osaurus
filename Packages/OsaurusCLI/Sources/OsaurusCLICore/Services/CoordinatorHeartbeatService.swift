import Foundation

public struct CoordinatorHeartbeatGateDecision: Codable, Equatable, Sendable {
    public let action: String
    public let status: String
    public let reason: String?
    public let mainSHA: String?
    public let evidenceDirectory: String?
}

public struct CoordinatorHeartbeatReport: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let root: String
    public let preflight: CoordinatorPreflightReport
    public let planDrift: CoordinatorPlanDriftReport
    public let reapedLocks: [CoordinatorLock]
    public let control: CoordinatorControlState
    public let gate: CoordinatorHeartbeatGateDecision
    public let tickReportPath: String

    public var ok: Bool {
        preflight.ok && planDrift.allowsGate && !control.paused && !control.stopped && gate.status != "failed"
    }
}

public struct CoordinatorHeartbeatService {
    public let paths: CoordinatorPaths
    private let preflightService: CoordinatorPreflightService
    private let planDriftService: CoordinatorPlanDriftService
    private let lockService: CoordinatorLockService
    private let controlService: CoordinatorControlService
    private let mainGateService: CoordinatorMainGateService
    private let tickReportService: CoordinatorTickReportService

    public init(
        paths: CoordinatorPaths,
        repositoryRoot: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        runner: any CoordinatorProcessRunning = CoordinatorProcessRunner(),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.preflightService = CoordinatorPreflightService(repositoryRoot: repositoryRoot, runner: runner)
        self.planDriftService = CoordinatorPlanDriftService(repositoryRoot: repositoryRoot, runner: runner)
        self.lockService = CoordinatorLockService(paths: paths, fileManager: fileManager)
        self.controlService = CoordinatorControlService(paths: paths, fileManager: fileManager)
        self.mainGateService = CoordinatorMainGateService(paths: paths, repositoryRoot: repositoryRoot, runner: runner, fileManager: fileManager)
        self.tickReportService = CoordinatorTickReportService(paths: paths, fileManager: fileManager)
    }

    init(
        paths: CoordinatorPaths,
        preflightService: CoordinatorPreflightService,
        planDriftService: CoordinatorPlanDriftService,
        lockService: CoordinatorLockService,
        controlService: CoordinatorControlService,
        mainGateService: CoordinatorMainGateService,
        tickReportService: CoordinatorTickReportService
    ) {
        self.paths = paths
        self.preflightService = preflightService
        self.planDriftService = planDriftService
        self.lockService = lockService
        self.controlService = controlService
        self.mainGateService = mainGateService
        self.tickReportService = tickReportService
    }

    public func tick(now: Date = Date()) throws -> CoordinatorHeartbeatReport {
        let preflight = preflightService.run(now: now)
        let planDrift = planDriftService.check(now: now)
        let reapedLocks = try lockService.reapExpired(now: now)
        let control = try controlService.state()

        let gate = try gateDecision(
            preflight: preflight,
            planDrift: planDrift,
            control: control,
            now: now
        )
        let reportURL = tickReportService.defaultArtifactURL(kind: "heartbeat", now: now)
        let report = CoordinatorHeartbeatReport(
            generatedAt: now,
            root: paths.root.path,
            preflight: preflight,
            planDrift: planDrift,
            reapedLocks: reapedLocks,
            control: control,
            gate: gate,
            tickReportPath: reportURL.path
        )
        try tickReportService.writeHeartbeatReport(report, output: reportURL)
        return report
    }

    private func gateDecision(
        preflight: CoordinatorPreflightReport,
        planDrift: CoordinatorPlanDriftReport,
        control: CoordinatorControlState,
        now: Date
    ) throws -> CoordinatorHeartbeatGateDecision {
        guard preflight.ok else {
            return CoordinatorHeartbeatGateDecision(
                action: "skipped",
                status: "skipped",
                reason: "preflight failed",
                mainSHA: preflight.originMainSHA,
                evidenceDirectory: nil
            )
        }
        guard planDrift.allowsGate else {
            return CoordinatorHeartbeatGateDecision(
                action: "skipped",
                status: "skipped",
                reason: "plan drift is not clean",
                mainSHA: preflight.originMainSHA,
                evidenceDirectory: nil
            )
        }
        if control.stopped {
            return CoordinatorHeartbeatGateDecision(
                action: "skipped",
                status: "skipped",
                reason: "coordinator is stopped",
                mainSHA: preflight.originMainSHA,
                evidenceDirectory: nil
            )
        }
        if control.paused {
            return CoordinatorHeartbeatGateDecision(
                action: "skipped",
                status: "skipped",
                reason: "coordinator is paused",
                mainSHA: preflight.originMainSHA,
                evidenceDirectory: nil
            )
        }

        let report = try mainGateService.run(now: now)
        return CoordinatorHeartbeatGateDecision(
            action: report.action.rawValue,
            status: report.status.rawValue,
            reason: report.message,
            mainSHA: report.mainSHA,
            evidenceDirectory: report.evidenceDirectory
        )
    }
}
