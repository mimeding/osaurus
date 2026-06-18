//
//  OsaurusCLITests.swift
//  osaurus
//
//  Unit tests for the Osaurus CLI core functionality.
//

import XCTest
@testable import OsaurusCLICore

final class OsaurusCLITests: XCTestCase {
    func testConfiguration() {
        // Just a smoke test to ensure things link
        let root = Configuration.toolsRootDirectory()
        XCTAssertFalse(root.path.isEmpty)
    }

    func testStatusFormatsAuthSummaryWhenHealthIncludesLoadedKeys() throws {
        let json = """
            {
              "auth": {
                "local_auth_policy": "always_allow",
                "loopback_trusted": true,
                "network_exposure": true,
                "access_keys_loaded": true,
                "access_key_count": 4,
                "active_access_key_count": 2,
                "revoked_access_key_count": 1,
                "expired_access_key_count": 1
              }
            }
            """
        let payload = try JSONDecoder().decode(StatusHealthPayload.self, from: Data(json.utf8))

        XCTAssertEqual(
            StatusCommand.formatRunningStatus(port: 1337, health: payload),
            """
            running (port 1337)
            auth: localhost keyless; network exposed; keys active 2, revoked 1, expired 1
            """
        )
    }

    func testStatusFormatsUnloadedKeyMetadata() throws {
        let json = """
            {
              "auth": {
                "local_auth_policy": "local_only",
                "loopback_trusted": false,
                "network_exposure": true,
                "access_keys_loaded": false,
                "access_key_count": null,
                "active_access_key_count": null,
                "revoked_access_key_count": null,
                "expired_access_key_count": null
              }
            }
            """
        let payload = try JSONDecoder().decode(StatusHealthPayload.self, from: Data(json.utf8))

        XCTAssertEqual(
            StatusCommand.formatRunningStatus(port: 8080, health: payload),
            """
            running (port 8080)
            auth: localhost requires key; network exposed; key metadata not loaded
            """
        )
    }
}
