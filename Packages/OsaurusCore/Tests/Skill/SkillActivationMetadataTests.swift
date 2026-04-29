import Foundation
import Testing

@testable import OsaurusCore

struct SkillActivationMetadataTests {

    @Test
    func parsesAgentSkillsActivationMetadata() throws {
        let markdown = """
            ---
            name: on-demand-helper
            description: Helps only when loaded
            metadata:
              version: "1.2.3"
              category: development
              keywords: "helper, on demand, session"
              osaurus-discoverable: true
              osaurus-default-selected: false
              osaurus-activation: "on-demand"
            ---

            # On Demand Helper
            """

        let skill = try Skill.parseAnyFormat(from: markdown)

        #expect(skill.name == "On Demand Helper")
        #expect(skill.version == "1.2.3")
        #expect(skill.category == "development")
        #expect(skill.keywords.contains("on demand"))
        #expect(skill.isDiscoverable)
        #expect(skill.isDefaultSelectedForAgents == false)
        #expect(skill.activationMode == .onDemand)
    }

    @Test
    func parsesOsaurusActivationMetadata() throws {
        let markdown = """
            ---
            id: "00000001-0000-0000-0000-00000000ABCD"
            name: "Local Helper"
            description: "A local helper"
            version: "1.0.0"
            keywords: "local, helper"
            enabled: true
            discoverable: false
            defaultSelectedForAgents: false
            activation: "on-demand"
            ---

            # Local Helper
            """

        let skill = try Skill.parseAnyFormat(from: markdown)

        #expect(skill.name == "Local Helper")
        #expect(skill.isDiscoverable == false)
        #expect(skill.isDefaultSelectedForAgents == false)
        #expect(skill.activationMode == .onDemand)
    }

    @Test
    func agentSkillsExportIncludesActivationMetadata() {
        let skill = Skill(
            name: "Exported Helper",
            description: "Exported helper",
            keywords: ["exported", "helper"],
            discoverable: true,
            defaultSelectedForAgents: false,
            activation: .onDemand,
            instructions: "# Exported Helper"
        )

        let markdown = skill.toAgentSkillsFormat()

        #expect(markdown.contains("osaurus-discoverable: true"))
        #expect(markdown.contains("osaurus-default-selected: false"))
        #expect(markdown.contains("osaurus-activation: \"on-demand\""))
    }
}
