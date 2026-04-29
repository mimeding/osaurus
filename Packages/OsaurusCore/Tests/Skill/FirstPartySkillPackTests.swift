import Foundation
import Testing

@testable import OsaurusCore

struct FirstPartySkillPackTests {

    @Test
    func firstPartySkillPackIsOnDemandAndParseable() throws {
        let root = repoRoot()
        let packDir = root.appendingPathComponent("skills/first-party", isDirectory: true)
        let manifest = try loadMarketplace(from: root)
        let manifestPaths = manifest.plugins.flatMap(\.skills)
        let expectedPaths = try skillDirectories(in: packDir).map {
            "./skills/first-party/\($0.lastPathComponent)"
        }

        #expect(manifestPaths.isEmpty == false)
        #expect(Set(manifestPaths) == Set(expectedPaths))

        for dir in try skillDirectories(in: packDir) {
            let skillURL = dir.appendingPathComponent("SKILL.md")
            let markdown = try String(contentsOf: skillURL, encoding: .utf8)
            let skill = try Skill.parseAnyFormat(from: markdown)

            #expect(skill.enabled)
            #expect(skill.isDiscoverable)
            #expect(skill.isDefaultSelectedForAgents == false)
            #expect(skill.activationMode == .onDemand)
            #expect(skill.keywords.count >= 5)
            #expect(markdown.localizedCaseInsensitiveContains("Work Mode") == false)
        }
    }

    @Test
    func firstPartyReferencesStayWithinPromptLimit() throws {
        let root = repoRoot()
        let packDir = root.appendingPathComponent("skills/first-party", isDirectory: true)
        let referenceURLs = try FileManager.default.subpathsOfDirectory(atPath: packDir.path)
            .filter { $0.contains("/references/") }

        #expect(referenceURLs.isEmpty == false)

        for relativePath in referenceURLs {
            let url = packDir.appendingPathComponent(relativePath)
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = attrs[.size] as? NSNumber
            #expect((size?.intValue ?? 0) < 100_000)
        }
    }

    private struct Marketplace: Decodable {
        let plugins: [Plugin]

        struct Plugin: Decodable {
            let skills: [String]
        }
    }

    private func loadMarketplace(from root: URL) throws -> Marketplace {
        let url = root.appendingPathComponent(".claude-plugin/marketplace.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Marketplace.self, from: data)
    }

    private func skillDirectories(in packDir: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: packDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
