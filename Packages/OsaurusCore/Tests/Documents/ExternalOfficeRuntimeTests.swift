//
//  ExternalOfficeRuntimeTests.swift
//  osaurusTests
//
//  Contract tests for the lazy external office detector. The tests use
//  temporary fake `soffice` and `which` scripts so the host machine's
//  installed applications and PATH never influence the result.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("ExternalOfficeRuntime")
struct ExternalOfficeRuntimeTests {
    @Test func libreOfficeApplicationPathFound() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let soffice = root.appendingPathComponent("LibreOffice.app/Contents/MacOS/soffice")
        try Self.writeFakeSoffice(at: soffice, output: "LibreOffice 7.6.4.1 60(Build:2)")

        let runtime = ExternalOfficeRuntime(
            applicationCandidates: [
                .init(kind: .libreOffice, executableURL: soffice)
            ],
            whichExecutableURL: try Self.writeWhichNotFound(in: root)
        )

        let snapshot = await runtime.snapshot()
        #expect(snapshot.available)
        #expect(snapshot.kind == .libreOffice)
        #expect(snapshot.version == "7.6.4.1")
        #expect(snapshot.executablePath == soffice.standardizedFileURL)
        #expect(snapshot.supportedConversions.contains(.docxToPDF))
        #expect(snapshot.supportedConversions.contains(.pptxToPNG))
        #expect(snapshot.supportedConversions.contains(.pptxRepair))
    }

    @Test func openOfficeApplicationPathFoundAfterLibreOfficeMiss() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let missingLibreOffice = root.appendingPathComponent("LibreOffice.app/Contents/MacOS/soffice")
        let openOffice = root.appendingPathComponent("OpenOffice.app/Contents/MacOS/soffice")
        try Self.writeFakeSoffice(at: openOffice, output: "Apache OpenOffice 4.1.15 AOO4115m1(Build:9813)")

        let runtime = ExternalOfficeRuntime(
            applicationCandidates: [
                .init(kind: .libreOffice, executableURL: missingLibreOffice),
                .init(kind: .openOffice, executableURL: openOffice),
            ],
            whichExecutableURL: try Self.writeWhichNotFound(in: root)
        )

        let snapshot = await runtime.snapshot()
        #expect(snapshot.available)
        #expect(snapshot.kind == .openOffice)
        #expect(snapshot.version == "4.1.15")
        #expect(snapshot.executablePath == openOffice.standardizedFileURL)
    }

    @Test func pathExecutableResolvedThroughWhich() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let soffice = root.appendingPathComponent("bin/soffice")
        try Self.writeFakeSoffice(at: soffice, output: "LibreOffice 24.2.0.3 420(Build:3)")
        let which = try Self.writeWhich(in: root, resolvingTo: soffice)

        let runtime = ExternalOfficeRuntime(
            applicationCandidates: [],
            whichExecutableURL: which
        )

        let snapshot = await runtime.snapshot()
        #expect(snapshot.available)
        #expect(snapshot.kind == .libreOffice)
        #expect(snapshot.version == "24.2.0.3")
        #expect(snapshot.executablePath == soffice.standardizedFileURL)
    }

    @Test func nothingFoundReturnsUnavailableSnapshot() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = ExternalOfficeRuntime(
            applicationCandidates: [],
            whichExecutableURL: try Self.writeWhichNotFound(in: root)
        )

        let snapshot = await runtime.snapshot()
        #expect(snapshot == .unavailable)
    }

    @Test func unparseableVersionStillMarksRuntimeAvailable() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let soffice = root.appendingPathComponent("bin/soffice")
        try Self.writeFakeSoffice(at: soffice, output: "office runtime ready")
        let which = try Self.writeWhich(in: root, resolvingTo: soffice)

        let runtime = ExternalOfficeRuntime(
            applicationCandidates: [],
            whichExecutableURL: which
        )

        let snapshot = await runtime.snapshot()
        #expect(snapshot.available)
        #expect(snapshot.kind == nil)
        #expect(snapshot.version == nil)
        #expect(snapshot.executablePath == soffice.standardizedFileURL)
        #expect(snapshot.supportedConversions.contains(.pptxToPDF))
    }

    @Test func representativeVersionParsing() {
        let libreOffice = ExternalOfficeRuntime.parseVersionOutput(
            "LibreOffice 7.5.9.2 50(Build:2)"
        )
        #expect(libreOffice.kind == .libreOffice)
        #expect(libreOffice.version == "7.5.9.2")

        let libreOfficeDev = ExternalOfficeRuntime.parseVersionOutput(
            "LibreOfficeDev 25.2.0.0.alpha0+ Build:abcd"
        )
        #expect(libreOfficeDev.kind == .libreOffice)
        #expect(libreOfficeDev.version == "25.2.0.0.alpha0")

        let openOffice = ExternalOfficeRuntime.parseVersionOutput(
            "Apache OpenOffice 4.1.15 AOO4115m1(Build:9813)"
        )
        #expect(openOffice.kind == .openOffice)
        #expect(openOffice.version == "4.1.15")
    }

    @Test func detectionCachesFirstSnapshot() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let soffice = root.appendingPathComponent("LibreOffice.app/Contents/MacOS/soffice")
        try Self.writeFakeSoffice(at: soffice, output: "LibreOffice 7.6.4.1 60(Build:2)")

        let runtime = ExternalOfficeRuntime(
            applicationCandidates: [
                .init(kind: .libreOffice, executableURL: soffice)
            ],
            whichExecutableURL: try Self.writeWhichNotFound(in: root)
        )

        let first = await runtime.snapshot()
        try Self.writeFakeSoffice(at: soffice, output: "LibreOffice 7.6.5.2 60(Build:2)")
        let second = await runtime.snapshot()

        #expect(first.version == "7.6.4.1")
        #expect(second.version == "7.6.4.1")
    }

    @Test func explicitInvalidationReprobes() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let soffice = root.appendingPathComponent("LibreOffice.app/Contents/MacOS/soffice")
        try Self.writeFakeSoffice(at: soffice, output: "LibreOffice 7.6.4.1 60(Build:2)")

        let runtime = ExternalOfficeRuntime(
            applicationCandidates: [
                .init(kind: .libreOffice, executableURL: soffice)
            ],
            whichExecutableURL: try Self.writeWhichNotFound(in: root)
        )

        let first = await runtime.snapshot()
        try Self.writeFakeSoffice(at: soffice, output: "LibreOffice 7.6.5.2 60(Build:2)")
        runtime.invalidate()
        let second = await runtime.snapshot()

        #expect(first.version == "7.6.4.1")
        #expect(second.version == "7.6.5.2")
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalOfficeRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func writeFakeSoffice(
        at url: URL,
        output: String,
        exitStatus: Int32 = 0
    ) throws {
        let script =
            [
                "#!/bin/sh",
                #"if [ "$1" != "--version" ]; then"#,
                "  exit 64",
                "fi",
                "cat <<'OSAURUS_SOFFICE_VERSION'",
                output,
                "OSAURUS_SOFFICE_VERSION",
                "exit \(exitStatus)",
            ].joined(separator: "\n") + "\n"
        try Self.writeExecutableScript(at: url, content: script)
    }

    private static func writeWhich(in root: URL, resolvingTo soffice: URL) throws -> URL {
        let which = root.appendingPathComponent("usr/bin/which")
        let script =
            [
                "#!/bin/sh",
                #"if [ "$1" = "soffice" ]; then"#,
                "  cat <<'OSAURUS_WHICH_RESULT'",
                soffice.path,
                "OSAURUS_WHICH_RESULT",
                "  exit 0",
                "fi",
                "exit 1",
            ].joined(separator: "\n") + "\n"
        try Self.writeExecutableScript(at: which, content: script)
        return which
    }

    private static func writeWhichNotFound(in root: URL) throws -> URL {
        let which = root.appendingPathComponent("usr/bin/which")
        let script =
            [
                "#!/bin/sh",
                "exit 1",
            ].joined(separator: "\n") + "\n"
        try Self.writeExecutableScript(at: which, content: script)
        return which
    }

    private static func writeExecutableScript(at url: URL, content: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: url.path
        )
    }
}
