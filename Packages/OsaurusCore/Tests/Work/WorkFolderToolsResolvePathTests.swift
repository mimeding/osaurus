//
//  WorkFolderToolsResolvePathTests.swift
//  osaurusTests
//
//  Containment tests for `WorkFolderToolHelpers.resolvePath`. These exercise
//  both the lexical (`..` rejection) and symlink-aware (`/Volumes/escape`)
//  layers of path containment, plus the macOS-typical case where the work
//  root itself is reached via a symlink and must not fail spuriously.
//

import Foundation
import Testing

@testable import OsaurusCore

private struct TempDirectory {
    let url: URL

    init(name: String = "osaurus-tests-\(UUID().uuidString)") throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}

struct WorkFolderToolsResolvePathTests {

    @Test func acceptsRelativePathInsideRoot() throws {
        let root = try TempDirectory()
        defer { root.cleanup() }

        let resolved = try WorkFolderToolHelpers.resolvePath("src/lib.swift", rootPath: root.url)
        #expect(resolved.path.hasPrefix(root.url.standardized.path))
    }

    @Test func acceptsLeadingSlashAsRelative() throws {
        let root = try TempDirectory()
        defer { root.cleanup() }

        let resolved = try WorkFolderToolHelpers.resolvePath("/src/lib.swift", rootPath: root.url)
        #expect(resolved.path.hasPrefix(root.url.standardized.path))
    }

    @Test func rejectsDotDotEscape() throws {
        let root = try TempDirectory()
        defer { root.cleanup() }

        var threw = false
        do {
            _ = try WorkFolderToolHelpers.resolvePath("../etc/passwd", rootPath: root.url)
        } catch WorkFolderToolError.pathOutsideRoot {
            threw = true
        } catch {
            // Any other error is also OK as long as we reject it.
            threw = true
        }
        #expect(threw)
    }

    @Test func rejectsSymlinkEscape() throws {
        let root = try TempDirectory()
        defer { root.cleanup() }

        let outside = try TempDirectory(name: "osaurus-outside-\(UUID().uuidString)")
        defer { outside.cleanup() }

        // Plant a symlink inside the work root that points outside it. An
        // agent that emits `escape/secret` would lexically pass the
        // `.standardized` prefix check but actually read from `outside/...`.
        let symlinkInsideRoot = root.url.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(
            at: symlinkInsideRoot, withDestinationURL: outside.url)

        var threw = false
        do {
            _ = try WorkFolderToolHelpers.resolvePath("escape/secret", rootPath: root.url)
        } catch WorkFolderToolError.pathOutsideRoot {
            threw = true
        } catch {
            threw = true
        }
        #expect(threw, "symlink that exits the work root must be rejected")
    }

    @Test func acceptsRootReachedViaSymlink() throws {
        // macOS-typical pattern: the work-root URL the caller hands us is
        // itself reached through a symlink (e.g. /var -> /private/var on
        // macOS). Containment must compare apples-to-apples after symlink
        // resolution; otherwise legitimate projects fail.
        let realRoot = try TempDirectory()
        defer { realRoot.cleanup() }

        let symlinkParent = try TempDirectory(name: "osaurus-symlink-\(UUID().uuidString)")
        defer { symlinkParent.cleanup() }

        let symlinkRoot = symlinkParent.url.appendingPathComponent("root")
        try FileManager.default.createSymbolicLink(
            at: symlinkRoot, withDestinationURL: realRoot.url)

        // Create an actual file under the real path to make the test concrete.
        let nestedDir = realRoot.url.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        let nestedFile = nestedDir.appendingPathComponent("lib.swift")
        FileManager.default.createFile(atPath: nestedFile.path, contents: Data())

        let resolved = try WorkFolderToolHelpers.resolvePath("src/lib.swift", rootPath: symlinkRoot)
        // Either the symlinked or symlink-resolved path is acceptable as the
        // returned URL; the important property is that the call succeeded.
        let symPath = symlinkRoot.appendingPathComponent("src/lib.swift").path
        let realPath = nestedFile.path
        #expect(resolved.path == symPath || resolved.path == realPath)
    }
}
