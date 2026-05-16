//
//  TTSConfiguration.swift
//  osaurus
//
//  Configuration model for FluidAudio PocketTTS text-to-speech.
//

import Foundation

/// Stable app-owned IDs for PocketTTS language packs so persisted
/// preferences do not depend on FluidAudio's Swift symbol names.
public enum TTSLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case english
    case french24L = "french_24l"
    case german
    case german24L = "german_24l"
    case italian
    case italian24L = "italian_24l"
    case portuguese
    case portuguese24L = "portuguese_24l"
    case spanish
    case spanish24L = "spanish_24l"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .english: return "English"
        case .french24L: return "French (24-layer)"
        case .german: return "German"
        case .german24L: return "German (24-layer)"
        case .italian: return "Italian"
        case .italian24L: return "Italian (24-layer)"
        case .portuguese: return "Portuguese"
        case .portuguese24L: return "Portuguese (24-layer)"
        case .spanish: return "Spanish"
        case .spanish24L: return "Spanish (24-layer)"
        }
    }
}

/// Configuration settings for PocketTTS text-to-speech.
public struct TTSConfiguration: Codable, Equatable, Sendable {
    /// Master enable toggle. When false, speaker buttons are hidden from message cells.
    public var enabled: Bool

    /// PocketTTS language pack used for synthesis.
    public var language: TTSLanguage

    /// PocketTTS voice identifier.
    public var voice: String

    /// Generation temperature (0.1 – 1.2). Higher = more variation.
    public var temperature: Double

    public static let defaultVoice = "alba"

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TTSConfiguration.default
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        if let rawLanguage = try container.decodeIfPresent(String.self, forKey: .language),
            let language = TTSLanguage(rawValue: rawLanguage)
        {
            self.language = language
        } else {
            self.language = defaults.language
        }
        self.voice = try container.decodeIfPresent(String.self, forKey: .voice) ?? defaults.voice
        self.temperature =
            try container.decodeIfPresent(Double.self, forKey: .temperature) ?? defaults.temperature
    }

    public init(
        enabled: Bool = true,
        language: TTSLanguage = .english,
        voice: String = TTSConfiguration.defaultVoice,
        temperature: Double = 0.7
    ) {
        self.enabled = enabled
        self.language = language
        self.voice = voice
        self.temperature = temperature
    }

    public static var `default`: TTSConfiguration { TTSConfiguration() }
}

/// Handles persistence of `TTSConfiguration` with in-memory caching.
@MainActor
public enum TTSConfigurationStore {
    private static var cachedConfig: TTSConfiguration?

    public static func load() -> TTSConfiguration {
        if let cached = cachedConfig { return cached }
        let config = loadFromDisk()
        cachedConfig = config
        return config
    }

    public static func save(_ configuration: TTSConfiguration) {
        cachedConfig = configuration
        saveToDisk(configuration)
        NotificationCenter.default.post(name: .ttsConfigurationChanged, object: nil)
    }

    private static func loadFromDisk() -> TTSConfiguration {
        let url = OsaurusPaths.ttsConfigFile()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return TTSConfiguration.default
        }
        do {
            return try JSONDecoder().decode(TTSConfiguration.self, from: Data(contentsOf: url))
        } catch {
            print("[Osaurus] Failed to load TTSConfiguration: \(error)")
            return TTSConfiguration.default
        }
    }

    private static func saveToDisk(_ configuration: TTSConfiguration) {
        let url = OsaurusPaths.ttsConfigFile()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: url, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save TTSConfiguration: \(error)")
        }
    }
}

extension Notification.Name {
    public static let ttsConfigurationChanged = Notification.Name("osaurus.ttsConfigurationChanged")
}
