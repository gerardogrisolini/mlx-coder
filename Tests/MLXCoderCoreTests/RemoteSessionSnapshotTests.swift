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

    @Test
    func remoteToolWireCatalogRewritesResponsesHistoryNames() throws {
        let catalog = RemoteToolWireCatalog(
            descriptors: [
                DirectToolDescriptor(
                    name: "local.exec",
                    description: "Run a shell command.",
                    inputSchema: #"{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}"#
                ),
                DirectToolDescriptor(
                    name: "git.diff",
                    description: "Run git diff.",
                    inputSchema: #"{"type":"object","properties":{}}"#
                )
            ]
        )
        let messages = RemoteGenerationClient.initialMessages(
            cwd: "/tmp/project",
            systemPrompt: "System prompt",
            history: remoteHistory(),
            allowedToolNames: ["local.exec"]
        )

        let wireMessages = catalog.wireMessages(from: messages)
        let payload = RemoteGenerationClient.responsesInputPayload(from: wireMessages)
        let inputObjects = payload.input.compactMap { $0 as? [String: Any] }
        let functionCall = try #require(
            inputObjects.first { $0["type"] as? String == "function_call" }
        )
        let toolPayloadNames = catalog.responsesToolPayloads.compactMap {
            $0["name"] as? String
        }
        let localToolCall = catalog.localToolCall(
            from: DirectAgentToolCall(
                id: "call_2",
                name: "tool_git_diff",
                argumentsObject: [:],
                argumentsJSON: "{}"
            )
        )

        #expect(functionCall["name"] as? String == "tool_local_exec")
        #expect(toolPayloadNames.contains("tool_local_exec"))
        #expect(!toolPayloadNames.contains("local.exec"))
        #expect(localToolCall.name == "git.diff")
    }

#if os(macOS)
    @Test
    func chatGPTSubscriptionContinuationKeepsFullInputForBaseRequest() throws {
        let messages = chatGPTContinuationMessages()
        let fullPayload = RemoteGenerationClient.responsesInputPayload(from: messages)
        let payload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
            from: messages,
            continuation: ChatGPTSubscriptionContinuationState(
                responseID: "resp_previous",
                messageCount: 3,
                instructions: "System prompt"
            )
        )
        let body = ChatGPTSubscriptionRequestBuilder.requestBody(
            input: JSONValue.acpValue(from: payload.input),
            model: "gpt-5.5",
            instructions: payload.instructions ?? "",
            reasoningEffort: nil,
            textVerbosity: "low",
            sessionID: "session-chatgpt"
        )

        #expect(payload.input.count == fullPayload.input.count)
        #expect(payload.cachedWebSocketInput?.count == 1)
        #expect(payload.previousResponseID == "resp_previous")
        #expect(body["previous_response_id"] == nil)
        #expect((body["input"] as? [Any])?.count == fullPayload.input.count)
    }

    @Test
    func chatGPTSubscriptionWebSocketUsesContinuationOnlyWhenCached() throws {
        let messages = chatGPTContinuationMessages()
        let payload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
            from: messages,
            continuation: ChatGPTSubscriptionContinuationState(
                responseID: "resp_previous",
                messageCount: 3,
                instructions: "System prompt"
            )
        )
        let body = ChatGPTSubscriptionRequestBuilder.requestBody(
            input: JSONValue.acpValue(from: payload.input),
            model: "gpt-5.5",
            instructions: payload.instructions ?? "",
            reasoningEffort: nil,
            textVerbosity: "low",
            sessionID: "session-chatgpt"
        )
        let freshPayload = ChatGPTSubscriptionResponsesClient.webSocketRequestPayload(
            body: body,
            cachedInput: payload.cachedWebSocketInput.map { JSONValue.acpValue(from: $0) },
            previousResponseID: payload.previousResponseID,
            useCachedContinuation: false
        )
        let cachedPayload = ChatGPTSubscriptionResponsesClient.webSocketRequestPayload(
            body: body,
            cachedInput: payload.cachedWebSocketInput.map { JSONValue.acpValue(from: $0) },
            previousResponseID: payload.previousResponseID,
            useCachedContinuation: true
        )

        #expect(freshPayload["previous_response_id"] == nil)
        #expect((freshPayload["input"] as? [Any])?.count == payload.input.count)
        #expect(cachedPayload["previous_response_id"] as? String == "resp_previous")
        #expect((cachedPayload["input"] as? [Any])?.count == payload.cachedWebSocketInput?.count)
        #expect(cachedPayload["type"] as? String == "response.create")
    }

    @Test
    func chatGPTSubscriptionContinuationUsesToolOutputDelta() throws {
        let messages = chatGPTContinuationMessagesWithToolOutput()
        let fullPayload = RemoteGenerationClient.responsesInputPayload(from: messages)
        let payload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
            from: messages,
            continuation: ChatGPTSubscriptionContinuationState(
                responseID: "resp_tool_call",
                messageCount: 3,
                instructions: "System prompt"
            )
        )
        let cachedInput = try #require(payload.cachedWebSocketInput)
        let cachedObject = try #require(cachedInput.first as? [String: Any])

        #expect(payload.input.count == fullPayload.input.count)
        #expect(cachedInput.count == 1)
        #expect(cachedObject["type"] as? String == "function_call_output")
        #expect(cachedObject["call_id"] as? String == "call_memory")
        #expect(payload.previousResponseID == "resp_tool_call")
    }

    @Test
    func chatGPTSubscriptionContextEstimateIncludesInstructionsAndTools() throws {
        let payload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
            from: chatGPTContinuationMessages(),
            continuation: nil
        )
        let toolPayloads = RemoteToolWireCatalog(
            descriptors: [
                DirectToolDescriptor(
                    name: "local.exec",
                    description: "Run a shell command.",
                    inputSchema: #"{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}"#
                )
            ]
        ).responsesToolPayloads

        let inputOnlyEstimate = try #require(
            ChatGPTSubscriptionRequestBuilder.estimatedContextTokenCount(
                instructions: nil,
                input: payload.input,
                toolPayloads: []
            )
        )
        let withInstructionsEstimate = try #require(
            ChatGPTSubscriptionRequestBuilder.estimatedContextTokenCount(
                instructions: payload.instructions,
                input: payload.input,
                toolPayloads: []
            )
        )
        let withToolsEstimate = try #require(
            ChatGPTSubscriptionRequestBuilder.estimatedContextTokenCount(
                instructions: payload.instructions,
                input: payload.input,
                toolPayloads: toolPayloads
            )
        )

        #expect(withInstructionsEstimate > inputOnlyEstimate)
        #expect(withToolsEstimate > withInstructionsEstimate)
    }
#endif

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

#if os(macOS)
    private func chatGPTContinuationMessages() -> [[String: Any]] {
        [
            [
                "role": "system",
                "content": "System prompt"
            ],
            RemoteGenerationClient.remoteMessage(
                role: "user",
                content: "first prompt",
                attachments: []
            ),
            RemoteGenerationClient.remoteMessage(
                role: "assistant",
                content: "first answer",
                attachments: []
            ),
            RemoteGenerationClient.remoteMessage(
                role: "user",
                content: "second prompt",
                attachments: []
            )
        ]
    }

    private func chatGPTContinuationMessagesWithToolOutput() -> [[String: Any]] {
        [
            [
                "role": "system",
                "content": "System prompt"
            ],
            RemoteGenerationClient.remoteMessage(
                role: "user",
                content: "update the journal",
                attachments: []
            ),
            [
                "role": "assistant",
                "content": "",
                "tool_calls": [
                    [
                        "id": "call_memory",
                        "type": "function",
                        "function": [
                            "name": "memory_write",
                            "arguments": #"{"entry":"Updated journal."}"#
                        ]
                    ]
                ]
            ],
            [
                "role": "tool",
                "tool_call_id": "call_memory",
                "name": "memory_write",
                "content": "Saved memory entry to project MEMORY.md."
            ]
        ]
    }
#endif
}
