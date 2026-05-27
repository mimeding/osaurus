//
//  ArchiveSafetyTests.swift
//  osaurusTests
//
//  Tests for the post-extraction ZIP-slip / symlink-escape validator in
//  `OsaurusRepository.ArchiveSafety`. The validator runs after the extractor
//  (currently /usr/bin/unzip) has written files to disk and is the last line
//  of defense before the caller reads anything out of the extracted tree.
//

import Foundation
import OsaurusRepository
import Testing

@testable import OsaurusCore

private struct TempDirectory {
    let url: URL

    init(name: String = "osaurus-archive-tests-\(UUID().uuidString)") throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}

struct ArchiveSafetyTests {

    @Test func acceptsCleanTree() throws {
        let root = try TempDirectory()
        defer { root.cleanup() }

        let nestedDir = root.url.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: nestedDir.appendingPathComponent("lib.swift").path,
            contents: Data("hi".utf8)
        )
        FileManager.default.createFile(
            atPath: root.url.appendingPathComponent("README.md").path,
            contents: Data("readme".utf8)
        )

        try ArchiveSafety.validate(extractedRoot: root.url)
    }

    @Test func rejectsSymlinkEscape() throws {
        let root = try TempDirectory()
        defer { root.cleanup() }
        let outside = try TempDirectory(name: "osaurus-archive-outside-\(UUID().uuidString)")
        defer { outside.cleanup() }

        // Simulate a malicious zip entry that, when extracted, became a
        // symbolic link inside the destination pointing OUT of it. macOS
        // Info-ZIP's own protections don't catch this case.
        let link = root.url.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.url)

        var threw = false
        do {
            try ArchiveSafety.validate(extractedRoot: root.url)
        } catch ArchiveSafetyError.escapingSymlink {
            threw = true
        } catch {
            threw = true
        }
        #expect(threw, "symlink to outside directory must be rejected")
    }

    @Test func acceptsInternalSymlink() throws {
        let root = try TempDirectory()
        defer { root.cleanup() }

        let target = root.url.appendingPathComponent("real-file")
        FileManager.default.createFile(atPath: target.path, contents: Data())

        let link = root.url.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try ArchiveSafety.validate(extractedRoot: root.url)
    }

    @Test func rejectsExtractionRootMissing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-archive-missing-\(UUID().uuidString)")
        var threw = false
        do {
            try ArchiveSafety.validate(extractedRoot: missing)
        } catch ArchiveSafetyError.extractionRootMissing {
            threw = true
        } catch {
            threw = true
        }
        #expect(threw)
    }
}
