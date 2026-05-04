//
//  ExternalOfficeRuntime.swift
//  osaurus
//
//  Lazy detector for external office suites that expose a `soffice`
//  executable. Construction is intentionally cheap: filesystem and process
//  probes happen only when `snapshot()` is awaited.
//

import Foundation

public final class ExternalOfficeRuntime: @unchecked Sendable {
    public static let shared = ExternalOfficeRuntime()

    public enum Kind: String, Hashable, Sendable {
        case libreOffice = "LibreOffice"
        case openOffice = "OpenOffice"
    }

    public struct Conversion: Hashable, Sendable {
        public let sourceExtension: String
        public let targetExtension: String

        public init(sourceExtension: String, targetExtension: String) {
            self.sourceExtension = Self.normalizedExtension(sourceExtension)
            self.targetExtension = Self.normalizedExtension(targetExtension)
        }

        public static let docToPDF = Conversion(sourceExtension: "doc", targetExtension: "pdf")
        public static let docxToPDF = Conversion(sourceExtension: "docx", targetExtension: "pdf")
        public static let odtToPDF = Conversion(sourceExtension: "odt", targetExtension: "pdf")
        public static let rtfToPDF = Conversion(sourceExtension: "rtf", targetExtension: "pdf")
        public static let xlsToPDF = Conversion(sourceExtension: "xls", targetExtension: "pdf")
        public static let xlsxToPDF = Conversion(sourceExtension: "xlsx", targetExtension: "pdf")
        public static let odsToPDF = Conversion(sourceExtension: "ods", targetExtension: "pdf")
        public static let pptToPDF = Conversion(sourceExtension: "ppt", targetExtension: "pdf")
        public static let pptxToPDF = Conversion(sourceExtension: "pptx", targetExtension: "pdf")
        public static let pptxToPNG = Conversion(sourceExtension: "pptx", targetExtension: "png")
        public static let pptxRepair = Conversion(sourceExtension: "pptx", targetExtension: "pptx")
        public static let odpToPDF = Conversion(sourceExtension: "odp", targetExtension: "pdf")

        private static func normalizedExtension(_ value: String) -> String {
            value
                .trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
                .lowercased()
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public let available: Bool
        public let kind: Kind?
        public let version: String?
        public let executablePath: URL?
        public let supportedConversions: Set<Conversion>

        public init(
            available: Bool,
            kind: Kind?,
            version: String?,
            executablePath: URL?,
            supportedConversions: Set<Conversion>
        ) {
            self.available = available
            self.kind = kind
            self.version = version
            self.executablePath = executablePath
            self.supportedConversions = supportedConversions
        }

        public static let unavailable = Snapshot(
            available: false,
            kind: nil,
            version: nil,
            executablePath: nil,
            supportedConversions: []
        )
    }

    struct ProbeCandidate: Equatable, Sendable {
        let kind: Kind?
        let executableURL: URL
    }

    struct ParsedVersion: Equatable, Sendable {
        let kind: Kind?
        let version: String?
    }

    struct ProcessResult: Sendable {
        let exitStatus: Int32
        let output: String
    }

    typealias ProcessRunner = @Sendable (URL, [String]) async -> ProcessResult?

    private struct Configuration: Sendable {
        let applicationCandidates: [ProbeCandidate]
        let whichExecutableURL: URL
        let processRunner: ProcessRunner

        static let production = Configuration(
            applicationCandidates: [
                ProbeCandidate(
                    kind: .libreOffice,
                    executableURL: URL(
                        fileURLWithPath: "/Applications/LibreOffice.app/Contents/MacOS/soffice"
                    )
                ),
                ProbeCandidate(
                    kind: .openOffice,
                    executableURL: URL(
                        fileURLWithPath: "/Applications/OpenOffice.app/Contents/MacOS/soffice"
                    )
                ),
            ],
            whichExecutableURL: URL(fileURLWithPath: "/usr/bin/which"),
            processRunner: { executableURL, arguments in
                await ExternalOfficeRuntime.runProcess(
                    executableURL: executableURL,
                    arguments: arguments
                )
            }
        )
    }

    private struct InFlightDetection {
        let id: Int
        let task: Task<Snapshot, Never>
    }

    private enum SnapshotLookup {
        case cached(Snapshot)
        case inFlight(Task<Snapshot, Never>)
        case started(id: Int, task: Task<Snapshot, Never>)
    }

    private static let standardSupportedConversions: Set<Conversion> = [
        .docToPDF,
        .docxToPDF,
        .odtToPDF,
        .rtfToPDF,
        .xlsToPDF,
        .xlsxToPDF,
        .odsToPDF,
        .pptToPDF,
        .pptxToPDF,
        .pptxToPNG,
        .pptxRepair,
        .odpToPDF,
    ]

    private let configuration: Configuration
    private let lock = NSLock()
    private var cachedSnapshot: Snapshot?
    private var inFlightDetection: InFlightDetection?
    private var nextDetectionID = 0

    private init() {
        self.configuration = .production
    }

    init(
        applicationCandidates: [ProbeCandidate],
        whichExecutableURL: URL
    ) {
        self.configuration = Configuration(
            applicationCandidates: applicationCandidates,
            whichExecutableURL: whichExecutableURL,
            processRunner: { executableURL, arguments in
                await ExternalOfficeRuntime.runProcess(
                    executableURL: executableURL,
                    arguments: arguments
                )
            }
        )
    }

    public func snapshot() async -> Snapshot {
        switch prepareSnapshotLookup() {
        case .cached(let snapshot):
            return snapshot

        case .inFlight(let task):
            return await task.value

        case .started(let id, let task):
            let snapshot = await task.value
            completeDetection(id: id, snapshot: snapshot)
            return snapshot
        }
    }

    func invalidate() {
        lock.lock()
        cachedSnapshot = nil
        inFlightDetection = nil
        nextDetectionID += 1
        lock.unlock()
    }

    private func prepareSnapshotLookup() -> SnapshotLookup {
        lock.lock()
        defer { lock.unlock() }

        if let cachedSnapshot {
            return .cached(cachedSnapshot)
        }

        if let inFlightDetection {
            return .inFlight(inFlightDetection.task)
        }

        let id = nextDetectionID
        nextDetectionID += 1

        let configuration = configuration
        let task = Task.detached(priority: .utility) {
            await Self.detect(configuration: configuration)
        }
        inFlightDetection = InFlightDetection(id: id, task: task)
        return .started(id: id, task: task)
    }

    private func completeDetection(id: Int, snapshot: Snapshot) {
        lock.lock()
        defer { lock.unlock() }

        guard inFlightDetection?.id == id else {
            return
        }

        cachedSnapshot = snapshot
        inFlightDetection = nil
    }

    private static func detect(configuration: Configuration) async -> Snapshot {
        for candidate in configuration.applicationCandidates {
            if let snapshot = await probe(candidate, processRunner: configuration.processRunner) {
                return snapshot
            }
        }

        guard
            let pathCandidate = await resolvePathCandidate(configuration: configuration),
            let snapshot = await probe(
                pathCandidate,
                processRunner: configuration.processRunner
            )
        else {
            return .unavailable
        }

        return snapshot
    }

    private static func resolvePathCandidate(configuration: Configuration) async -> ProbeCandidate? {
        guard
            let result = await configuration.processRunner(configuration.whichExecutableURL, ["soffice"]),
            result.exitStatus == 0,
            let path = firstPathLine(in: result.output)
        else {
            return nil
        }

        let executableURL = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return nil
        }

        return ProbeCandidate(kind: nil, executableURL: executableURL)
    }

    private static func firstPathLine(in output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func probe(
        _ candidate: ProbeCandidate,
        processRunner: ProcessRunner
    ) async -> Snapshot? {
        let executableURL = candidate.executableURL.standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return nil
        }

        let versionResult = await processRunner(executableURL, ["--version"])
        let parsedVersion: ParsedVersion?
        if let versionResult, versionResult.exitStatus == 0 {
            parsedVersion = parseVersionOutput(versionResult.output)
        } else {
            parsedVersion = nil
        }

        return Snapshot(
            available: true,
            kind: parsedVersion?.kind ?? candidate.kind,
            version: parsedVersion?.version,
            executablePath: executableURL,
            supportedConversions: standardSupportedConversions
        )
    }

    static func parseVersionOutput(_ output: String) -> ParsedVersion {
        let normalizedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedOutput = normalizedOutput.lowercased()

        let kind: Kind?
        if lowercasedOutput.contains("libreoffice") {
            kind = .libreOffice
        } else if lowercasedOutput.contains("openoffice") {
            kind = .openOffice
        } else {
            kind = nil
        }

        let version =
            normalizedOutput
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .compactMap { versionPrefix(in: String($0)) }
            .first

        return ParsedVersion(kind: kind, version: version)
    }

    private static func versionPrefix(in token: String) -> String? {
        guard
            let first = token.unicodeScalars.first,
            CharacterSet.decimalDigits.contains(first)
        else {
            return nil
        }

        var result = String.UnicodeScalarView()
        var sawDot = false
        for scalar in token.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" {
                if scalar == "." {
                    sawDot = true
                }
                result.append(scalar)
            } else {
                break
            }
        }

        let version = String(result).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return sawDot && !version.isEmpty ? version : nil
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String]
    ) async -> ProcessResult? {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                return nil
            }

            process.waitUntilExit()

            var outputData = stdout.fileHandleForReading.readDataToEndOfFile()
            outputData.append(stderr.fileHandleForReading.readDataToEndOfFile())

            return ProcessResult(
                exitStatus: process.terminationStatus,
                output: String(data: outputData, encoding: .utf8) ?? ""
            )
        }.value
    }
}
