//
//  DevProxyURLGuardTests.swift
//  osaurusTests
//
//  Unit tests for `HTTPHandler.isLoopbackProxyURL`. The dev-proxy.json feature
//  reads a developer-supplied URL and proxies plugin web traffic to it. This
//  guard constrains the allowed targets to loopback so an attacker (or a
//  misconfigured editor / tool that drops a config file) can't turn the
//  dev-proxy channel into an SSRF primitive against RFC1918 hosts or the
//  public internet.
//

import Foundation
import Testing

@testable import OsaurusCore

struct DevProxyURLGuardTests {

    @Test func acceptsLocalhost() {
        #expect(HTTPHandler.isLoopbackProxyURL("http://localhost:5173"))
        #expect(HTTPHandler.isLoopbackProxyURL("https://localhost"))
    }

    @Test func acceptsLoopbackV4() {
        #expect(HTTPHandler.isLoopbackProxyURL("http://127.0.0.1:3000"))
        #expect(HTTPHandler.isLoopbackProxyURL("http://127.0.0.1/"))
        #expect(HTTPHandler.isLoopbackProxyURL("http://127.255.255.255/x"))
    }

    @Test func acceptsLoopbackV6() {
        #expect(HTTPHandler.isLoopbackProxyURL("http://[::1]:1234/"))
    }

    @Test func rejectsRFC1918() {
        // 10.x, 172.16-31.x, 192.168.x — common LAN ranges. dev-proxy is a
        // local-loopback feature; it has no business proxying to LAN hosts.
        #expect(!HTTPHandler.isLoopbackProxyURL("http://10.0.0.1:3000"))
        #expect(!HTTPHandler.isLoopbackProxyURL("http://172.16.0.1:3000"))
        #expect(!HTTPHandler.isLoopbackProxyURL("http://192.168.1.1:3000"))
    }

    @Test func rejectsPublicHost() {
        #expect(!HTTPHandler.isLoopbackProxyURL("http://example.com"))
        #expect(!HTTPHandler.isLoopbackProxyURL("https://1.1.1.1/dns-query"))
        #expect(!HTTPHandler.isLoopbackProxyURL("http://8.8.8.8/"))
    }

    @Test func rejectsLinkLocalAndCloudMetadata() {
        // 169.254.169.254 is the AWS / GCP metadata service. A real exploit
        // of an SSRF-style dev-proxy would target exactly this address.
        #expect(!HTTPHandler.isLoopbackProxyURL("http://169.254.169.254/latest/meta-data/"))
        #expect(!HTTPHandler.isLoopbackProxyURL("http://169.254.0.1/"))
    }

    @Test func rejectsNonHTTPSchemes() {
        // file:// would let an attacker exfiltrate local file contents
        // through the dev-proxy code path. Reject anything that isn't
        // http or https.
        #expect(!HTTPHandler.isLoopbackProxyURL("file:///etc/passwd"))
        #expect(!HTTPHandler.isLoopbackProxyURL("data:text/plain,abc"))
        #expect(!HTTPHandler.isLoopbackProxyURL("ftp://localhost/x"))
    }

    @Test func rejectsMalformedURL() {
        #expect(!HTTPHandler.isLoopbackProxyURL(""))
        #expect(!HTTPHandler.isLoopbackProxyURL("not a url"))
        #expect(!HTTPHandler.isLoopbackProxyURL("http://"))
    }
}
