//
//  LocalTemplateCompatibilityTests.swift
//  osaurusTests
//
//  Regression coverage for local MLX chat-template compatibility shims.
//

import Foundation
import Testing

@testable import OsaurusCore

struct LocalTemplateCompatibilityTests {

    @Test func nonGemmaKeepsSystemRoleUntouched() {
        let messages = [
            ChatMessage(role: "system", content: "Your name is Gerald."),
            ChatMessage(role: "user", content: "Who are you?"),
        ]

        let adapted = ModelRuntime.applyLocalTemplateCompatibility(
            messages,
            modelName: "qwen3-32b-mlx"
        )

        #expect(adapted.map(\.role) == ["system", "user"])
        #expect(adapted[0].content == "Your name is Gerald.")
        #expect(adapted[1].content == "Who are you?")
    }

    @Test func gemmaMovesSystemInstructionsIntoFirstUserTurn() {
        let messages = [
            ChatMessage(role: "system", content: "Your name is Gerald."),
            ChatMessage(role: "user", content: "Who are you?"),
        ]

        let adapted = ModelRuntime.applyLocalTemplateCompatibility(
            messages,
            modelName: "OsaurusAI/gemma-4-E4B-it-8bit"
        )

        #expect(adapted.map(\.role) == ["user"])
        #expect(adapted[0].content?.contains("System instructions:") == true)
        #expect(adapted[0].content?.contains("Your name is Gerald.") == true)
        #expect(adapted[0].content?.contains("User message:") == true)
        #expect(adapted[0].content?.contains("Who are you?") == true)
    }

    @Test func gemmaPreservesUserImagePartsWhileAddingInstructions() {
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        let messages = [
            ChatMessage(role: "system", content: "Describe images tersely."),
            ChatMessage(role: "user", text: "What is in this image?", imageData: [imageData]),
        ]

        let adapted = ModelRuntime.applyLocalTemplateCompatibility(
            messages,
            modelName: "gemma-4-26b-a4b-it"
        )

        #expect(adapted.count == 1)
        #expect(adapted[0].role == "user")
        #expect(adapted[0].content?.contains("Describe images tersely.") == true)
        #expect(adapted[0].content?.contains("What is in this image?") == true)

        let parts = adapted[0].contentParts ?? []
        #expect(parts.count == 2)
        if case .text(let text) = parts[0] {
            #expect(text.contains("System instructions:"))
            #expect(text.contains("What is in this image?"))
        } else {
            Issue.record("first content part should be text")
        }

        if case .imageUrl(let url, _) = parts[1] {
            #expect(url.hasPrefix("data:image/png;base64,"))
        } else {
            Issue.record("second content part should preserve the image")
        }
    }
}
