//
//  VoiceCaptureHotkey.swift
//  osaurus
//
//  Testable policy for transcription-mode hotkeys and voice-capture starts.
//

import Carbon.HIToolbox
import Foundation

public enum VoiceCaptureActivationSource: String, Codable, Equatable, Sendable {
    case button
    case explicitHotkey
    case background
}

public enum VoiceCaptureHotkeyBlocker: String, Codable, Equatable, Sendable {
    case transcriptionDisabled
    case missingHotkey
    case reservedKey
    case missingModifier
    case invalidDisplayName
    case accessibilityPermission
    case microphonePermission
    case speechModel
    case backgroundActivation

    public var message: String {
        switch self {
        case .transcriptionDisabled:
            return L("Transcription Mode is disabled")
        case .missingHotkey:
            return L("Choose a hotkey or keep transcription disabled")
        case .reservedKey:
            return L("Escape is reserved for canceling transcription")
        case .missingModifier:
            return L("Letter, number, and punctuation keys need a modifier")
        case .invalidDisplayName:
            return L("The hotkey label could not be read")
        case .accessibilityPermission:
            return L("Accessibility permission is required to type into other apps")
        case .microphonePermission:
            return L("Microphone permission is required to capture speech")
        case .speechModel:
            return L("Select a downloaded speech model before recording")
        case .backgroundActivation:
            return L("Voice capture requires an explicit button press or hotkey")
        }
    }
}

public struct VoiceCaptureRuntimeRequirements: Equatable, Sendable {
    public var accessibilityPermissionGranted: Bool
    public var microphonePermissionGranted: Bool
    public var speechModelAvailable: Bool

    public init(
        accessibilityPermissionGranted: Bool,
        microphonePermissionGranted: Bool,
        speechModelAvailable: Bool
    ) {
        self.accessibilityPermissionGranted = accessibilityPermissionGranted
        self.microphonePermissionGranted = microphonePermissionGranted
        self.speechModelAvailable = speechModelAvailable
    }
}

public struct VoiceCaptureHotkeyReadiness: Equatable, Sendable {
    public var hotkey: Hotkey?
    public var registrationBlockers: [VoiceCaptureHotkeyBlocker]
    public var captureBlockers: [VoiceCaptureHotkeyBlocker]

    public var canRegister: Bool {
        hotkey != nil && registrationBlockers.isEmpty
    }

    public var canStartCapture: Bool {
        canRegister && captureBlockers.isEmpty
    }

    public var firstBlockerMessage: String? {
        (registrationBlockers + captureBlockers).first?.message
    }
}

public enum VoiceCaptureStartDecision: Equatable, Sendable {
    case allowed
    case denied([VoiceCaptureHotkeyBlocker])

    public var blockers: [VoiceCaptureHotkeyBlocker] {
        switch self {
        case .allowed:
            return []
        case .denied(let blockers):
            return blockers
        }
    }

    public var message: String? {
        blockers.first?.message
    }
}

public enum VoiceCaptureHotkeyPolicy {
    public static let defaultHotkey = Hotkey(
        keyCode: UInt32(kVK_F8),
        carbonModifiers: 0,
        displayString: "F8"
    )

    public static func readiness(
        configuration: TranscriptionConfiguration,
        requirements: VoiceCaptureRuntimeRequirements
    ) -> VoiceCaptureHotkeyReadiness {
        var registrationBlockers: [VoiceCaptureHotkeyBlocker] = []
        var captureBlockers: [VoiceCaptureHotkeyBlocker] = []

        if !configuration.transcriptionModeEnabled {
            registrationBlockers.append(.transcriptionDisabled)
        }

        switch validate(configuration.hotkey) {
        case .valid:
            break
        case .missing:
            registrationBlockers.append(.missingHotkey)
        case .reservedKey:
            registrationBlockers.append(.reservedKey)
        case .missingModifier:
            registrationBlockers.append(.missingModifier)
        case .invalidDisplayName:
            registrationBlockers.append(.invalidDisplayName)
        }

        if !requirements.accessibilityPermissionGranted {
            captureBlockers.append(.accessibilityPermission)
        }
        if !requirements.microphonePermissionGranted {
            captureBlockers.append(.microphonePermission)
        }
        if !requirements.speechModelAvailable {
            captureBlockers.append(.speechModel)
        }

        return VoiceCaptureHotkeyReadiness(
            hotkey: configuration.hotkey,
            registrationBlockers: registrationBlockers,
            captureBlockers: captureBlockers
        )
    }

    public static func startDecision(
        source: VoiceCaptureActivationSource,
        readiness: VoiceCaptureHotkeyReadiness
    ) -> VoiceCaptureStartDecision {
        var blockers = readiness.registrationBlockers + readiness.captureBlockers
        if source == .button {
            blockers.removeAll { blocker in
                blocker == .transcriptionDisabled || blocker == .missingHotkey
            }
        }
        if source == .background {
            blockers.append(.backgroundActivation)
        }
        return blockers.isEmpty ? .allowed : .denied(blockers)
    }

    public static func validate(_ hotkey: Hotkey?) -> HotkeyValidation {
        guard let hotkey else { return .missing }
        if hotkey.keyCode == UInt32(kVK_Escape) { return .reservedKey }
        if hotkey.displayString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .invalidDisplayName
        }
        if hotkey.carbonModifiers == 0 && !isFunctionKey(hotkey.keyCode) {
            return .missingModifier
        }
        return .valid(hotkey)
    }

    private static func isFunctionKey(_ keyCode: UInt32) -> Bool {
        switch Int(keyCode) {
        case kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
            kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12:
            return true
        default:
            return false
        }
    }
}

public enum HotkeyValidation: Equatable, Sendable {
    case valid(Hotkey)
    case missing
    case reservedKey
    case missingModifier
    case invalidDisplayName
}
