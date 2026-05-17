import Foundation

public enum CoordinatorMainGateStatus: String, Codable, Equatable, Sendable {
    case passed
    case failed
}

public enum CoordinatorMainGateAction: String, Codable, Equatable, Sendable {
    case validatedExisting = "validated-existing"
    case built
}

public struct CoordinatorMainGateCommandEvidence: Codable, Equatable, Sendable {
    public let command: [String]
    public let workingDirectory: String?
    public let exitCode: Int32?
}

public struct CoordinatorMainGateReport: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let mainSHA: String
    public let status: CoordinatorMainGateStatus
    public let action: CoordinatorMainGateAction
    public let message: String
    public let evidenceDirectory: String
    public let worktree: String
    public let command: CoordinatorMainGateCommandEvidence?
    public let stdoutPath: String?
    public let stderrPath: String?

    public var ok: Bool { status == .passed }
}

public struct CoordinatorMainGateService {
    public let paths: CoordinatorPaths
    public let repositoryRoot: URL
    public let buildCommand: [String]
    private let runner: any CoordinatorProcessRunning
    private let fileManager: FileManager

    public init(
        paths: CoordinatorPaths,
        repositoryRoot: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        buildCommand: [String] = ["swift", "build", "--package-path", "Packages/OsaurusCore", "-c", "release"],
        runner: any CoordinatorProcessRunning = CoordinatorProcessRunner(),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.repositoryRoot = repositoryRoot.standardizedFileURL
        self.buildCommand = buildCommand
        self.runner = runner
        self.fileManager = fileManager
    }

    public func run(now: Date = Date(), forceRebuild: Bool = false) throws -> CoordinatorMainGateReport {
        let mainSHAResult = try resolveOriginMainSHA()
        let mainSHA = mainSHAResult.trimmingCharacters(in: .whitespacesAndNewlines)
        let evidenceDirectory = gateEvidenceDirectory(for: mainSHA)
        let reportURL = evidenceDirectory.appendingPathComponent("report.json")
        let worktree = worktreeDirectory(for: mainSHA)

        if !forceRebuild, let existing = try loadPassingReport(at: reportURL, mainSHA: mainSHA) {
            return CoordinatorMainGateReport(
                generatedAt: now,
                mainSHA: mainSHA,
                status: .passed,
                action: .validatedExisting,
                message: "reused passing exact-main release evidence",
                evidenceDirectory: evidenceDirectory.path,
                worktree: existing.worktree,
                command: existing.command,
                stdoutPath: existing.stdoutPath,
                stderrPath: existing.stderrPath
            )
        }

        try fileManager.createDirectory(
            at: evidenceDirectory,
            withIntermediateDirectories: true,
            attributes: CoordinatorFilePermissions.directoryAttributes
        )
        try CoordinatorFilePermissions.applyDirectoryPermissions(to: paths.evidenceDirectory, fileManager: fileManager)
        try CoordinatorFilePermissions.applyDirectoryPermissions(to: evidenceDirectory, fileManager: fileManager)
        try fileManager.createDirectory(
            at: paths.worktreesDirectory,
            withIntermediateDirectories: true,
            attributes: CoordinatorFilePermissions.directoryAttributes
        )
        try CoordinatorFilePermissions.applyDirectoryPermissions(to: paths.worktreesDirectory, fileManager: fileManager)

        if fileManager.fileExists(atPath: worktree.path) {
            let headInvocation = CoordinatorProcessInvocation(
                command: ["git", "rev-parse", "--verify", "HEAD"],
                workingDirectory: worktree
            )
            let head: CoordinatorProcessResult
            do {
                head = try runner.run(headInvocation)
            } catch {
                let report = failedReport(
                    now: now,
                    mainSHA: mainSHA,
                    message: "existing main worktree could not be verified",
                    evidenceDirectory: evidenceDirectory,
                    worktree: worktree,
                    invocation: headInvocation,
                    exitCode: nil
                )
                try write(report: report, to: reportURL)
                return report
            }
            let headSHA = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard head.succeeded, headSHA == mainSHA else {
                let report = failedReport(
                    now: now,
                    mainSHA: mainSHA,
                    message: "existing main worktree does not match exact main SHA",
                    evidenceDirectory: evidenceDirectory,
                    worktree: worktree,
                    invocation: head.invocation,
                    exitCode: head.exitCode
                )
                try write(report: report, to: reportURL)
                return report
            }
        } else {
            let addInvocation = CoordinatorProcessInvocation(
                command: ["git", "worktree", "add", "--detach", worktree.path, mainSHA],
                workingDirectory: repositoryRoot
            )
            let addWorktree: CoordinatorProcessResult
            do {
                addWorktree = try runner.run(addInvocation)
            } catch {
                let report = failedReport(
                    now: now,
                    mainSHA: mainSHA,
                    message: "failed to launch exact-main worktree creation",
                    evidenceDirectory: evidenceDirectory,
                    worktree: worktree,
                    invocation: addInvocation,
                    exitCode: nil
                )
                try write(report: report, to: reportURL)
                return report
            }
            guard addWorktree.succeeded else {
                let report = failedReport(
                    now: now,
                    mainSHA: mainSHA,
                    message: "failed to create exact-main worktree",
                    evidenceDirectory: evidenceDirectory,
                    worktree: worktree,
                    invocation: addWorktree.invocation,
                    exitCode: addWorktree.exitCode
                )
                try write(report: report, to: reportURL)
                return report
            }
        }

        let buildInvocation = CoordinatorProcessInvocation(command: buildCommand, workingDirectory: worktree)
        let build: CoordinatorProcessResult
        do {
            build = try runner.run(buildInvocation)
        } catch {
            let report = failedReport(
                now: now,
                mainSHA: mainSHA,
                message: "failed to launch exact-main release build",
                evidenceDirectory: evidenceDirectory,
                worktree: worktree,
                invocation: buildInvocation,
                exitCode: nil
            )
            try write(report: report, to: reportURL)
            return report
        }
        let stdoutURL = evidenceDirectory.appendingPathComponent("stdout.txt")
        let stderrURL = evidenceDirectory.appendingPathComponent("stderr.txt")
        try build.stdout.write(to: stdoutURL, atomically: true, encoding: .utf8)
        try build.stderr.write(to: stderrURL, atomically: true, encoding: .utf8)
        try CoordinatorFilePermissions.applyFilePermissions(to: stdoutURL, fileManager: fileManager)
        try CoordinatorFilePermissions.applyFilePermissions(to: stderrURL, fileManager: fileManager)

        let report = CoordinatorMainGateReport(
            generatedAt: now,
            mainSHA: mainSHA,
            status: build.succeeded ? .passed : .failed,
            action: .built,
            message: build.succeeded ? "exact-main release build passed" : "exact-main release build failed",
            evidenceDirectory: evidenceDirectory.path,
            worktree: worktree.path,
            command: CoordinatorMainGateCommandEvidence(
                command: build.invocation.command,
                workingDirectory: build.invocation.workingDirectory,
                exitCode: build.exitCode
            ),
            stdoutPath: stdoutURL.path,
            stderrPath: stderrURL.path
        )
        try write(report: report, to: reportURL)
        return report
    }

    private func resolveOriginMainSHA() throws -> String {
        let result = try runner.run(
            CoordinatorProcessInvocation(command: ["git", "rev-parse", "--verify", "origin/main^{commit}"], workingDirectory: repositoryRoot)
        )
        guard result.succeeded else {
            throw CoordinatorMainGateError.originMainUnavailable(exitCode: result.exitCode)
        }
        let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sha.isEmpty else { throw CoordinatorMainGateError.originMainUnavailable(exitCode: result.exitCode) }
        return sha
    }

    private func gateEvidenceDirectory(for sha: String) -> URL {
        paths.evidenceDirectory
            .appendingPathComponent("gate-main", isDirectory: true)
            .appendingPathComponent(sha, isDirectory: true)
    }

    private func worktreeDirectory(for sha: String) -> URL {
        let prefix = String(sha.prefix(12))
        return paths.worktreesDirectory.appendingPathComponent("main-\(prefix)", isDirectory: true)
    }

    private func failedReport(
        now: Date,
        mainSHA: String,
        message: String,
        evidenceDirectory: URL,
        worktree: URL,
        invocation: CoordinatorProcessInvocation,
        exitCode: Int32?
    ) -> CoordinatorMainGateReport {
        CoordinatorMainGateReport(
            generatedAt: now,
            mainSHA: mainSHA,
            status: .failed,
            action: .built,
            message: message,
            evidenceDirectory: evidenceDirectory.path,
            worktree: worktree.path,
            command: CoordinatorMainGateCommandEvidence(
                command: invocation.command,
                workingDirectory: invocation.workingDirectory,
                exitCode: exitCode
            ),
            stdoutPath: nil,
            stderrPath: nil
        )
    }

    private func loadPassingReport(at url: URL, mainSHA: String) throws -> CoordinatorMainGateReport? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let report = try CoordinatorJSON.decoder().decode(CoordinatorMainGateReport.self, from: data)
        guard report.mainSHA == mainSHA, report.status == .passed else { return nil }
        return report
    }

    private func write(report: CoordinatorMainGateReport, to url: URL) throws {
        let data = try CoordinatorJSON.encoder().encode(report)
        try data.write(to: url, options: .atomic)
        try CoordinatorFilePermissions.applyFilePermissions(to: url, fileManager: fileManager)
    }
}

public enum CoordinatorMainGateError: LocalizedError, Equatable {
    case originMainUnavailable(exitCode: Int32)

    public var errorDescription: String? {
        switch self {
        case .originMainUnavailable(let exitCode):
            return "origin/main could not be resolved for the main gate (exit \(exitCode))."
        }
    }
}
