import Foundation
import Testing

@testable import OsaurusCore

@Suite("Shared artifact trust boundary hardening", .serialized)
struct SharedArtifactSecurityTests {

    @Test func processToolResult_sanitizesDestinationFilename() throws {
        try withIsolatedOsaurusRoot { _ in
            let contextId = "artifact-dest-\(UUID().uuidString)"
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
    }

    @Test func processToolResult_rejectsHostFolderPathTraversal() throws {
        try withIsolatedOsaurusRoot { root in
            let fm = FileManager.default
            let workspaceRoot = root.appendingPathComponent("workspace", isDirectory: true)
            let outsideFile = root.appendingPathComponent("outside.txt")
            try fm.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
            try Data("outside".utf8).write(to: outsideFile)

            let context = WorkFolderContext(
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
                contextId: "artifact-host-\(UUID().uuidString)",
                contextType: .work,
                executionMode: .hostFolder(context)
            )

            #expect(processed == nil)
        }
    }

    @Test func processToolResult_rejectsSandboxPathTraversal() throws {
        try withIsolatedOsaurusRoot { _ in
            let fm = FileManager.default
            let agentName = "artifact-security-agent"
            let agentDir = OsaurusPaths.containerAgentDir(agentName)
            try fm.createDirectory(at: agentDir, withIntermediateDirectories: true)
            let outsideFile = OsaurusPaths.container().appendingPathComponent("outside.txt")
            try fm.createDirectory(at: outsideFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("outside".utf8).write(to: outsideFile)

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
                contextId: "artifact-sandbox-\(UUID().uuidString)",
                contextType: .work,
                executionMode: .sandbox,
                sandboxAgentName: agentName
            )

            #expect(processed == nil)
        }
    }

    private func withIsolatedOsaurusRoot(_ body: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let originalRoot = OsaurusPaths.overrideRoot
        let wasOpen = WorkDatabase.shared.isOpen
        let isolatedRoot = fm.temporaryDirectory
            .appendingPathComponent("osaurus-artifact-security-\(UUID().uuidString)", isDirectory: true)

        WorkDatabase.shared.close()
        try fm.createDirectory(at: isolatedRoot, withIntermediateDirectories: true)
        OsaurusPaths.overrideRoot = isolatedRoot
        try WorkDatabase.shared.open()

        defer {
            WorkDatabase.shared.close()
            OsaurusPaths.overrideRoot = originalRoot
            if wasOpen {
                try? WorkDatabase.shared.open()
            }
            try? fm.removeItem(at: isolatedRoot)
        }

        try body(isolatedRoot)
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
