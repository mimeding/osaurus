//
//  VoiceInputOutputPolicyTests.swift
//  osaurusTests
//

import Carbon.HIToolbox
import Foundation
import Testing

@testable import OsaurusCore

@Suite("Voice input and speech output policy")
struct VoiceInputOutputPolicyTests {
    @Test("default transcription configuration uses a function-key hotkey without enabling capture")
    func defaultTranscriptionConfigurationUsesFunctionKeyHotkey() {
        let config = TranscriptionConfiguration.default

        #expect(config.transcriptionModeEnabled == false)
        #expect(config.hotkey == VoiceCaptureHotkeyPolicy.defaultHotkey)
        #expect(VoiceCaptureHotkeyPolicy.validate(config.hotkey) == .valid(VoiceCaptureHotkeyPolicy.defaultHotkey))
    }

    @Test("hotkey policy allows function keys and requires modifiers for text keys")
    func hotkeyPolicyValidatesKeyShape() {
        let plainA = Hotkey(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: 0, displayString: "A")
        let commandA = Hotkey(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(cmdKey), displayString: "⌘A")
        let escape = Hotkey(keyCode: UInt32(kVK_Escape), carbonModifiers: 0, displayString: "Esc")

        #expect(
            VoiceCaptureHotkeyPolicy.validate(VoiceCaptureHotkeyPolicy.defaultHotkey)
                == .valid(VoiceCaptureHotkeyPolicy.defaultHotkey)
        )
        #expect(VoiceCaptureHotkeyPolicy.validate(plainA) == .missingModifier)
        #expect(VoiceCaptureHotkeyPolicy.validate(commandA) == .valid(commandA))
        #expect(VoiceCaptureHotkeyPolicy.validate(escape) == .reservedKey)
        #expect(VoiceCaptureHotkeyPolicy.validate(nil) == .missing)
    }

    @Test("hotkey readiness separates registration from runtime capture blockers")
    func hotkeyReadinessSeparatesRegistrationAndRuntimeBlockers() {
        let config = TranscriptionConfiguration(
            transcriptionModeEnabled: true,
            hotkey: VoiceCaptureHotkeyPolicy.defaultHotkey
        )
        let readiness = VoiceCaptureHotkeyPolicy.readiness(
            configuration: config,
            requirements: VoiceCaptureRuntimeRequirements(
                accessibilityPermissionGranted: false,
                microphonePermissionGranted: true,
                speechModelAvailable: false
            )
        )

        #expect(readiness.canRegister)
        #expect(readiness.canStartCapture == false)
        #expect(readiness.registrationBlockers.isEmpty)
        #expect(readiness.captureBlockers == [.accessibilityPermission, .speechModel])
    }

    @Test("background capture is denied even when requirements are met")
    func backgroundCaptureIsDenied() {
        let config = TranscriptionConfiguration(
            transcriptionModeEnabled: true,
            hotkey: VoiceCaptureHotkeyPolicy.defaultHotkey
        )
        let readiness = VoiceCaptureHotkeyPolicy.readiness(
            configuration: config,
            requirements: VoiceCaptureRuntimeRequirements(
                accessibilityPermissionGranted: true,
                microphonePermissionGranted: true,
                speechModelAvailable: true
            )
        )

        #expect(VoiceCaptureHotkeyPolicy.startDecision(source: .explicitHotkey, readiness: readiness) == .allowed)
        #expect(
            VoiceCaptureHotkeyPolicy.startDecision(source: .background, readiness: readiness)
                == .denied([.backgroundActivation])
        )
    }

    @Test("speech-output policy selects the next complete assistant turn")
    func speechOutputSelectsNextAssistantTurn() {
        let user = SpeechOutputConversationTurn(id: UUID(), role: .user, text: "Question")
        let blankAssistant = SpeechOutputConversationTurn(id: UUID(), role: .assistant, text: "   ")
        let firstAssistant = SpeechOutputConversationTurn(id: UUID(), role: .assistant, text: "First answer")
        let secondAssistant = SpeechOutputConversationTurn(id: UUID(), role: .assistant, text: "Second answer")
        let turns = [user, blankAssistant, firstAssistant, secondAssistant]

        #expect(
            SpeechOutputConversationPolicy.nextAssistantTurn(
                in: turns,
                after: nil,
                currentPlayingTurnId: nil
            ) == .speak(firstAssistant)
        )
        #expect(
            SpeechOutputConversationPolicy.nextAssistantTurn(
                in: turns,
                after: firstAssistant.id,
                currentPlayingTurnId: nil
            ) == .speak(secondAssistant)
        )
    }

    @Test("speech-output policy handles stop and busy playback semantics")
    func speechOutputStopAndBusySemantics() {
        let turn = SpeechOutputConversationTurn(id: UUID(), role: .assistant, text: "Read this")
        let other = UUID()

        #expect(
            SpeechOutputConversationPolicy.explicitTurnDecision(
                turn,
                currentPlayingTurnId: turn.id
            ) == .stop(turn.id)
        )
        #expect(
            SpeechOutputConversationPolicy.explicitTurnDecision(
                turn,
                currentPlayingTurnId: other
            ) == .skip(.alreadyPlaying(other))
        )
    }
}
