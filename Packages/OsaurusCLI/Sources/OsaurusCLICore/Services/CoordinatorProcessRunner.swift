import Foundation

public struct CoordinatorProcessInvocation: Codable, Equatable, Sendable {
    public let command: [String]
    public let workingDirectory: String?
    public let environment: [String: String]

    public init(command: [String], workingDirectory: URL? = nil, environment: [String: String] = [:]) {
        self.command = command
        self.workingDirectory = workingDirectory?.path
        self.environment = environment
    }
}

public struct CoordinatorProcessResult: Codable, Equatable, Sendable {
    public let invocation: CoordinatorProcessInvocation
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { exitCode == 0 }

    public init(invocation: CoordinatorProcessInvocation, exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.invocation = invocation
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum CoordinatorProcessRunnerError: LocalizedError, Equatable {
    case emptyCommand
    case temporaryFileUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .emptyCommand:
            return "Coordinator process invocation cannot be empty."
        case .temporaryFileUnavailable(let path):
            return "Unable to create coordinator process output file at \(path)."
        }
    }
}

public protocol CoordinatorProcessRunning {
    func run(_ invocation: CoordinatorProcessInvocation) throws -> CoordinatorProcessResult
}

public struct CoordinatorProcessRunner: CoordinatorProcessRunning {
    public init() {}

    public func run(_ invocation: CoordinatorProcessInvocation) throws -> CoordinatorProcessResult {
        guard !invocation.command.isEmpty else { throw CoordinatorProcessRunnerError.emptyCommand }

        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("osaurus-coord-process-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true,
            attributes: CoordinatorFilePermissions.directoryAttributes
        )
        try CoordinatorFilePermissions.applyDirectoryPermissions(to: temporaryDirectory, fileManager: fileManager)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let stdoutURL = temporaryDirectory.appendingPathComponent("stdout.txt")
        let stderrURL = temporaryDirectory.appendingPathComponent("stderr.txt")
        guard fileManager.createFile(
            atPath: stdoutURL.path,
            contents: nil,
            attributes: [FileAttributeKey.posixPermissions: NSNumber(value: CoordinatorFilePermissions.fileMode)]
        ) else {
            throw CoordinatorProcessRunnerError.temporaryFileUnavailable(stdoutURL.path)
        }
        guard fileManager.createFile(
            atPath: stderrURL.path,
            contents: nil,
            attributes: [FileAttributeKey.posixPermissions: NSNumber(value: CoordinatorFilePermissions.fileMode)]
        ) else {
            throw CoordinatorProcessRunnerError.temporaryFileUnavailable(stderrURL.path)
        }

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = invocation.command
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        if let workingDirectory = invocation.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }
        if !invocation.environment.isEmpty {
            var environment = ProcessInfo.processInfo.environment
            for (key, value) in invocation.environment {
                environment[key] = value
            }
            process.environment = environment
        }

        try process.run()
        process.waitUntilExit()
        try stdoutHandle.close()
        try stderrHandle.close()

        let stdout = String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self)
        let stderr = String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self)
        return CoordinatorProcessResult(
            invocation: invocation,
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }
}
