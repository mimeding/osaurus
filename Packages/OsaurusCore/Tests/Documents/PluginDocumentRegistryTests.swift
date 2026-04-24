//
//  PluginDocumentRegistryTests.swift
//  osaurusTests
//
//  Covers the plugin → host bridge for document format registration.
//  The end-to-end path (plugin C dylib → host-provided callback →
//  `PluginDocumentRegistry.registerParser` → `DocumentFormatRegistry` →
//  back through the plugin's `invoke`) is exercised here at the Swift
//  level with a fake `PluginDocumentInvoker`, so the registry logic
//  and the shim adapter both get pinned without a compiled test
//  plugin. The missing piece — `PluginManager` wiring its plugins'
//  `invoke` pointers into this API — lands with a follow-up PR.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("PluginDocumentRegistry", .serialized)
struct PluginDocumentRegistryTests {

    init() {
        // Ensure every test starts with a clean ownership map even when
        // an earlier test failed mid-run.
        PluginDocumentRegistry.unregisterAll(pluginId: "com.example.a")
        PluginDocumentRegistry.unregisterAll(pluginId: "com.example.b")
    }

    // MARK: - Registration happy path

    @Test func registerParser_routesThroughSharedRegistry() async throws {
        let registry = DocumentFormatRegistry()
        let invoker = FakeInvoker(
            onInvoke: { _, _, _ in
                #"{"ok": true, "text_fallback": "parsed body", "filename": "a.wacky"}"#
            }
        )

        let response = PluginDocumentRegistry.registerParser(
            requestJSON: #"""
                {"plugin_id": "com.example.a", "format_id": "wacky", "extensions": [".wacky"]}
                """#,
            invoker: invoker,
            registry: registry
        )
        #expect(response.contains(#""ok":true"#))

        let url = URL(fileURLWithPath: "/tmp/foo.wacky")
        guard let adapter = registry.adapter(for: url) else {
            Issue.record("expected registered adapter")
            return
        }
        #expect(adapter.formatId == "wacky")
    }

    @Test func registeredAdapter_parseInvokesPluginAndReturnsDocument() async throws {
        let registry = DocumentFormatRegistry()
        let invokedType = LockedBox<String>(nil)
        let invokedId = LockedBox<String>(nil)
        let invoker = FakeInvoker { type, id, _ in
            invokedType.set(type)
            invokedId.set(id)
            return #"{"ok": true, "text_fallback": "plugin-parsed text", "filename": "demo.wacky"}"#
        }

        _ = PluginDocumentRegistry.registerParser(
            requestJSON: #"""
                {"plugin_id": "com.example.a", "format_id": "wacky", "extensions": ["wacky"]}
                """#,
            invoker: invoker,
            registry: registry
        )

        let url = try Self.writeFile(content: "raw", ext: "wacky")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let adapter = registry.adapter(for: url) else {
            Issue.record("no adapter"); return
        }

        let document = try await adapter.parse(url: url, sizeLimit: 0)
        #expect(document.textFallback == "plugin-parsed text")
        #expect(document.filename == "demo.wacky")
        #expect(invokedType.get() == "parser")
        #expect(invokedId.get() == "wacky")
    }

    @Test func registeredAdapter_pluginErrorSurfacesAsReadFailed() async throws {
        let registry = DocumentFormatRegistry()
        let invoker = FakeInvoker { _, _, _ in
            #"{"ok": false, "error": "parser refused"}"#
        }
        _ = PluginDocumentRegistry.registerParser(
            requestJSON: #"""
                {"plugin_id": "com.example.a", "format_id": "wacky", "extensions": ["wacky"]}
                """#,
            invoker: invoker,
            registry: registry
        )

        let url = try Self.writeFile(content: "x", ext: "wacky")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let adapter = registry.adapter(for: url) else {
            Issue.record("no adapter"); return
        }
        await #expect(throws: DocumentAdapterError.self) {
            _ = try await adapter.parse(url: url, sizeLimit: 0)
        }
    }

    // MARK: - Emitter

    @Test func registerEmitter_routesByCanEmit() async throws {
        let registry = DocumentFormatRegistry()
        let invoker = FakeInvoker { _, _, _ in #"{"ok": true}"# }
        _ = PluginDocumentRegistry.registerEmitter(
            requestJSON: #"""
                {"plugin_id": "com.example.a", "format_id": "wacky"}
                """#,
            invoker: invoker,
            registry: registry
        )

        let doc = StructuredDocument(
            formatId: "wacky",
            filename: "a.wacky",
            fileSize: 0,
            representation: AnyStructuredRepresentation(
                formatId: "wacky",
                underlying: PlainTextRepresentation(text: "hi")
            ),
            textFallback: "hi"
        )
        guard let emitter = registry.emitter(for: doc) else {
            Issue.record("no emitter"); return
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("pd-\(UUID().uuidString).wacky")
        try await emitter.emit(doc, to: dest)
    }

    // MARK: - Ownership

    @Test func anotherPluginCannotOverwriteRegistration() {
        let registry = DocumentFormatRegistry()
        let invoker = FakeInvoker { _, _, _ in #"{"ok": true}"# }

        let first = PluginDocumentRegistry.registerParser(
            requestJSON: #"""
                {"plugin_id": "com.example.a", "format_id": "wacky", "extensions": ["wacky"]}
                """#,
            invoker: invoker,
            registry: registry
        )
        let second = PluginDocumentRegistry.registerParser(
            requestJSON: #"""
                {"plugin_id": "com.example.b", "format_id": "wacky", "extensions": ["wacky"]}
                """#,
            invoker: invoker,
            registry: registry
        )
        #expect(first.contains(#""ok":true"#))
        #expect(second.contains(#""ok":false"#))
        #expect(second.contains("already registered"))
    }

    @Test func unregisterByOtherPluginIsRejected() {
        let registry = DocumentFormatRegistry()
        let invoker = FakeInvoker { _, _, _ in #"{"ok": true}"# }
        _ = PluginDocumentRegistry.registerParser(
            requestJSON: #"""
                {"plugin_id": "com.example.a", "format_id": "wacky", "extensions": ["wacky"]}
                """#,
            invoker: invoker,
            registry: registry
        )
        let response = PluginDocumentRegistry.unregisterFormat(
            requestJSON: #"""
                {"plugin_id": "com.example.b", "format_id": "wacky"}
                """#,
            registry: registry
        )
        #expect(response.contains(#""ok":false"#))
    }

    @Test func unregisterAll_dropsAdaptersOwnedByPlugin() {
        let registry = DocumentFormatRegistry()
        let invoker = FakeInvoker { _, _, _ in #"{"ok": true}"# }
        _ = PluginDocumentRegistry.registerParser(
            requestJSON: #"""
                {"plugin_id": "com.example.a", "format_id": "wacky", "extensions": ["wacky"]}
                """#,
            invoker: invoker,
            registry: registry
        )
        _ = PluginDocumentRegistry.registerParser(
            requestJSON: #"""
                {"plugin_id": "com.example.a", "format_id": "nutty", "extensions": ["nutty"]}
                """#,
            invoker: invoker,
            registry: registry
        )
        PluginDocumentRegistry.unregisterAll(pluginId: "com.example.a", registry: registry)
        #expect(registry.adapter(for: URL(fileURLWithPath: "/tmp/a.wacky")) == nil)
        #expect(registry.adapter(for: URL(fileURLWithPath: "/tmp/a.nutty")) == nil)
    }

    // MARK: - Malformed input

    @Test func malformedRegistrationReturnsErrorEnvelope() {
        let registry = DocumentFormatRegistry()
        let invoker = FakeInvoker { _, _, _ in #"{"ok": true}"# }
        let response = PluginDocumentRegistry.registerParser(
            requestJSON: "not json",
            invoker: invoker,
            registry: registry
        )
        #expect(response.contains(#""ok":false"#))
    }

    // MARK: - Fixtures

    private struct FakeInvoker: PluginDocumentInvoker {
        let onInvoke: @Sendable (String, String, String) -> String
        func invoke(type: String, id: String, payload: String) async -> String {
            onInvoke(type, id, payload)
        }
    }

    private static func writeFile(content: String, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pd-\(UUID().uuidString).\(ext)")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// Tiny lock-box so test closures can capture and later read a value
/// across the async/Sendable boundary without per-test actor plumbing.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    init(_ value: Value?) { self.value = value }
    func get() -> Value? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func set(_ newValue: Value?) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }
}
