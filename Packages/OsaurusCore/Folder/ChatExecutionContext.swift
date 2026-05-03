//
//  ChatExecutionContext.swift
//  osaurus
//
//  TaskLocal context populated by the chat engine before dispatching every
//  tool call so per-session state (the agent todo, file-operation undo
//  log, method telemetry, etc.) can be addressed by the active session.
//

import Foundation

/// A file attachment that is available to tool/plugin execution for the
/// current chat turn context. The original bytes live on disk, not in chat
/// history JSON.
public struct ChatInputFile: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let filename: String
    public let mimeType: String
    public let fileSize: Int
    public let hostPath: String

    public init(id: String, filename: String, mimeType: String, fileSize: Int, hostPath: String) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.fileSize = fileSize
        self.hostPath = hostPath
    }

    var toolPayload: [String: Any] {
        [
            "id": id,
            "filename": filename,
            "mime_type": mimeType,
            "file_size": fileSize,
            "host_path": hostPath,
        ]
    }
}

/// TaskLocal storage carrying the active chat session / agent / batch ids
/// down through tool execution. The chat engine seeds these in
/// `ChatSession.send` (and equivalent headless paths) so any tool reading
/// them picks up the right scope without an explicit parameter.
public enum ChatExecutionContext {
    /// The current chat session id whose tool calls are running. Tools that
    /// need per-conversation state (todo store, file-op undo log, method
    /// telemetry) key off this.
    @TaskLocal public static var currentSessionId: String?

    /// The current batch ID for grouped operations (nil for non-batch operations).
    @TaskLocal public static var currentBatchId: UUID?

    /// The agent ID whose context is active for the current execution.
    @TaskLocal public static var currentAgentId: UUID?

    /// Assistant turn dispatching the current tool call. Used by `speak`
    /// to bind TTS playback to the right message bubble
    @TaskLocal public static var currentAssistantTurnId: UUID?

    /// Specific tool invocation id. Used by `speak` so the inline card
    /// can swap its check for a spinner while its audio plays
    @TaskLocal public static var currentToolCallId: String?

    /// Preserved high-fidelity file attachments visible to the current tool call.
    @TaskLocal public static var currentInputFiles: [ChatInputFile] = []
}
