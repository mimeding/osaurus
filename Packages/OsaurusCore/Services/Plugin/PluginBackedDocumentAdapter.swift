//
//  PluginBackedDocumentAdapter.swift
//  osaurus
//
//  Swift shims that implement `DocumentFormatAdapter` / `DocumentFormatEmitter`
//  by forwarding to an external plugin via the existing
//  `invoke(type:id:payload:)` callback. Created when a plugin calls the
//  register_parser / register_emitter host callbacks from its `init` entry
//  point.
//
//  The plugin side speaks JSON; these shims translate between the
//  typed `DocumentFormatRegistry` contract and the plugin's wire format.
//  Only the `textFallback` representation is surfaced today — richer
//  types (`Workbook`, `PDFDocumentRepresentation`) are left for future
//  PRs that extend the plugin response schema.
//

import Foundation

/// Opaque invoker the plugin host wires up so shims don't need to know
/// about `ExternalPlugin` internals. The host side (PluginHostAPI) is
/// the only producer; tests use a closure-backed fake.
public protocol PluginDocumentInvoker: Sendable {
    func invoke(type: String, id: String, payload: String) async -> String
}

struct PluginBackedAdapter: DocumentFormatAdapter {
    let formatId: String
    let extensions: Set<String>
    let invoker: any PluginDocumentInvoker

    func canHandle(url: URL, uti: String?) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    func parse(url: URL, sizeLimit: Int64) async throws -> StructuredDocument {
        let fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        if sizeLimit > 0, fileSize > sizeLimit {
            throw DocumentAdapterError.sizeLimitExceeded(actual: fileSize, limit: sizeLimit)
        }

        let payload: [String: Any] = [
            "path": url.path,
            "size_limit": Int(sizeLimit),
        ]
        let payloadJSON = Self.serialize(payload)
        let responseText = await invoker.invoke(type: "parser", id: formatId, payload: payloadJSON)

        guard let response = Self.decodeResponse(responseText) else {
            throw DocumentAdapterError.readFailed(
                underlying: "plugin returned malformed parser response for format '\(formatId)'"
            )
        }
        if response.ok == false {
            throw DocumentAdapterError.readFailed(
                underlying: response.error ?? "plugin parser failed for format '\(formatId)'"
            )
        }

        let text = response.textFallback ?? ""
        guard !text.isEmpty else {
            throw DocumentAdapterError.emptyContent
        }

        return StructuredDocument(
            formatId: formatId,
            filename: response.filename ?? url.lastPathComponent,
            fileSize: response.fileSize ?? fileSize,
            representation: AnyStructuredRepresentation(
                formatId: formatId,
                underlying: PlainTextRepresentation(text: text)
            ),
            textFallback: text
        )
    }

    // MARK: - Response parsing

    struct ParserResponse {
        var ok: Bool
        var error: String?
        var textFallback: String?
        var filename: String?
        var fileSize: Int64?
    }

    static func decodeResponse(_ raw: String) -> ParserResponse? {
        guard let data = raw.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return ParserResponse(
            ok: (obj["ok"] as? Bool) ?? false,
            error: obj["error"] as? String,
            textFallback: obj["text_fallback"] as? String,
            filename: obj["filename"] as? String,
            fileSize: (obj["file_size"] as? NSNumber)?.int64Value
        )
    }

    static func serialize(_ dict: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: dict))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

struct PluginBackedEmitter: DocumentFormatEmitter {
    let formatId: String
    let invoker: any PluginDocumentInvoker

    func canEmit(_ document: StructuredDocument) -> Bool {
        document.formatId == formatId
    }

    func emit(_ document: StructuredDocument, to url: URL) async throws {
        let payload: [String: Any] = [
            "destination": url.path,
            "filename": document.filename,
            "text": document.textFallback,
        ]
        let payloadJSON = PluginBackedAdapter.serialize(payload)
        let responseText = await invoker.invoke(type: "emitter", id: formatId, payload: payloadJSON)

        guard let data = responseText.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw DocumentAdapterError.writeFailed(
                underlying: "plugin returned malformed emitter response for format '\(formatId)'"
            )
        }
        if (obj["ok"] as? Bool) != true {
            let message = (obj["error"] as? String) ?? "plugin emitter failed"
            throw DocumentAdapterError.writeFailed(underlying: message)
        }
    }
}
