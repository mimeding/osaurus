//
//  AgentWorkspaceStore.swift
//  osaurus
//
//  JSON persistence and bounded source inspection for agent workspaces.
//

import Foundation

public enum AgentWorkspaceStoreError: Error, LocalizedError, Sendable {
    case emptyName
    case workspaceNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Workspace name cannot be empty."
        case let .workspaceNotFound(id):
            return "Workspace not found: \(id.uuidString)."
        }
    }
}

public struct AgentWorkspaceSourceAuthorization: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        case denied
        case trustedLocal
        case scopedRoots([URL])
    }

    public let mode: Mode
    public let allowSensitivePaths: Bool

    public static let denied = AgentWorkspaceSourceAuthorization(mode: .denied)
    public static let trustedLocal = AgentWorkspaceSourceAuthorization(mode: .trustedLocal)

    public static func scopedRoots(
        _ roots: [URL],
        allowSensitivePaths: Bool = false
    ) -> AgentWorkspaceSourceAuthorization {
        AgentWorkspaceSourceAuthorization(
            mode: .scopedRoots(roots),
            allowSensitivePaths: allowSensitivePaths
        )
    }

    public init(mode: Mode, allowSensitivePaths: Bool = false) {
        self.mode = mode
        self.allowSensitivePaths = allowSensitivePaths
    }
}

public enum AgentWorkspaceStore {
    public static let defaultFileReadLimit = 64 * 1024
    public static let defaultFileSummaryLimit = 1_500
    public static let defaultFolderEntryLimit = 40

    public static func loadAll(agentId: UUID) -> [AgentWorkspace] {
        let directory = OsaurusPaths.agentWorkspacesDirectory(for: agentId)
        OsaurusPaths.ensureExistsSilent(directory)

        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var workspaces: [AgentWorkspace] = []
        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                let workspace = try decoder.decode(AgentWorkspace.self, from: data)
                if workspace.agentId == agentId {
                    workspaces.append(workspace)
                }
            } catch {
                print("[Osaurus] Failed to load agent workspace \(file.lastPathComponent): \(error)")
            }
        }

        return workspaces.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    public static func load(agentId: UUID, workspaceId: UUID) -> AgentWorkspace? {
        let url = OsaurusPaths.agentWorkspaceFile(agentId: agentId, workspaceId: workspaceId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let workspace = try decoder.decode(AgentWorkspace.self, from: data)
            return workspace.agentId == agentId ? workspace : nil
        } catch {
            print("[Osaurus] Failed to load agent workspace \(workspaceId): \(error)")
            return nil
        }
    }

    @discardableResult
    public static func create(
        agentId: UUID,
        name: String,
        description: String = "",
        paths: [String] = [],
        sourceAuthorization: AgentWorkspaceSourceAuthorization = .denied
    ) throws -> AgentWorkspace {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw AgentWorkspaceStoreError.emptyName }

        let now = Date()
        var workspace = AgentWorkspace(
            agentId: agentId,
            name: trimmedName,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: now,
            updatedAt: now
        )
        workspace.sources = paths.map { inspectSource(path: $0, authorization: sourceAuthorization) }
        save(workspace)
        return workspace
    }

    @discardableResult
    public static func attachPaths(
        agentId: UUID,
        workspaceId: UUID,
        paths: [String],
        sourceAuthorization: AgentWorkspaceSourceAuthorization = .denied
    ) throws -> AgentWorkspace {
        guard var workspace = load(agentId: agentId, workspaceId: workspaceId) else {
            throw AgentWorkspaceStoreError.workspaceNotFound(workspaceId)
        }
        workspace.sources.append(contentsOf: paths.map { inspectSource(path: $0, authorization: sourceAuthorization) })
        workspace.updatedAt = Date()
        save(workspace)
        return workspace
    }

    @discardableResult
    public static func delete(agentId: UUID, workspaceId: UUID) -> Bool {
        let url = OsaurusPaths.agentWorkspaceFile(agentId: agentId, workspaceId: workspaceId)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            print("[Osaurus] Failed to delete agent workspace \(workspaceId): \(error)")
            return false
        }
    }

    public static func deleteAll(for agentId: UUID) throws {
        let directory = OsaurusPaths.agentWorkspacesDirectory(for: agentId)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    public static func promptSummary(
        agentId: UUID,
        canReadSources: Bool,
        maxWorkspaces: Int = 4,
        maxSourcesPerWorkspace: Int = 6,
        maxSourceSummaryCharacters: Int = 600
    ) -> AgentWorkspacePromptSummary? {
        let allWorkspaces = loadAll(agentId: agentId)
        guard !allWorkspaces.isEmpty else { return nil }

        var omittedSources = 0
        let limitedWorkspaces = allWorkspaces.prefix(max(0, maxWorkspaces))
        let promptWorkspaces = limitedWorkspaces.map { workspace in
            let sources = workspace.sources.prefix(max(0, maxSourcesPerWorkspace)).map { source in
                AgentWorkspacePromptSource(
                    kind: source.kind,
                    path: canReadSources ? source.path : source.displayName,
                    displayName: source.displayName,
                    status: source.status,
                    summary: canReadSources
                        ? capped(source.summary, maxCharacters: maxSourceSummaryCharacters)
                        : nil,
                    error: canReadSources ? source.error : nil
                )
            }
            if workspace.sources.count > sources.count {
                omittedSources += workspace.sources.count - sources.count
            }
            return AgentWorkspacePromptWorkspace(
                name: workspace.name,
                description: workspace.description,
                sources: Array(sources)
            )
        }

        return AgentWorkspacePromptSummary(
            workspaces: Array(promptWorkspaces),
            omittedWorkspaces: max(0, allWorkspaces.count - promptWorkspaces.count),
            omittedSources: omittedSources,
            canReadSources: canReadSources
        )
    }

    public static func inspectSource(
        path rawPath: String,
        authorization: AgentWorkspaceSourceAuthorization = .denied,
        fileReadLimit: Int = defaultFileReadLimit,
        fileSummaryLimit: Int = defaultFileSummaryLimit,
        folderEntryLimit: Int = defaultFolderEntryLimit
    ) -> AgentWorkspaceSource {
        let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return AgentWorkspaceSource(
                kind: .missing,
                path: rawPath,
                displayName: "Empty path",
                status: .error,
                error: "Source path is empty."
            )
        }

        let url = url(forUserPath: trimmedPath)
        let path = url.standardizedFileURL.path
        let displayName = url.lastPathComponent.isEmpty ? path : url.lastPathComponent

        if let rejection = authorizeSourceURL(url, authorization: authorization) {
            return AgentWorkspaceSource(
                kind: .missing,
                path: path,
                displayName: displayName,
                status: .skipped,
                error: rejection
            )
        }

        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return AgentWorkspaceSource(
                kind: .missing,
                path: path,
                displayName: displayName,
                status: .error,
                error: "Source path does not exist."
            )
        }

        if isDirectory.boolValue {
            return inspectFolder(
                url: URL(fileURLWithPath: path, isDirectory: true),
                displayName: displayName,
                entryLimit: folderEntryLimit
            )
        }
        return inspectFile(
            url: URL(fileURLWithPath: path, isDirectory: false),
            displayName: displayName,
            readLimit: fileReadLimit,
            summaryLimit: fileSummaryLimit
        )
    }

    private static func save(_ workspace: AgentWorkspace) {
        let url = OsaurusPaths.agentWorkspaceFile(agentId: workspace.agentId, workspaceId: workspace.id)
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(workspace)
            try data.write(to: url, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save agent workspace \(workspace.id): \(error)")
        }
    }

    private static func inspectFile(
        url: URL,
        displayName: String,
        readLimit: Int,
        summaryLimit: Int
    ) -> AgentWorkspaceSource {
        let byteCount = fileSize(url)
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: max(0, readLimit)) ?? Data()
            guard !data.contains(0) else {
                return AgentWorkspaceSource(
                    kind: .file,
                    path: url.path,
                    displayName: displayName,
                    status: .skipped,
                    byteCount: byteCount,
                    error: "Binary file skipped."
                )
            }
            guard let text = String(data: data, encoding: .utf8) else {
                return AgentWorkspaceSource(
                    kind: .file,
                    path: url.path,
                    displayName: displayName,
                    status: .skipped,
                    byteCount: byteCount,
                    error: "File is not valid UTF-8 text."
                )
            }
            let suffix = byteCount.map { $0 > Int64(readLimit) } == true ? " (truncated)" : ""
            let summary = (capped(normalizeWhitespace(text), maxCharacters: summaryLimit) ?? "") + suffix
            return AgentWorkspaceSource(
                kind: .file,
                path: url.path,
                displayName: displayName,
                status: .indexed,
                byteCount: byteCount,
                summary: summary,
                indexedAt: Date()
            )
        } catch {
            return AgentWorkspaceSource(
                kind: .file,
                path: url.path,
                displayName: displayName,
                status: .error,
                byteCount: byteCount,
                error: error.localizedDescription
            )
        }
    }

    private static func inspectFolder(
        url: URL,
        displayName: String,
        entryLimit: Int
    ) -> AgentWorkspaceSource {
        do {
            let entries = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
            let sorted = entries.sorted {
                $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
            }
            let visibleEntries = sorted.filter { !isSensitiveSourcePath($0) }
            let sample = visibleEntries.prefix(max(0, entryLimit)).map { entry -> String in
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return isDirectory ? "\(entry.lastPathComponent)/" : entry.lastPathComponent
            }
            var summary =
                sample.isEmpty
                ? "Folder is empty."
                : "Top-level entries: \(sample.joined(separator: ", "))."
            let omitted = entries.count - sample.count
            if omitted > 0 {
                summary += " \(omitted) additional entries omitted."
            }
            return AgentWorkspaceSource(
                kind: .folder,
                path: url.path,
                displayName: displayName,
                status: .indexed,
                itemCount: entries.count,
                summary: summary,
                indexedAt: Date()
            )
        } catch {
            return AgentWorkspaceSource(
                kind: .folder,
                path: url.path,
                displayName: displayName,
                status: .error,
                error: error.localizedDescription
            )
        }
    }

    private static func fileSize(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
            let size = values.fileSize
        else {
            return nil
        }
        return Int64(size)
    }

    private static func url(forUserPath path: String) -> URL {
        if path == "~" {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        if path.hasPrefix("~/") {
            let suffix = String(path.dropFirst(2))
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(suffix)
        }
        return URL(fileURLWithPath: path)
    }

    private static func authorizeSourceURL(
        _ url: URL,
        authorization: AgentWorkspaceSourceAuthorization
    ) -> String? {
        switch authorization.mode {
        case .denied:
            return "Source inspection requires a trusted local caller or an explicit scoped root."
        case .trustedLocal:
            break
        case .scopedRoots(let roots):
            guard isURL(url, containedInAnyOf: roots) else {
                return "Source path is outside the authorized workspace roots."
            }
        }

        if !authorization.allowSensitivePaths, isSensitiveSourcePath(url) {
            return "Sensitive source paths are not eligible for workspace summaries."
        }
        return nil
    }

    private static func isURL(_ url: URL, containedInAnyOf roots: [URL]) -> Bool {
        roots.contains { root in
            let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
            let candidatePath = url.resolvingSymlinksInPath().standardizedFileURL.path
            return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
        }
    }

    private static func isSensitiveSourcePath(_ url: URL) -> Bool {
        let realURL = url.resolvingSymlinksInPath().standardizedFileURL
        let path = realURL.path
        let components = realURL.pathComponents.map { $0.lowercased() }
        let systemRoots: Set<String> = [
            "/",
            "/bin",
            "/cores",
            "/dev",
            "/etc",
            "/library",
            "/network",
            "/sbin",
            "/system",
            "/usr",
        ]
        if systemRoots.contains(path.lowercased()) { return true }
        if path.hasPrefix("/System/")
            || path.hasPrefix("/Library/")
            || path.hasPrefix("/private/etc/")
            || path.hasPrefix("/private/var/db/")
            || path.hasPrefix("/private/var/root/")
            || path.hasPrefix("/usr/")
            || path.hasPrefix("/etc/")
            || path.hasPrefix("/var/db/")
            || path.hasPrefix("/var/root/")
        {
            return true
        }
        if components.contains("keychains") { return true }
        return FolderToolHelpers.isSecretPath(fileURL: realURL)
    }

    private static func normalizeWhitespace(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func capped(_ value: String?, maxCharacters: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard maxCharacters >= 0, trimmed.count > maxCharacters else { return trimmed }
        return String(trimmed.prefix(maxCharacters)) + "..."
    }
}
