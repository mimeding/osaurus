//
//  AgentChannelCustomJSONModels.swift
//  osaurus
//
//  Safety and mapping options for configuration-only custom JSON channels.
//

import Foundation

struct AgentChannelCustomHTTPResponseMapping: Codable, Equatable, Sendable {
    var itemsPath: String?
    var idPath: String?
    var namePath: String?
    var roomIdPath: String?
    var threadIdPath: String?
    var contentPath: String?
    var authorIdPath: String?
    var authorNamePath: String?
    var timestampPath: String?
    var cursorPath: String?

    init(
        itemsPath: String? = nil,
        idPath: String? = nil,
        namePath: String? = nil,
        roomIdPath: String? = nil,
        threadIdPath: String? = nil,
        contentPath: String? = nil,
        authorIdPath: String? = nil,
        authorNamePath: String? = nil,
        timestampPath: String? = nil,
        cursorPath: String? = nil
    ) {
        self.itemsPath = Self.trimmed(itemsPath)
        self.idPath = Self.trimmed(idPath)
        self.namePath = Self.trimmed(namePath)
        self.roomIdPath = Self.trimmed(roomIdPath)
        self.threadIdPath = Self.trimmed(threadIdPath)
        self.contentPath = Self.trimmed(contentPath)
        self.authorIdPath = Self.trimmed(authorIdPath)
        self.authorNamePath = Self.trimmed(authorNamePath)
        self.timestampPath = Self.trimmed(timestampPath)
        self.cursorPath = Self.trimmed(cursorPath)
    }

    var normalized: AgentChannelCustomHTTPResponseMapping {
        AgentChannelCustomHTTPResponseMapping(
            itemsPath: itemsPath,
            idPath: idPath,
            namePath: namePath,
            roomIdPath: roomIdPath,
            threadIdPath: threadIdPath,
            contentPath: contentPath,
            authorIdPath: authorIdPath,
            authorNamePath: authorNamePath,
            timestampPath: timestampPath,
            cursorPath: cursorPath
        )
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
struct AgentChannelCustomHTTPIdempotency: Codable, Equatable, Sendable {
    var header: String?
    var keyTemplate: String?
    var responseIdPath: String?

    init(
        header: String? = "Idempotency-Key",
        keyTemplate: String? = nil,
        responseIdPath: String? = nil
    ) {
        self.header = Self.trimmed(header)
        self.keyTemplate = Self.trimmed(keyTemplate)
        self.responseIdPath = Self.trimmed(responseIdPath)
    }

    var normalized: AgentChannelCustomHTTPIdempotency {
        AgentChannelCustomHTTPIdempotency(
            header: header,
            keyTemplate: keyTemplate,
            responseIdPath: responseIdPath
        )
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
