//
//  RepositoryGlobalProxySettingsTests.swift
//  OsaurusRepository
//

import CFNetwork
import Foundation
import XCTest

@testable import OsaurusRepository

final class RepositoryGlobalProxySettingsTests: XCTestCase {
    func testSharedSessionAppliesProxyFromServerConfiguration() throws {
        try withTemporaryToolsRoot { root in
            try writeServerConfiguration(
                root: root,
                proxyURL: "https://proxy.example.com:8443"
            )

            let session = RepositoryGlobalProxySettings.sharedSession()
            let dictionary = session.configuration.connectionProxyDictionary

            XCTAssertEqual(dictionary?[proxyKey(kCFNetworkProxiesHTTPSEnable)] as? Int, 1)
            XCTAssertEqual(dictionary?[proxyKey(kCFNetworkProxiesHTTPSProxy)] as? String, "proxy.example.com")
            XCTAssertEqual(dictionary?[proxyKey(kCFNetworkProxiesHTTPSPort)] as? Int, 8443)
        }
    }

    func testSharedSessionRebuildsWhenProxyChanges() throws {
        try withTemporaryToolsRoot { root in
            try writeServerConfiguration(
                root: root,
                proxyURL: "http://proxy-one.example.com:8080"
            )

            let first = RepositoryGlobalProxySettings.sharedSession()
            XCTAssertEqual(
                first.configuration.connectionProxyDictionary?[proxyKey(kCFNetworkProxiesHTTPProxy)] as? String,
                "proxy-one.example.com"
            )

            try writeServerConfiguration(
                root: root,
                proxyURL: "socks5://proxy-two.example.com:1080"
            )

            let second = RepositoryGlobalProxySettings.sharedSession()
            XCTAssertFalse(first === second)
            XCTAssertEqual(
                second.configuration.connectionProxyDictionary?[proxyKey(kCFNetworkProxiesSOCKSProxy)] as? String,
                "proxy-two.example.com"
            )
            XCTAssertNil(second.configuration.connectionProxyDictionary?[proxyKey(kCFNetworkProxiesHTTPProxy)])
        }
    }

    func testInvalidProxyFallsBackToDirectNetworking() throws {
        try withTemporaryToolsRoot { root in
            try writeServerConfiguration(root: root, proxyURL: "http://localhost:8080")

            let session = RepositoryGlobalProxySettings.sharedSession()

            XCTAssertNil(session.configuration.connectionProxyDictionary)
        }
    }

    func testLegacyServerConfigurationPathIsReadWhenNewPathIsAbsent() throws {
        try withTemporaryToolsRoot { root in
            let data = Data(#"{"globalProxyURL":"socks5://proxy.example.com:1080"}"#.utf8)
            try data.write(
                to: root.appendingPathComponent("ServerConfiguration.json"),
                options: .atomic
            )

            let session = RepositoryGlobalProxySettings.sharedSession()
            let dictionary = session.configuration.connectionProxyDictionary

            XCTAssertEqual(dictionary?[proxyKey(kCFNetworkProxiesSOCKSEnable)] as? Int, 1)
            XCTAssertEqual(dictionary?[proxyKey(kCFNetworkProxiesSOCKSProxy)] as? String, "proxy.example.com")
            XCTAssertEqual(dictionary?[proxyKey(kCFNetworkProxiesSOCKSPort)] as? Int, 1080)
        }
    }

    private func withTemporaryToolsRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-repository-proxy-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previousRoot = ToolsPaths.overrideRoot
        ToolsPaths.overrideRoot = root
        defer {
            ToolsPaths.overrideRoot = previousRoot
            _ = RepositoryGlobalProxySettings.sharedSession()
            try? FileManager.default.removeItem(at: root)
        }

        try body(root)
    }

    private func writeServerConfiguration(root: URL, proxyURL: String?) throws {
        let configDir = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        var object: [String: Any] = [:]
        if let proxyURL {
            object["globalProxyURL"] = proxyURL
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: configDir.appendingPathComponent("server.json"), options: .atomic)
    }

    private func proxyKey(_ value: CFString) -> AnyHashable {
        AnyHashable(value as String)
    }
}
