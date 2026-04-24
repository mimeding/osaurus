//
//  PluginDocumentRegistry.swift
//  osaurus
//
//  Bridge between the plugin lifecycle and `DocumentFormatRegistry`.
//  Plugins reach it through a host callback (proposed as the v2
//  `register_parser` / `register_emitter` entry points in the osaurus
//  plugin ABI header) but Swift callers — including future
//  `PluginManager` wiring that threads a plugin's invoke pointer back
//  into an adapter — use this module directly.
//
//  Responsibilities:
//    - Translate the plugin's JSON registration request into a
//      `DocumentFormatAdapter` / `DocumentFormatEmitter` shim.
//    - Track which plugin owns which `formatId` so a plugin unload can
//      tear down only its own adapters, not an in-tree one that
//      happens to share a format name.
//    - Return a stable JSON response shape so the plugin side can log /
//      report failures without needing Swift types.
//

import Foundation

public enum PluginDocumentRegistry {
    private static let lock = NSLock()
    // Maps format_id -> plugin_id. Keeps ownership out of the shared
    // `DocumentFormatRegistry` (which has no concept of owners) so one
    // plugin cannot unregister another's format.
    nonisolated(unsafe) private static var ownership: [String: String] = [:]

    /// Register a plugin-backed parser. `requestJSON` matches the
    /// `register_parser` contract from `osaurus_plugin.h`. On success
    /// the shim adapter immediately appears in `DocumentFormatRegistry.shared`.
    @discardableResult
    public static func registerParser(
        requestJSON: String,
        invoker: any PluginDocumentInvoker,
        registry: DocumentFormatRegistry = .shared
    ) -> String {
        guard let req = parse(requestJSON) else {
            return response(ok: false, error: "request JSON must include `plugin_id`, `format_id`, and `extensions`")
        }
        if !claimOwnership(pluginId: req.pluginId, formatId: req.formatId) {
            return response(
                ok: false,
                error: "format '\(req.formatId)' already registered by another plugin"
            )
        }
        registry.register(
            adapter: PluginBackedAdapter(
                formatId: req.formatId,
                extensions: req.extensions,
                invoker: invoker
            )
        )
        return response(ok: true)
    }

    /// Register a plugin-backed emitter. Same JSON shape as `registerParser`;
    /// the `extensions` field is accepted but ignored because emitter
    /// routing is `canEmit(document)`-based.
    @discardableResult
    public static func registerEmitter(
        requestJSON: String,
        invoker: any PluginDocumentInvoker,
        registry: DocumentFormatRegistry = .shared
    ) -> String {
        guard let req = parse(requestJSON) else {
            return response(ok: false, error: "request JSON must include `plugin_id` and `format_id`")
        }
        if !claimOwnership(pluginId: req.pluginId, formatId: req.formatId) {
            return response(
                ok: false,
                error: "format '\(req.formatId)' already registered by another plugin"
            )
        }
        registry.register(
            emitter: PluginBackedEmitter(formatId: req.formatId, invoker: invoker)
        )
        return response(ok: true)
    }

    /// Unregister every adapter/emitter/streamer associated with a
    /// plugin-owned `formatId`. Declines to unregister in-tree formats
    /// so a buggy plugin can't strip the built-in XLSX / PDF adapters.
    @discardableResult
    public static func unregisterFormat(
        requestJSON: String,
        registry: DocumentFormatRegistry = .shared
    ) -> String {
        guard let req = parse(requestJSON) else {
            return response(ok: false, error: "request JSON must include `plugin_id` and `format_id`")
        }
        guard releaseOwnership(pluginId: req.pluginId, formatId: req.formatId) else {
            return response(ok: false, error: "format '\(req.formatId)' not owned by this plugin")
        }
        registry.unregisterAll(formatId: req.formatId)
        return response(ok: true)
    }

    /// Tear down every format a plugin registered. Called by
    /// `PluginManager` during plugin unload so the shared registry
    /// doesn't carry stale pointers.
    public static func unregisterAll(pluginId: String, registry: DocumentFormatRegistry = .shared) {
        lock.lock()
        let owned = ownership.filter { $0.value == pluginId }.map(\.key)
        for format in owned { ownership.removeValue(forKey: format) }
        lock.unlock()
        for format in owned {
            registry.unregisterAll(formatId: format)
        }
    }

    // MARK: - Internals

    struct Request {
        let pluginId: String
        let formatId: String
        let extensions: Set<String>
    }

    static func parse(_ json: String) -> Request? {
        guard let data = json.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let pluginId = obj["plugin_id"] as? String, !pluginId.isEmpty,
            let formatId = obj["format_id"] as? String, !formatId.isEmpty
        else { return nil }
        let rawExtensions = (obj["extensions"] as? [String]) ?? []
        let cleaned = rawExtensions.map {
            $0.hasPrefix(".") ? String($0.dropFirst()) : $0
        }
        return Request(
            pluginId: pluginId,
            formatId: formatId,
            extensions: Set(cleaned.map { $0.lowercased() })
        )
    }

    private static func claimOwnership(pluginId: String, formatId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let existing = ownership[formatId], existing != pluginId { return false }
        ownership[formatId] = pluginId
        return true
    }

    private static func releaseOwnership(pluginId: String, formatId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard ownership[formatId] == pluginId else { return false }
        ownership.removeValue(forKey: formatId)
        return true
    }

    private static func response(ok: Bool, error: String? = nil) -> String {
        var payload: [String: Any] = ["ok": ok]
        if let error { payload["error"] = error }
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
