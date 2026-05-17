import Foundation

public struct CoordinatorControlMarker: Codable, Equatable, Sendable {
    public let reason: String
    public let createdAt: Date

    public init(reason: String, createdAt: Date = Date()) {
        self.reason = reason
        self.createdAt = createdAt
    }
}

public struct CoordinatorControlState: Codable, Equatable, Sendable {
    public let pause: CoordinatorControlMarker?
    public let stop: CoordinatorControlMarker?

    public var paused: Bool { pause != nil }
    public var stopped: Bool { stop != nil }
}

public struct CoordinatorControlService {
    public let paths: CoordinatorPaths
    private let fileManager: FileManager

    public init(paths: CoordinatorPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func state() throws -> CoordinatorControlState {
        CoordinatorControlState(
            pause: try loadMarker(at: paths.pauseFile),
            stop: try loadMarker(at: paths.stopFile)
        )
    }

    @discardableResult
    public func pause(reason: String, now: Date = Date()) throws -> CoordinatorControlMarker {
        try writeMarker(CoordinatorControlMarker(reason: reason, createdAt: now), to: paths.pauseFile)
    }

    public func resume() throws {
        try removeMarker(at: paths.pauseFile)
    }

    @discardableResult
    public func stop(reason: String, now: Date = Date()) throws -> CoordinatorControlMarker {
        try writeMarker(CoordinatorControlMarker(reason: reason, createdAt: now), to: paths.stopFile)
    }

    public func clearStop() throws {
        try removeMarker(at: paths.stopFile)
    }

    private func loadMarker(at url: URL) throws -> CoordinatorControlMarker? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try CoordinatorJSON.decoder().decode(CoordinatorControlMarker.self, from: data)
    }

    @discardableResult
    private func writeMarker(_ marker: CoordinatorControlMarker, to url: URL) throws -> CoordinatorControlMarker {
        try fileManager.createDirectory(
            at: paths.stateDirectory,
            withIntermediateDirectories: true,
            attributes: CoordinatorFilePermissions.directoryAttributes
        )
        try CoordinatorFilePermissions.applyDirectoryPermissions(to: paths.stateDirectory, fileManager: fileManager)
        let data = try CoordinatorJSON.encoder().encode(marker)
        try data.write(to: url, options: .atomic)
        try CoordinatorFilePermissions.applyFilePermissions(to: url, fileManager: fileManager)
        return marker
    }

    private func removeMarker(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}
