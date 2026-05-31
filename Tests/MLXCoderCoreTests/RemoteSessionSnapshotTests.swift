import Foundation
@testable import MLXCoderCore
import Testing

@Suite
struct RemoteSessionSnapshotTests {
    @Test
    func remoteInitialMessagesRoundTripToolTranscript() {
        let history = remoteHistory()
        let messages = RemoteGenerationClient.initialMessages(
            cwd: "/tmp/project",
            systemPrompt: "System prompt",
            history: history,
            allowedToolNames: ["local.exec"]
        )
        let snapshot = RemoteGenerationClient.snapshotMessages(from: messages)

        #expect(snapshot.systemPrompt == "System prompt")
        #expect(snapshot.history == history)
    }

    @Test
    func remoteClientSnapshotUsesLocalTranscript() async {
        let history = remoteHistory()
        let configuration = AgentRuntimeConfiguration(
            modelID: "remote-model",
            bearerToken: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            maxToolRounds: 4,
            verboseLogging: false,
            toolAuthorizationHandler: nil
        )
        let client = RemoteGenerationClient(
            configuration: configuration,
            provider: AgentRemoteProvider(
                name: "Remote mlx-server",
                baseURL: "http://127.0.0.1:8080/v1",
                modelID: "remote-model",
                chatEndpoint: .responses
            ),
            apiKey: nil
        )

        await client.createSession(
            id: "session-remote",
            cwd: "/tmp/project",
            systemPrompt: "System prompt",
            history: history,
            cacheKey: "cache-remote",
            allowedToolNames: ["local.exec"],
            thinkingSelection: nil,
            preserveThinking: false
        )

        let snapshot = await client.snapshotSession(id: "session-remote")

        #expect(snapshot?.sessionID == "session-remote")
        #expect(snapshot?.systemPrompt == "System prompt")
        #expect(snapshot?.cacheKey == "cache-remote")
        #expect(snapshot?.history == history)
    }

    private func remoteHistory() -> [AgentRuntimeMessage] {
        [
            AgentRuntimeMessage(role: .user, content: "run pwd"),
            AgentRuntimeMessage(
                role: .assistant,
                content: "",
                toolCalls: [
                    AgentRuntimeToolCall(
                        id: "call_1",
                        name: "local.exec",
                        argumentsJSON: #"{"command":"pwd"}"#
                    )
                ]
            ),
            AgentRuntimeMessage(
                role: .tool,
                content: "/tmp/project",
                toolCallID: "call_1",
                toolName: "local.exec"
            ),
            AgentRuntimeMessage(role: .assistant, content: "Done.")
        ]
    }
}
