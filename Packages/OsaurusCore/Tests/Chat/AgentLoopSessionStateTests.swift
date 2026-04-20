import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct AgentLoopSessionStateTests {

    @Test
    func chatSessionDataPersistsLoopState() throws {
        let state = AgentLoopSessionState(
            todoMarkdown: "- [x] Read code\n- [ ] Add test",
            completionSummary: "Updated chat loop state and verified with a targeted persistence test.",
            clarifyQuestion: nil
        )
        let session = ChatSessionData(
            id: UUID(),
            title: "Loop state",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            selectedModel: "foundation",
            turns: [
                ChatTurnData(role: .user, content: "Please do the thing")
            ],
            agentId: Agent.defaultId,
            agentLoopState: state
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ChatSessionData.self, from: data)

        #expect(decoded.agentLoopState == state)
        #expect(decoded.agentLoopState?.todoMarkdown == "- [x] Read code\n- [ ] Add test")
        #expect(decoded.agentLoopState?.completionSummary == state.completionSummary)
    }

    @Test
    func derivesLoopStateFromLegacyTranscript() {
        let summary = "Changed the session metadata model and verified with Swift package tests."
        let turns = [
            ChatTurnData(role: .user, content: "Implement this"),
            ChatTurnData(
                role: .assistant,
                content: "",
                toolCalls: [
                    toolCall("todo", #"{"markdown":"- [x] Inspect\n- [ ] Patch"}"#),
                    toolCall("complete", "{\"summary\":\"\(summary)\"}"),
                ]
            ),
        ]

        let state = AgentLoopSessionState.derived(from: turns)

        #expect(state?.todoMarkdown == "- [x] Inspect\n- [ ] Patch")
        #expect(state?.completionSummary == summary)
        #expect(state?.clarifyQuestion == nil)
    }

    @Test
    func userFollowupClearsDerivedTerminalStateButKeepsTodo() {
        let turns = [
            ChatTurnData(role: .user, content: "Implement this"),
            ChatTurnData(
                role: .assistant,
                content: "",
                toolCalls: [
                    toolCall("todo", #"{"markdown":"- [ ] Continue"}"#),
                    toolCall("clarify", #"{"question":"Use SQLite or Postgres?"}"#),
                ]
            ),
            ChatTurnData(role: .user, content: "Use SQLite"),
        ]

        let state = AgentLoopSessionState.derived(from: turns)

        #expect(state?.todoMarkdown == "- [ ] Continue")
        #expect(state?.completionSummary == nil)
        #expect(state?.clarifyQuestion == nil)
    }

    @Test
    func chatSessionLoadRestoresDurableLoopState() async {
        let id = UUID()
        await AgentTodoStore.shared.clear(for: id.uuidString)

        let sessionData = ChatSessionData(
            id: id,
            title: "Restored",
            turns: [ChatTurnData(role: .user, content: "Start")],
            agentLoopState: AgentLoopSessionState(
                todoMarkdown: "- [ ] Restore todo",
                completionSummary: nil,
                clarifyQuestion: "Which target should run first?"
            )
        )
        let session = ChatSession()

        session.load(from: sessionData)
        try? await Task.sleep(nanoseconds: 20_000_000)

        #expect(session.currentTodo?.markdown == "- [ ] Restore todo")
        #expect(session.currentTodo?.totalCount == 1)
        #expect(session.lastClarifyQuestion == "Which target should run first?")
        let stored = await AgentTodoStore.shared.todo(for: id.uuidString)
        #expect(stored?.markdown == "- [ ] Restore todo")
    }

    private func toolCall(_ name: String, _ arguments: String) -> ToolCall {
        ToolCall(
            id: "call_\(name)",
            type: "function",
            function: ToolCallFunction(name: name, arguments: arguments)
        )
    }
}
