//
//  ServerConfigurationStore.swift
//  osaurus
//
//  Persistence for ServerConfiguration
//

import Foundation

@MainActor
enum ServerConfigurationStore {
    /// When set, configuration reads/writes use this directory instead of the default path.
    static var overrideDirectory: URL?

    static func load() -> ServerConfiguration? {
        let url = configurationFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(ServerConfiguration.self, from: Data(contentsOf: url))
        } catch {
            print("[Osaurus] Failed to load ServerConfiguration: \(error)")
            return nil
        }
    }

    /// Persist ServerConfiguration to disk. Errors are logged but swallowed
    /// to keep the API convenient for background auto-save flows that have
    /// no UI to report to. Callers that need to surface failures to the
    /// user (notably `ConfigurationView.saveConfiguration`) should use
    /// `saveThrowing` instead.
    static func save(_ configuration: ServerConfiguration) {
        do {
            try saveThrowing(configuration)
        } catch {
            print("[Osaurus] Failed to save ServerConfiguration: \(error)")
        }
    }

    /// Throwing variant of `save`. Propagates encode/write errors so a
    /// UI caller can catch them and fire a toast. See `05-CONFIGURABILITY-AUDIT.md`
    /// Issue 10 — silently swallowing write failures lets users believe
    /// their settings saved when they didn't (disk full, permissions,
    /// lock conflicts).
    static func saveThrowing(_ configuration: ServerConfiguration) throws {
        let url = configurationFileURL()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: url, options: [.atomic])
    }

    private static func configurationFileURL() -> URL {
        if let dir = overrideDirectory {
            return dir.appendingPathComponent("server.json")
        }
        return OsaurusPaths.resolvePath(new: OsaurusPaths.serverConfigFile(), legacy: "ServerConfiguration.json")
    }
}
