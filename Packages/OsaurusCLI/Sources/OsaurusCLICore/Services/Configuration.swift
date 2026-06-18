//
//  Configuration.swift
//  osaurus
//
//  Service for reading CLI configuration including server port and tools directory paths.
//

import Foundation
import OsaurusRepository

public struct Configuration {
    /// Resolved data directory for Osaurus.
    public static func root() -> URL {
        ToolsPaths.root()
    }

    public static func resolveConfiguredPort() -> Int? {
        if let env = ProcessInfo.processInfo.environment["OSU_PORT"], let p = Int(env) {
            return p
        }

        let fm = FileManager.default
        let locations = AppDataLocationResolver.resolve(overrideRoot: ToolsPaths.overrideRoot)

        let configCandidates = locations.configSearchDirectories.map {
            $0.appendingPathComponent("server.json")
        }
        let rootCandidates = locations.dataSearchRoots.map {
            $0.appendingPathComponent("ServerConfiguration.json")
        }
        let candidates = (configCandidates + rootCandidates).deduplicatedByPath()

        guard let configURL = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else {
            return nil
        }

        struct PartialConfig: Decodable { let port: Int? }
        do {
            let data = try Data(contentsOf: configURL)
            let cfg = try JSONDecoder().decode(PartialConfig.self, from: data)
            return cfg.port
        } catch {
            return nil
        }
    }

    public static func toolsRootDirectory() -> URL {
        ToolsPaths.toolsRootDirectory()
    }
}

private extension Array where Element == URL {
    func deduplicatedByPath() -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []
        for url in self {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            result.append(url)
        }
        return result
    }
}
