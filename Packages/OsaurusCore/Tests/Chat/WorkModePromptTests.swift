//
//  WorkModePromptTests.swift
//  osaurusTests
//
//  Pins down the Work-mode prompt guidance the user actually sees, so
//  regressions to the targeted reliability nudges (Stay Oriented,
//  save_notes-not-terminal, host-folder completion, aligned ambiguity
//  wording) surface as test failures rather than mysterious agent drift.
//

import Foundation
import Testing

@testable import OsaurusCore

struct WorkModePromptTests {

    // MARK: - Stay Oriented

    @Test
    func workModeFull_includesStayOrientedSection() {
        let prompt = SystemPromptTemplates.workMode(.full, hasSandbox: true)
        #expect(prompt.contains("## Stay Oriented"))
        #expect(prompt.contains("goal -> what is done -> next action"))
    }

    @Test
    func workModeCompact_includesStayOrientedBullet() {
        let prompt = SystemPromptTemplates.workMode(.compact, hasSandbox: true)
        #expect(prompt.contains("restate goal -> done -> next -> blockers"))
    }

    // MARK: - save_notes vs complete_task

    @Test
    func workModeFull_clarifiesSaveNotesIsNotCompletion() {
        let prompt = SystemPromptTemplates.workMode(.full, hasSandbox: true)
        #expect(prompt.contains(SystemPromptTemplates.saveNotesNotTerminalReminder))
    }

    @Test
    func workModeCompact_clarifiesSaveNotesIsNotCompletion() {
        let prompt = SystemPromptTemplates.workMode(.compact, hasSandbox: true)
        #expect(prompt.contains(SystemPromptTemplates.saveNotesNotTerminalReminder))
    }

    // MARK: - Host-folder completion mandate

    @Test
    func workModeFull_hostFolder_includesFileListMandate() {
        let prompt = SystemPromptTemplates.workMode(.full, hasSandbox: false)
        #expect(prompt.contains(SystemPromptTemplates.hostFolderFileListMandate))
        // share_artifact mandate must NOT appear in the no-sandbox path.
        #expect(prompt.contains("share_artifact") == false)
    }

    @Test
    func workModeCompact_hostFolder_includesFileListMandate() {
        let prompt = SystemPromptTemplates.workMode(.compact, hasSandbox: false)
        #expect(prompt.contains(SystemPromptTemplates.hostFolderFileListMandate))
        #expect(prompt.contains("share_artifact") == false)
    }

    @Test
    func workModeFull_sandbox_keepsShareArtifactMandate() {
        let prompt = SystemPromptTemplates.workMode(.full, hasSandbox: true)
        // Sandbox path keeps its own share_artifact requirement; the host-
        // folder file-list bullet is only for the !hasSandbox path.
        #expect(prompt.contains("MUST call `share_artifact`"))
        #expect(prompt.contains(SystemPromptTemplates.hostFolderFileListMandate) == false)
    }

    // MARK: - Aligned ambiguity threshold

    @Test
    func workModeFull_clarificationWordingMatchesToolDescription() {
        let prompt = SystemPromptTemplates.workMode(.full, hasSandbox: true)
        let toolDescription = RequestClarificationTool().description

        // Both surfaces reference the single canonical guidance constant so
        // the model never sees a three-way mismatch.
        #expect(prompt.contains(SystemPromptTemplates.requestClarificationGuidance))
        #expect(toolDescription.contains(SystemPromptTemplates.requestClarificationGuidance))
    }

    @Test
    func workModeCompact_clarificationWordingMatchesToolDescription() {
        let prompt = SystemPromptTemplates.workMode(.compact, hasSandbox: true)
        let toolDescription = RequestClarificationTool().description

        #expect(prompt.contains(SystemPromptTemplates.requestClarificationGuidance))
        #expect(toolDescription.contains(SystemPromptTemplates.requestClarificationGuidance))
    }
}
