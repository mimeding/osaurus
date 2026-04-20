import Foundation
import Testing

@testable import OsaurusCore

@Suite("Shared artifact trust boundary hardening", .serialized)
struct SharedArtifactSecurityTests {

    @Test func processToolResult_sanitizesDestinationFilename() throws {
        let contextId = "artifact-dest-\(UUID().uuidString)"
        defer { cleanupArtifacts(contextId: contextId) }

        let toolResult = try makeToolResult(
            metadata: [
                "filename": "../exports/../../quarterly.md",
                "mime_type": "text/plain",
                "has_content": true,
            ],
            contentLines: ["safe payload"]
        )

        let processed = try #require(
            SharedArtifact.processToolResult(
                toolResult,
                contextId: contextId,
                contextType: .chat,
                executionMode: .none
            )
        )

        let contextDir = OsaurusPaths.contextArtifactsDir(contextId: contextId).resolvingSymlinksInPath()
        let artifactURL = URL(fileURLWithPath: processed.artifact.hostPath).resolvingSymlinksInPath()

        #expect(processed.artifact.filename == "quarterly.md")
        #expect(artifactURL.deletingLastPathComponent().path == contextDir.path)
        #expect(FileManager.default.fileExists(atPath: artifactURL.path))

        let enrichedArtifact = try #require(SharedArtifact.fromEnrichedToolResult(processed.enrichedToolResult))
        #expect(enrichedArtifact.filename == "quarterly.md")
    }

    @Test func processToolResult_rejectsInvalidDestinationFilename() throws {
        let contextId = "artifact-invalid-\(UUID().uuidString)"
        defer { cleanupArtifacts(contextId: contextId) }

        let toolResult = try makeToolResult(
            metadata: [
                "filename": "../..",
                "mime_type": "text/plain",
                "has_content": true,
            ],
            contentLines: ["unsafe payload"]
        )

        let processed = SharedArtifact.processToolResult(
            toolResult,
            contextId: contextId,
            contextType: .chat,
            executionMode: .none
        )

        #expect(processed == nil)
    }

    @Test func processToolResult_rejectsHostFolderPathTraversal() throws {
        try withTemporaryWorkspace { root in
            let contextId = "artifact-host-\(UUID().uuidString)"
            defer { cleanupArtifacts(contextId: contextId) }

            let fm = FileManager.default
            let workspaceRoot = root.appendingPathComponent("workspace", isDirectory: true)
            let outsideFile = root.appendingPathComponent("outside.txt")
            try fm.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
            try Data("outside".utf8).write(to: outsideFile)

            let context = FolderContext(
                rootPath: workspaceRoot,
                projectType: .unknown,
                tree: "",
                manifest: nil,
                gitStatus: nil,
                isGitRepo: false
            )
            let toolResult = try makeToolResult(
                metadata: [
                    "filename": "artifact.txt",
                    "mime_type": "text/plain",
                    "path": "../outside.txt",
                    "has_content": false,
                ]
            )

            let processed = SharedArtifact.processToolResult(
                toolResult,
                contextId: contextId,
                contextType: .chat,
                executionMode: .hostFolder(context)
            )

            #expect(processed == nil)
        }
    }

    @Test func processToolResult_rejectsAbsoluteHostFolderSourcePath() throws {
        try withTemporaryWorkspace { root in
            let contextId = "artifact-host-absolute-\(UUID().uuidString)"
            defer { cleanupArtifacts(contextId: contextId) }

            let fm = FileManager.default
            let workspaceRoot = root.appendingPathComponent("workspace", isDirectory: true)
            let sourceFile = workspaceRoot.appendingPathComponent("safe.txt")
            try fm.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
            try Data("safe".utf8).write(to: sourceFile)

            let context = FolderContext(
                rootPath: workspaceRoot,
                projectType: .unknown,
                tree: "",
                manifest: nil,
                gitStatus: nil,
                isGitRepo: false
            )
            let toolResult = try makeToolResult(
                metadata: [
                    "filename": "artifact.txt",
                    "mime_type": "text/plain",
                    "path": sourceFile.path,
                    "has_content": false,
                ]
            )

            let processed = SharedArtifact.processToolResult(
                toolResult,
                contextId: contextId,
                contextType: .chat,
                executionMode: .hostFolder(context)
            )

            #expect(processed == nil)
        }
    }

    @Test func processToolResult_rejectsSandboxPathTraversal() throws {
        let agentName = "artifact-security-agent-\(UUID().uuidString)"
        let contextId = "artifact-sandbox-\(UUID().uuidString)"
        defer { cleanupArtifacts(contextId: contextId) }

        let toolResult = try makeToolResult(
            metadata: [
                "filename": "artifact.txt",
                "mime_type": "text/plain",
                "path": "/workspace/agents/\(agentName)/../../../outside.txt",
                "has_content": false,
            ]
        )

        let processed = SharedArtifact.processToolResult(
            toolResult,
            contextId: contextId,
            contextType: .chat,
            executionMode: .sandbox,
            sandboxAgentName: agentName
        )

        #expect(processed == nil)
    }

    private func withTemporaryWorkspace(_ body: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("osaurus-artifact-security-\(UUID().uuidString)", isDirectory: true)

        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        defer {
            try? fm.removeItem(at: root)
        }

        try body(root)
    }

    private func cleanupArtifacts(contextId: String) {
        try? FileManager.default.removeItem(at: OsaurusPaths.contextArtifactsDir(contextId: contextId))
    }

    private func makeToolResult(
        metadata: [String: Any],
        contentLines: [String] = []
    ) throws -> String {
        let metadataData = try JSONSerialization.data(withJSONObject: metadata)
        let metadataLine = String(data: metadataData, encoding: .utf8) ?? "{}"
        let contentBlock = contentLines.isEmpty ? "" : "\n" + contentLines.joined(separator: "\n")
        return SharedArtifact.startMarker + metadataLine + contentBlock + SharedArtifact.endMarker
    }
}
