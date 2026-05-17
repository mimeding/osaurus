import Foundation

public struct CoordinatorTickReportArtifact: Codable, Equatable, Sendable {
    public let path: String
    public let markdown: String
}

public struct CoordinatorTickReportService {
    public let paths: CoordinatorPaths
    private let fileManager: FileManager

    public init(paths: CoordinatorPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func defaultArtifactURL(kind: String, now: Date = Date()) -> URL {
        paths.tickReportsDirectory
            .appendingPathComponent("\(CoordinatorTimestamp.fileStamp(now))-\(CoordinatorPaths.fileComponent(for: kind)).md")
    }

    @discardableResult
    public func writeHeartbeatReport(_ report: CoordinatorHeartbeatReport, output: URL? = nil) throws
        -> CoordinatorTickReportArtifact
    {
        let url = output ?? defaultArtifactURL(kind: "heartbeat", now: report.generatedAt)
        let markdown = renderHeartbeatReport(report)
        try write(markdown: markdown, to: url)
        return CoordinatorTickReportArtifact(path: url.path, markdown: markdown)
    }

    @discardableResult
    public func writeStatusReport(_ snapshot: CoordinatorStatusSnapshot, now: Date = Date(), output: URL? = nil) throws
        -> CoordinatorTickReportArtifact
    {
        let url = output ?? defaultArtifactURL(kind: "status", now: now)
        let markdown = renderStatusReport(snapshot, now: now)
        try write(markdown: markdown, to: url)
        return CoordinatorTickReportArtifact(path: url.path, markdown: markdown)
    }

    private func renderHeartbeatReport(_ report: CoordinatorHeartbeatReport) -> String {
        var lines: [String] = []
        lines.append("# Coordinator Heartbeat Tick")
        lines.append("")
        lines.append("- Generated: \(CoordinatorTimestamp.isoString(report.generatedAt))")
        lines.append("- Root: \(report.root)")
        lines.append("- Tick report: \(report.tickReportPath)")
        lines.append("")
        lines.append("## Preflight")
        lines.append("")
        lines.append("- Status: \(report.preflight.ok ? "pass" : "fail")")
        for check in report.preflight.checks {
            lines.append("- \(check.name): \(check.status.rawValue) - \(check.message)")
        }
        lines.append("")
        lines.append("## Plan Drift")
        lines.append("")
        lines.append("- Status: \(report.planDrift.status.rawValue)")
        lines.append("- Message: \(report.planDrift.message)")
        lines.append("- Baseline: \(report.planDrift.baselineSHA ?? "unavailable")")
        if !report.planDrift.changedPaths.isEmpty {
            for path in report.planDrift.changedPaths {
                lines.append("- Changed: \(path)")
            }
        }
        lines.append("")
        lines.append("## Locks")
        lines.append("")
        lines.append("- Reaped: \(report.reapedLocks.count)")
        for lock in report.reapedLocks {
            lines.append("- \(lock.resource): owner=\(lock.owner)")
        }
        lines.append("")
        lines.append("## Control")
        lines.append("")
        lines.append("- Paused: \(report.control.paused ? "yes" : "no")")
        lines.append("- Stopped: \(report.control.stopped ? "yes" : "no")")
        if let pause = report.control.pause {
            lines.append("- Pause reason: \(pause.reason)")
        }
        if let stop = report.control.stop {
            lines.append("- Stop reason: \(stop.reason)")
        }
        lines.append("")
        lines.append("## Gate Main")
        lines.append("")
        lines.append("- Action: \(report.gate.action)")
        lines.append("- Status: \(report.gate.status)")
        lines.append("- Reason: \(report.gate.reason ?? "none")")
        lines.append("- Main SHA: \(report.gate.mainSHA ?? "unavailable")")
        lines.append("- Evidence: \(report.gate.evidenceDirectory ?? "none")")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func renderStatusReport(_ snapshot: CoordinatorStatusSnapshot, now: Date) -> String {
        var lines: [String] = []
        lines.append("# Coordinator Tick Report")
        lines.append("")
        lines.append("- Generated: \(CoordinatorTimestamp.isoString(now))")
        lines.append("- Root: \(snapshot.root)")
        lines.append("- Initialized: \(snapshot.initialized ? "yes" : "no")")
        lines.append("- Paused: \(snapshot.paused ? "yes" : "no")")
        lines.append("- Stopped: \(snapshot.stopped ? "yes" : "no")")
        lines.append("- Active locks: \(snapshot.activeLocks.count)")
        lines.append("- Expired locks: \(snapshot.expiredLocks.count)")
        lines.append("")
        lines.append("## Directories")
        lines.append("")
        for directory in snapshot.directories.sorted(by: { $0.name < $1.name }) {
            lines.append("- \(directory.name): \(directory.exists ? "present" : "missing")")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func write(markdown: String, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: CoordinatorFilePermissions.directoryAttributes
        )
        if fileManager.fileExists(atPath: paths.artifactsDirectory.path) {
            try CoordinatorFilePermissions.applyDirectoryPermissions(to: paths.artifactsDirectory, fileManager: fileManager)
        }
        try CoordinatorFilePermissions.applyDirectoryPermissions(to: directory, fileManager: fileManager)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        try CoordinatorFilePermissions.applyFilePermissions(to: url, fileManager: fileManager)
    }
}

enum CoordinatorTimestamp {
    static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }
}
