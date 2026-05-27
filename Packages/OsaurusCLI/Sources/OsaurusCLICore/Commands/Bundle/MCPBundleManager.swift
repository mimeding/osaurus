//
//  MCPBundleManager.swift
//  osaurus
//
//  Manages extraction and lifecycle of MCPB (MCP Bundle) files.
//

import Foundation
import MCP
import OsaurusRepository

class MCPBundleManager {
    struct BundleInfo {
        let extractedPath: String
        let manifestPath: String
        let bundleUUID: String

        func parseManifest() throws -> MCPBundleManifest {
            let data = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
            let decoder = JSONDecoder()
            do {
                return try decoder.decode(MCPBundleManifest.self, from: data)
            } catch {
                throw BundleLoadError.invalidManifest(error.localizedDescription)
            }
        }

        func cleanup() {
            try? FileManager.default.removeItem(atPath: extractedPath)
        }

        func launchServer(workingDirectory: String) async throws -> ServerInfo {
            let manifest = try parseManifest()

            // Launch MCP server process with stdio transport
            let process = Process()
            process.currentDirectoryPath = workingDirectory

            // Get entry point from manifest (supports both formats)
            let (cmdName, args, _) = manifest.getEntryPoint()

            // Resolve executable path
            let cmdPath: String
            if cmdName.hasPrefix("/") {
                cmdPath = cmdName
            } else {
                // Try to find in PATH
                if let resolved = Shell.which(cmdName) {
                    cmdPath = resolved
                } else {
                    cmdPath = cmdName
                }
            }

            process.executableURL = URL(fileURLWithPath: cmdPath)
            process.arguments = args

            // Set up environment
            var env = ProcessInfo.processInfo.environment
            for (key, value) in manifest.resolveEnvironment() {
                env[key] = value
            }
            process.environment = env

            // Create pipes for stdio
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = FileHandle.standardError

            do {
                try process.run()
            } catch {
                throw BundleLoadError.serverLaunchFailed(error.localizedDescription)
            }

            // Create server info
            let serverInfo = ServerInfo(
                process: process,
                manifest: manifest
            )

            return serverInfo
        }
    }

    struct ServerInfo {
        let process: Process
        let manifest: MCPBundleManifest

        func discoverTools() async throws -> [ToolInfo] {
            // In MVP, we don't implement tool discovery
            // Just communicate manifest information
            return []
        }

        func shutdown() {
            process.terminate()
        }
    }

    struct ToolInfo {
        let name: String
        let description: String?
    }

    // MARK: - Extraction

    static func extract(_ bundlePath: String) throws -> BundleInfo {
        let uuid = UUID().uuidString
        let extractPath = "/tmp/osaurus-bundles/\(uuid)"

        try FileManager.default.createDirectory(atPath: extractPath, withIntermediateDirectories: true)

        // Use unzip CLI
        try unzipWithCLI(bundlePath, to: extractPath)

        // Defense in depth: reject ZIP-slip and symlink escape entries
        // before reading the bundle manifest. Bundles are loaded from
        // local paths the user picked, so they're trusted-ish, but
        // validating costs almost nothing and shrinks the trust surface.
        do {
            try ArchiveSafety.validate(extractedRoot: URL(fileURLWithPath: extractPath))
        } catch {
            try? FileManager.default.removeItem(atPath: extractPath)
            throw BundleLoadError.extractionFailed("Unsafe bundle layout: \(error)")
        }

        let manifestPath = "\(extractPath)/manifest.json"
        guard FileManager.default.fileExists(atPath: manifestPath) else {
            try? FileManager.default.removeItem(atPath: extractPath)
            throw BundleLoadError.missingManifest
        }

        return BundleInfo(extractedPath: extractPath, manifestPath: manifestPath, bundleUUID: uuid)
    }

    private static func unzipWithCLI(_ zipPath: String, to destination: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", zipPath, "-d", destination]

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                throw BundleLoadError.extractionFailed("unzip exited with status \(process.terminationStatus)")
            }
        } catch {
            throw BundleLoadError.extractionFailed(error.localizedDescription)
        }
    }
}

// MARK: - Shell Helper

enum Shell {
    static func which(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
