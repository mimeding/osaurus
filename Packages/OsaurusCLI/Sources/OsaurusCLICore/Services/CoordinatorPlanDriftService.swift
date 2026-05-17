import Foundation

public enum CoordinatorPlanDriftStatus: String, Codable, Equatable, Sendable {
    case clean
    case drifted
    case failed
}

public struct CoordinatorPlanDriftReport: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let repositoryRoot: String
    public let planPath: String
    public let baselineSHA: String?
    public let status: CoordinatorPlanDriftStatus
    public let message: String
    public let changedPaths: [String]

    public var allowsGate: Bool { status == .clean }
}

public struct CoordinatorPlanDriftService {
    public let repositoryRoot: URL
    public let planRelativePath: String
    private let runner: any CoordinatorProcessRunning

    public init(
        repositoryRoot: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        planRelativePath: String = "docs/OPEN_PR_BUG_DEVELOPMENT_PLAN.md",
        runner: any CoordinatorProcessRunning = CoordinatorProcessRunner()
    ) {
        self.repositoryRoot = repositoryRoot.standardizedFileURL
        self.planRelativePath = planRelativePath
        self.runner = runner
    }

    public func check(now: Date = Date()) -> CoordinatorPlanDriftReport {
        let baseline = revParseOriginMain()
        guard let baselineSHA = baseline.sha else {
            return CoordinatorPlanDriftReport(
                generatedAt: now,
                repositoryRoot: repositoryRoot.path,
                planPath: planRelativePath,
                baselineSHA: nil,
                status: .failed,
                message: "origin/main is unavailable for plan drift check",
                changedPaths: []
            )
        }

        let invocation = CoordinatorProcessInvocation(
            command: ["git", "diff", "--name-only", "origin/main", "--", planRelativePath],
            workingDirectory: repositoryRoot
        )
        do {
            let result = try runner.run(invocation)
            guard result.succeeded else {
                return CoordinatorPlanDriftReport(
                    generatedAt: now,
                    repositoryRoot: repositoryRoot.path,
                    planPath: planRelativePath,
                    baselineSHA: baselineSHA,
                    status: .failed,
                    message: "plan drift check failed",
                    changedPaths: []
                )
            }
            let changed = result.stdout
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .sorted()
            if changed.isEmpty {
                return CoordinatorPlanDriftReport(
                    generatedAt: now,
                    repositoryRoot: repositoryRoot.path,
                    planPath: planRelativePath,
                    baselineSHA: baselineSHA,
                    status: .clean,
                    message: "plan matches origin/main",
                    changedPaths: []
                )
            }
            return CoordinatorPlanDriftReport(
                generatedAt: now,
                repositoryRoot: repositoryRoot.path,
                planPath: planRelativePath,
                baselineSHA: baselineSHA,
                status: .drifted,
                message: "plan differs from origin/main",
                changedPaths: changed
            )
        } catch {
            return CoordinatorPlanDriftReport(
                generatedAt: now,
                repositoryRoot: repositoryRoot.path,
                planPath: planRelativePath,
                baselineSHA: baselineSHA,
                status: .failed,
                message: "plan drift check could not run",
                changedPaths: []
            )
        }
    }

    private func revParseOriginMain() -> (sha: String?, details: [String: String]) {
        let invocation = CoordinatorProcessInvocation(
            command: ["git", "rev-parse", "--verify", "origin/main^{commit}"],
            workingDirectory: repositoryRoot
        )
        do {
            let result = try runner.run(invocation)
            guard result.succeeded else { return (nil, ["exitCode": "\(result.exitCode)"]) }
            let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return sha.isEmpty ? (nil, ["exitCode": "\(result.exitCode)"]) : (sha, ["sha": sha])
        } catch {
            return (nil, ["error": error.localizedDescription])
        }
    }
}
