//
//  TTSConfigurationTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct TTSConfigurationTests {
    @Test func decodeLegacyConfigDefaultsToEnglish() throws {
        let json = """
            {
                "enabled": true,
                "voice": "alba",
                "temperature": 0.7
            }
            """

        let decoded = try JSONDecoder().decode(
            TTSConfiguration.self,
            from: Data(json.utf8)
        )

        #expect(decoded.enabled)
        #expect(decoded.voice == "alba")
        #expect(decoded.temperature == 0.7)
        #expect(decoded.language == .english)
    }

    @Test func decodeUnknownLanguageFallsBackToEnglish() throws {
        let json = """
            {
                "enabled": true,
                "language": "klingon",
                "voice": "michael",
                "temperature": 0.6
            }
            """

        let decoded = try JSONDecoder().decode(
            TTSConfiguration.self,
            from: Data(json.utf8)
        )

        #expect(decoded.language == .english)
        #expect(decoded.voice == "michael")
    }

    @Test func roundTripPersistsSelectedLanguageRawValue() throws {
        let config = TTSConfiguration(
            enabled: true,
            language: .french24L,
            voice: "eve",
            temperature: 0.55
        )

        let data = try JSONEncoder().encode(config)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decoded = try JSONDecoder().decode(TTSConfiguration.self, from: data)

        #expect(object["language"] as? String == "french_24l")
        #expect(decoded == config)
    }

    @Test func languageCatalogIncludesPocketTTSLanguagePacks() {
        let languages = TTSLanguage.allCases

        #expect(languages.first == .english)
        #expect(languages.contains(.french24L))
        #expect(languages.contains(.german))
        #expect(languages.contains(.german24L))
        #expect(languages.contains(.italian))
        #expect(languages.contains(.italian24L))
        #expect(languages.contains(.portuguese))
        #expect(languages.contains(.portuguese24L))
        #expect(languages.contains(.spanish))
        #expect(languages.contains(.spanish24L))
        #expect(TTSLanguage.french24L.displayName == "French (24-layer)")
    }

    @Test func pocketTTSCacheDirectoryMatchesFluidAudioLayout() {
        let home = URL(fileURLWithPath: "/tmp/osaurus-home", isDirectory: true)
        let directory = TTSService.pocketTtsModelCacheDirectory(
            language: .french24L,
            homeDirectory: home
        )

        #expect(
            directory.path
                == "/tmp/osaurus-home/.cache/fluidaudio/Models/pocket-tts/v2/french_24l"
        )
    }
}
