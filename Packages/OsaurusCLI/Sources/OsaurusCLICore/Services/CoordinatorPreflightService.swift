import Foundation

public enum CoordinatorCheckStatus: String, Codable, Equatable, Sendable {
    case pass
    case fail
}

public struct CoordinatorCheckResult: Codable, Equatable, Sendable {
    public let name: String
    public let status: CoordinatorCheckStatus
    public let message: String
    public let details: [String: String]

    public var passed: Bool { status == .pass }
}

public struct CoordinatorPreflightReport: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let repositoryRoot: String
    public let checks: [CoordinatorCheckResult]
    public let mainSHA: String?
    public let originMainSHA: String?
    public let rateLimitRemaining: Int?
    public let rateLimitLimit: Int?

    public var ok: Bool { checks.allSatisfy(\.passed) }
}

public struct CoordinatorPreflightService {
    public let repositoryRoot: URL
    private let runner: any CoordinatorProcessRunning

    public init(
        repositoryRoot: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        runner: any CoordinatorProcessRunning = CoordinatorProcessRunner()
    ) {
        self.repositoryRoot = repositoryRoot.standardizedFileURL
        self.runner = runner
    }

    public func run(now: Date = Date()) -> CoordinatorPreflightReport {
        let auth = ghAuthCheck()
        let rateLimit = ghRateLimitCheck()
        let originMain = revParseCheck(ref: "origin/main^{commit}", name: "origin-main")
        let localMain = revParse(ref: "main^{commit}")
        let drift = shaDriftCheck(localMain: localMain, originMain: originMain.sha)

        return CoordinatorPreflightReport(
            generatedAt: now,
            repositoryRoot: repositoryRoot.path,
            checks: [auth, rateLimit.check, originMain.check, drift],
            mainSHA: localMain.sha,
            originMainSHA: originMain.sha,
            rateLimitRemaining: rateLimit.remaining,
            rateLimitLimit: rateLimit.limit
        )
    }

    private func ghAuthCheck() -> CoordinatorCheckResult {
        let invocation = CoordinatorProcessInvocation(command: ["gh", "auth", "status"], workingDirectory: repositoryRoot)
        do {
            let result = try runner.run(invocation)
            if result.succeeded {
                return CoordinatorCheckResult(
                    name: "gh-auth",
                    status: .pass,
                    message: "gh authentication is available",
                    details: ["exitCode": "\(result.exitCode)"]
                )
            }
            return CoordinatorCheckResult(
                name: "gh-auth",
                status: .fail,
                message: "gh auth status failed",
                details: ["exitCode": "\(result.exitCode)"]
            )
        } catch {
            return CoordinatorCheckResult(
                name: "gh-auth",
                status: .fail,
                message: "gh auth status could not run",
                details: ["error": error.localizedDescription]
            )
        }
    }

    private func ghRateLimitCheck() -> (
        check: CoordinatorCheckResult,
        remaining: Int?,
        limit: Int?
    ) {
        let invocation = CoordinatorProcessInvocation(command: ["gh", "api", "rate_limit"], workingDirectory: repositoryRoot)
        do {
            let result = try runner.run(invocation)
            guard result.succeeded else {
                return (
                    CoordinatorCheckResult(
                        name: "gh-rate-limit",
                        status: .fail,
                        message: "gh rate limit check failed",
                        details: ["exitCode": "\(result.exitCode)"]
                    ),
                    nil,
                    nil
                )
            }
            guard let parsed = parseCoreRateLimit(result.stdout) else {
                return (
                    CoordinatorCheckResult(
                        name: "gh-rate-limit",
                        status: .fail,
                        message: "gh rate limit response could not be parsed",
                        details: [:]
                    ),
                    nil,
                    nil
                )
            }
            return (
                CoordinatorCheckResult(
                    name: "gh-rate-limit",
                    status: parsed.remaining > 0 ? .pass : .fail,
                    message: parsed.remaining > 0 ? "gh core rate limit is available" : "gh core rate limit is exhausted",
                    details: ["limit": "\(parsed.limit)", "remaining": "\(parsed.remaining)"]
                ),
                parsed.remaining,
                parsed.limit
            )
        } catch {
            return (
                CoordinatorCheckResult(
                    name: "gh-rate-limit",
                    status: .fail,
                    message: "gh rate limit check could not run",
                    details: ["error": error.localizedDescription]
                ),
                nil,
                nil
            )
        }
    }

    private func revParseCheck(ref: String, name: String) -> (check: CoordinatorCheckResult, sha: String?) {
        let result = revParse(ref: ref)
        guard let sha = result.sha else {
            return (
                CoordinatorCheckResult(
                    name: name,
                    status: .fail,
                    message: "\(ref) is unavailable",
                    details: result.details
                ),
                nil
            )
        }
        return (
            CoordinatorCheckResult(
                name: name,
                status: .pass,
                message: "\(ref) resolves to \(sha)",
                details: ["sha": sha]
            ),
            sha
        )
    }

    private func revParse(ref: String) -> (sha: String?, details: [String: String]) {
        let invocation = CoordinatorProcessInvocation(command: ["git", "rev-parse", "--verify", ref], workingDirectory: repositoryRoot)
        do {
            let result = try runner.run(invocation)
            guard result.succeeded else {
                return (nil, ["exitCode": "\(result.exitCode)"])
            }
            let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return sha.isEmpty ? (nil, ["exitCode": "\(result.exitCode)"]) : (sha, ["sha": sha])
        } catch {
            return (nil, ["error": error.localizedDescription])
        }
    }

    private func shaDriftCheck(localMain: (sha: String?, details: [String: String]), originMain: String?)
        -> CoordinatorCheckResult
    {
        guard let localSHA = localMain.sha else {
            return CoordinatorCheckResult(
                name: "sha-drift",
                status: .fail,
                message: "local main is unavailable",
                details: localMain.details
            )
        }
        guard let originMain else {
            return CoordinatorCheckResult(
                name: "sha-drift",
                status: .fail,
                message: "origin/main is unavailable",
                details: ["main": localSHA]
            )
        }
        let details = ["main": localSHA, "originMain": originMain]
        guard localSHA == originMain else {
            return CoordinatorCheckResult(
                name: "sha-drift",
                status: .fail,
                message: "local main differs from origin/main",
                details: details
            )
        }
        return CoordinatorCheckResult(
            name: "sha-drift",
            status: .pass,
            message: "local main matches origin/main",
            details: details
        )
    }

    private func parseCoreRateLimit(_ output: String) -> (remaining: Int, limit: Int)? {
        guard let data = output.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let resources = object["resources"] as? [String: Any],
            let core = resources["core"] as? [String: Any],
            let remaining = core["remaining"] as? Int,
            let limit = core["limit"] as? Int
        else {
            return nil
        }
        return (remaining, limit)
    }
}
