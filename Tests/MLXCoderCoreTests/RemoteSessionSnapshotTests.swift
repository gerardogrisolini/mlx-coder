import Foundation
@testable import MLXCoderCore
import Testing

@Suite(.serialized)
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

    @Test
    func remoteToolWireCatalogSanitizesXcodeNamesForResponses() throws {
        let catalog = RemoteToolWireCatalog(
            descriptors: [
                DirectToolDescriptor(
                    name: "xcode.BuildProject",
                    description: "Xcode: build project.",
                    inputSchema: #"{"type":"object","properties":{}}"#
                )
            ]
        )
        let toolPayloadNames = catalog.responsesToolPayloads.compactMap {
            $0["name"] as? String
        }
        let chatToolPayloadNames = catalog.chatCompletionToolPayloads.compactMap {
            (($0["function"] as? [String: Any])?["name"] as? String)
        }
        let localToolCall = catalog.localToolCall(
            from: DirectAgentToolCall(
                id: "call_xcode",
                name: "tool_xcode_BuildProject",
                argumentsObject: [:],
                argumentsJSON: "{}"
            )
        )

        #expect(toolPayloadNames == ["tool_xcode_BuildProject"])
        #expect(chatToolPayloadNames == ["tool_xcode_BuildProject"])
        #expect(localToolCall.name == "xcode.BuildProject")
    }

    @Test
    func responsesRequestSendsWireSafeToolNamesAndRestoresLocalXcodeToolCall() async throws {
        let response = """
        data: {"type":"response.output_item.done","output_index":0,"item":{"id":"item_xcode","type":"function_call","call_id":"call_xcode","name":"tool_xcode_BuildProject","arguments":"{\\"scheme\\":\\"App\\"}"}}

        data: {"type":"response.completed","response":{"output":[]}}

        """
        let urlSession = RemoteRequestCapturingURLProtocol.urlSession(
            responseBody: Data(response.utf8)
        )
        let client = RemoteGenerationClient(
            configuration: remoteStreamingConfiguration(),
            provider: AgentRemoteProvider(
                name: "Unit Test",
                baseURL: "https://unit.test/v1",
                modelID: "unit-model",
                chatEndpoint: .responses
            ),
            apiKey: nil,
            urlSession: urlSession,
            mcpRuntime: await borrowedXcodeMCPRuntime()
        )

        let result = try await client.streamResponses(
            messages: remoteXcodeHistoryMessages(),
            sessionID: "session-responses",
            allowedToolNames: ["local.exec", "xcode."],
            thinkingSelection: nil,
            onEvent: { _ in }
        )
        let request = try #require(RemoteRequestCapturingURLProtocol.capturedRequests().first)
        let body = try request.jsonObject()
        let toolNames = Set(
            ((body["tools"] as? [[String: Any]]) ?? []).compactMap {
                $0["name"] as? String
            }
        )
        let input = try #require(body["input"] as? [[String: Any]])
        let historyFunctionCall = try #require(input.first {
            $0["type"] as? String == "function_call"
                && $0["call_id"] as? String == "call_previous_xcode"
        })

        #expect(toolNames == ["tool_local_exec", "tool_xcode_BuildProject"])
        #expect(!toolNames.contains("local.exec"))
        #expect(!toolNames.contains("xcode.BuildProject"))
        #expect(historyFunctionCall["name"] as? String == "tool_xcode_BuildProject")
        #expect(JSONValue(jsonObject: body).prettyPrinted().contains("xcode.BuildProject") == false)
        #expect(result.toolCalls.map(\.name) == ["xcode.BuildProject"])
        #expect(result.toolCalls.first?.argumentsObject["scheme"] as? String == "App")
    }

    @Test
    func chatCompletionsRequestSendsWireSafeToolNamesAndRestoresLocalXcodeToolCall() async throws {
        let response = """
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_xcode","type":"function","function":{"name":"tool_xcode_BuildProject","arguments":"{\\"scheme\\":\\"App\\"}"}}]},"finish_reason":"tool_calls"}]}

        data: [DONE]

        """
        let urlSession = RemoteRequestCapturingURLProtocol.urlSession(
            responseBody: Data(response.utf8)
        )
        let client = RemoteGenerationClient(
            configuration: remoteStreamingConfiguration(),
            provider: AgentRemoteProvider(
                name: "Unit Test",
                baseURL: "https://unit.test/v1",
                modelID: "unit-model",
                chatEndpoint: .chatCompletions
            ),
            apiKey: nil,
            urlSession: urlSession,
            mcpRuntime: await borrowedXcodeMCPRuntime()
        )

        let result = try await client.streamChatCompletions(
            messages: remoteXcodeHistoryMessages(),
            sessionID: "session-chat",
            allowedToolNames: ["local.exec", "xcode."],
            thinkingSelection: nil,
            onEvent: { _ in }
        )
        let request = try #require(RemoteRequestCapturingURLProtocol.capturedRequests().first)
        let body = try request.jsonObject()
        let toolNames = Set(
            ((body["tools"] as? [[String: Any]]) ?? []).compactMap {
                ($0["function"] as? [String: Any])?["name"] as? String
            }
        )
        let messages = try #require(body["messages"] as? [[String: Any]])
        let assistant = try #require(messages.first {
            ($0["tool_calls"] as? [[String: Any]])?.contains {
                $0["id"] as? String == "call_previous_xcode"
            } == true
        })
        let historyToolCall = try #require((assistant["tool_calls"] as? [[String: Any]])?.first)
        let historyFunction = try #require(historyToolCall["function"] as? [String: Any])
        let toolMessage = try #require(messages.first {
            $0["role"] as? String == "tool"
                && $0["tool_call_id"] as? String == "call_previous_xcode"
        })

        #expect(toolNames == ["tool_local_exec", "tool_xcode_BuildProject"])
        #expect(!toolNames.contains("local.exec"))
        #expect(!toolNames.contains("xcode.BuildProject"))
        #expect(historyFunction["name"] as? String == "tool_xcode_BuildProject")
        #expect(toolMessage["name"] as? String == "tool_xcode_BuildProject")
        #expect(JSONValue(jsonObject: body).prettyPrinted().contains("xcode.BuildProject") == false)
        #expect(result.toolCalls.map(\.name) == ["xcode.BuildProject"])
        #expect(result.toolCalls.first?.argumentsObject["scheme"] as? String == "App")
    }

    @Test
    func streamResponsesEmitsOutputItemMessageTextAfterReasoning() async throws {
        let response = """
        data: {"type":"response.reasoning_text.delta","delta":"thinking"}

        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","content":[{"type":"output_text","text":"Visible answer"}]}}

        data: {"type":"response.completed","response":{"output":[]}}

        """
        let urlSession = RemoteRequestCapturingURLProtocol.urlSession(
            responseBody: Data(response.utf8)
        )
        let client = RemoteGenerationClient(
            configuration: remoteStreamingConfiguration(),
            provider: AgentRemoteProvider(
                name: "Unit Test",
                baseURL: "https://unit.test/v1",
                modelID: "unit-model",
                chatEndpoint: .responses
            ),
            apiKey: nil,
            urlSession: urlSession
        )
        let capturedEvents = CapturedDirectAgentEvents()

        let result = try await client.streamResponses(
            messages: [["role": "user", "content": "hi"]],
            sessionID: "session-output-item-message",
            allowedToolNames: [],
            thinkingSelection: nil,
            onEvent: { event in
                capturedEvents.append(event)
            }
        )

        #expect(result.text == "Visible answer")
        #expect(capturedEvents.thoughtText() == "thinking")
        #expect(capturedEvents.contentText() == "Visible answer")
    }

    @Test
    func streamChatCompletionsPromotesReasoningContentAfterThinkCloseToContent() async throws {
        let response = """
        data: {"choices":[{"delta":{"reasoning_content":"Analisi.</think>"}}]}

        data: {"choices":[{"delta":{"reasoning_content":"Risposta visibile."},"finish_reason":"stop"}]}

        data: [DONE]

        """
        let urlSession = RemoteRequestCapturingURLProtocol.urlSession(
            responseBody: Data(response.utf8)
        )
        let client = RemoteGenerationClient(
            configuration: remoteStreamingConfiguration(),
            provider: AgentRemoteProvider(
                name: "Unit Test",
                baseURL: "https://unit.test/v1",
                modelID: "unit-model",
                chatEndpoint: .chatCompletions
            ),
            apiKey: nil,
            urlSession: urlSession
        )
        let capturedEvents = CapturedDirectAgentEvents()

        let result = try await client.streamChatCompletions(
            messages: [["role": "user", "content": "hi"]],
            sessionID: "session-reasoning-content-boundary",
            allowedToolNames: [],
            thinkingSelection: nil,
            onEvent: { event in
                capturedEvents.append(event)
            }
        )

        #expect(result.text == "Risposta visibile.")
        #expect(capturedEvents.thoughtText() == "Analisi.")
        #expect(capturedEvents.contentText() == "Risposta visibile.")
    }

    @Test
    func chatTemplateThinkingPayloadIncludesReasoningEffort() async throws {
        let response = """
        data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}

        data: [DONE]

        """
        let urlSession = RemoteRequestCapturingURLProtocol.urlSession(
            responseBody: Data(response.utf8)
        )
        let client = RemoteGenerationClient(
            configuration: remoteStreamingConfiguration(),
            provider: AgentRemoteProvider(
                name: "NVIDIA",
                baseURL: "https://integrate.api.nvidia.com/v1",
                modelID: "deepseek-ai/deepseek-v4-flash",
                chatEndpoint: .chatCompletions
            ),
            apiKey: nil,
            urlSession: urlSession,
            mcpRuntime: await borrowedXcodeMCPRuntime()
        )

        _ = try await client.streamChatCompletions(
            messages: [["role": "user", "content": "hi"]],
            sessionID: "session-chat-template",
            allowedToolNames: [],
            thinkingSelection: .high,
            onEvent: { _ in }
        )
        let request = try #require(RemoteRequestCapturingURLProtocol.capturedRequests().first)
        let body = try request.jsonObject()
        let chatTemplateKwargs = try #require(body["chat_template_kwargs"] as? [String: Any])

        #expect(chatTemplateKwargs["thinking"] as? Bool == true)
        #expect(chatTemplateKwargs["enable_thinking"] as? Bool == true)
        #expect(chatTemplateKwargs["reasoning_effort"] as? String == "high")
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
    func chatGPTSubscriptionWebSocketHasNoDefaultResponseIdleTimeout() {
        #expect(ChatGPTSubscriptionResponsesClient.webSocketIdleTimeoutNanoseconds == nil)
    }

    @Test
    func chatCompletionDeltaContentPartsAreParsedAsContent() {
        let events = RemoteGenerationClient.parseChatCompletionStreamEvent([
            "choices": [
                [
                    "delta": [
                        "content": [
                            ["type": "text", "text": "Hello "],
                            ["type": "text", "text": "world"]
                        ],
                        "reasoning_content": "thinking..."
                    ]
                ]
            ]
        ])
        var contentText = ""
        var reasoningText = ""
        for event in events {
            switch event {
            case let .content(delta):
                contentText += delta
            case let .reasoning(delta):
                reasoningText += delta
            default:
                continue
            }
        }
        #expect(contentText == "Hello world")
        #expect(reasoningText == "thinking...")
    }

    @Test
    func chatCompletionFinalMessageContentIsParsedAsFinalContent() {
        let events = RemoteGenerationClient.parseChatCompletionStreamEvent([
            "choices": [
                [
                    "finish_reason": "stop",
                    "message": [
                        "role": "assistant",
                        "content": "Final answer"
                    ]
                ]
            ]
        ])
        var finalContent: String?
        for event in events {
            if case let .finalContent(text) = event {
                finalContent = text
            }
        }
        #expect(finalContent == "Final answer")
    }

    @Test
    func responsesOutputTextDoneIsParsedAsFinalContent() {
        let events = RemoteGenerationClient.parseResponsesStreamEvent([
            "type": "response.output_text.done",
            "text": "Final answer"
        ])
        var finalContent: String?
        for event in events {
            if case let .finalContent(text) = event {
                finalContent = text
            }
        }
        #expect(finalContent == "Final answer")
    }

    @Test
    func responsesCompletedMessageItemIsParsedAsFinalContent() {
        let events = RemoteGenerationClient.parseResponsesStreamEvent([
            "type": "response.completed",
            "response": [
                "output": [
                    [
                        "type": "message",
                        "content": [
                            ["type": "output_text", "text": "Final answer"]
                        ]
                    ]
                ]
            ]
        ])
        var finalContent: String?
        var sawStop = false
        for event in events {
            switch event {
            case let .finalContent(text):
                finalContent = text
            case .stop:
                sawStop = true
            default:
                continue
            }
        }
        #expect(finalContent == "Final answer")
        #expect(sawStop)
    }

    @Test
    func contentTextExtractsNestedContentPartObjects() {
        let text = RemoteGenerationClient.contentText(from: [
            ["type": "text_delta", "content": "Visible "],
            ["type": "output_text", "text": "answer"]
        ] as [[String: Any]])

        #expect(text == "Visible answer")
    }

    @Test
    func responsesContentPartDeltaIsParsedAsContent() {
        let events = RemoteGenerationClient.parseResponsesStreamEvent([
            "type": "response.content_part.delta",
            "delta": [
                "type": "output_text_delta",
                "content": "Visible answer"
            ]
        ])
        var contentText = ""
        for event in events {
            if case let .content(delta) = event {
                contentText += delta
            }
        }

        #expect(contentText == "Visible answer")
    }

    @Test
    func responsesOutputItemDoneMessageIsParsedAsFinalContent() {
        let events = RemoteGenerationClient.parseResponsesStreamEvent([
            "type": "response.output_item.done",
            "output_index": 0,
            "item": [
                "type": "agent_message",
                "content": [
                    ["type": "output_text", "text": "Visible answer"]
                ]
            ]
        ])
        var finalContent: String?
        for event in events {
            if case let .finalContent(text) = event {
                finalContent = text
            }
        }

        #expect(finalContent == "Visible answer")
    }

    @Test
    func unstreamedRemainderDeduplicatesFinalContent() {
        #expect(
            RemoteGenerationClient.unstreamedRemainder(
                of: "Hello world",
                alreadyStreamed: ""
            ) == "Hello world"
        )
        #expect(
            RemoteGenerationClient.unstreamedRemainder(
                of: "Hello world",
                alreadyStreamed: "Hello world"
            ) == ""
        )
        #expect(
            RemoteGenerationClient.unstreamedRemainder(
                of: "Hello world",
                alreadyStreamed: "Hello"
            ) == " world"
        )
        #expect(
            RemoteGenerationClient.unstreamedRemainder(
                of: "Hello world\n",
                alreadyStreamed: "Hello world"
            ) == ""
        )
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
    func chatGPTSubscriptionRequestBodySendsWireSafeXcodeToolNames() throws {
        let catalog = remoteXcodeToolCatalog()
        let payload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
            from: catalog.wireMessages(from: remoteXcodeHistoryMessages()),
            continuation: nil
        )
        let body = ChatGPTSubscriptionRequestBuilder.requestBody(
            input: JSONValue.acpValue(from: payload.input),
            model: "gpt-5.5",
            instructions: payload.instructions ?? "",
            reasoningEffort: nil,
            textVerbosity: "low",
            sessionID: "session-chatgpt-xcode",
            toolPayloads: JSONValue.acpValue(from: catalog.responsesToolPayloads)
        )
        let toolNames = Set(
            ((body["tools"] as? [[String: Any]]) ?? []).compactMap {
                $0["name"] as? String
            }
        )
        let input = try #require(body["input"] as? [[String: Any]])
        let historyFunctionCall = try #require(input.first {
            $0["type"] as? String == "function_call"
                && $0["call_id"] as? String == "call_previous_xcode"
        })

        #expect(toolNames == ["tool_local_exec", "tool_xcode_BuildProject"])
        #expect(!toolNames.contains("local.exec"))
        #expect(!toolNames.contains("xcode.BuildProject"))
        #expect(historyFunctionCall["name"] as? String == "tool_xcode_BuildProject")
        #expect(JSONValue(jsonObject: body).prettyPrinted().contains("xcode.BuildProject") == false)
    }

    @Test
    func chatGPTSubscriptionClientUsesInjectedMCPRuntimeForActiveTools() async throws {
        let client = ChatGPTSubscriptionGenerationClient(
            configuration: remoteStreamingConfiguration(),
            mcpRuntime: await borrowedXcodeMCPRuntime()
        )

        await client.createSession(
            id: "session-chatgpt-xcode-tools",
            cwd: "/tmp/project",
            allowedToolNames: ["xcode."]
        )
        let descriptors = await client.activeToolDescriptors()

        #expect(descriptors.map(\.name) == ["xcode.BuildProject"])
    }

    @Test
    func chatGPTSubscriptionWebSocketPayloadKeepsCachedContinuationWireSafe() throws {
        let catalog = remoteXcodeToolCatalog()
        let messages = catalog.wireMessages(from: remoteXcodeHistoryMessages())
        let payload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
            from: messages,
            continuation: ChatGPTSubscriptionContinuationState(
                responseID: "resp_previous_xcode",
                messageCount: messages.count - 1,
                instructions: "System prompt"
            )
        )
        let body = ChatGPTSubscriptionRequestBuilder.requestBody(
            input: JSONValue.acpValue(from: payload.input),
            model: "gpt-5.5",
            instructions: payload.instructions ?? "",
            reasoningEffort: nil,
            textVerbosity: "low",
            sessionID: "session-chatgpt-xcode-ws",
            toolPayloads: JSONValue.acpValue(from: catalog.responsesToolPayloads)
        )
        let cachedPayload = ChatGPTSubscriptionResponsesClient.webSocketRequestPayload(
            body: body,
            cachedInput: payload.cachedWebSocketInput.map { JSONValue.acpValue(from: $0) },
            previousResponseID: payload.previousResponseID,
            useCachedContinuation: true
        )
        let cachedInput = try #require(cachedPayload["input"] as? [[String: Any]])
        let toolNames = Set(
            ((cachedPayload["tools"] as? [[String: Any]]) ?? []).compactMap {
                $0["name"] as? String
            }
        )

        #expect(payload.previousResponseID == "resp_previous_xcode")
        #expect(cachedPayload["previous_response_id"] as? String == "resp_previous_xcode")
        #expect(cachedInput.count == 1)
        #expect((cachedInput.first?["type"] as? String) == "function_call_output")
        #expect(toolNames == ["tool_local_exec", "tool_xcode_BuildProject"])
        #expect(JSONValue(jsonObject: cachedPayload).prettyPrinted().contains("xcode.BuildProject") == false)
    }

    @Test
    func chatGPTSubscriptionSSERequestSendsWireSafeXcodeToolNamesAndRestoresLocalCall() async throws {
        let response = """
        data: {"type":"response.output_item.done","output_index":0,"item":{"id":"item_xcode","type":"function_call","call_id":"call_xcode","name":"tool_xcode_BuildProject","arguments":"{\\"scheme\\":\\"App\\"}"}}

        data: {"type":"response.completed","response":{"id":"resp_xcode","output":[]}}

        """
        let sessionID = "session-chatgpt-xcode-sse"
        let urlSession = RemoteRequestCapturingURLProtocol.urlSession(
            responseBody: Data(response.utf8)
        )
        let webSocketPool = ChatGPTSubscriptionWebSocketPool()
        webSocketPool.activateSSEFallback(sessionID: sessionID)
        let client = ChatGPTSubscriptionResponsesClient(
            credentials: chatGPTSubscriptionTestCredentials(),
            baseURL: URL(string: "https://unit.test/backend-api")!,
            urlSession: urlSession,
            webSocketPool: webSocketPool
        )
        let catalog = remoteXcodeToolCatalog()
        let payload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
            from: catalog.wireMessages(from: remoteXcodeHistoryMessages()),
            continuation: nil
        )
        let capturedEvents = CapturedSubscriptionEvents()

        let completion = try await client.streamEvents(
            input: JSONValue.acpValue(from: payload.input),
            model: "gpt-5.5",
            instructions: payload.instructions ?? "",
            reasoningEffort: nil,
            textVerbosity: "low",
            sessionID: sessionID,
            toolPayloads: JSONValue.acpValue(from: catalog.responsesToolPayloads),
            maxOutputTokens: nil
        ) { object in
            capturedEvents.append(object)
        }
        let request = try #require(RemoteRequestCapturingURLProtocol.capturedRequests().first)
        let body = try request.jsonObject()
        let toolNames = Set(
            ((body["tools"] as? [[String: Any]]) ?? []).compactMap {
                $0["name"] as? String
            }
        )
        let input = try #require(body["input"] as? [[String: Any]])
        let historyFunctionCall = try #require(input.first {
            $0["type"] as? String == "function_call"
                && $0["call_id"] as? String == "call_previous_xcode"
        })
        let remoteToolCalls = try subscriptionToolCalls(from: capturedEvents.all())
        let localToolCalls = remoteToolCalls.map(catalog.localToolCall)

        #expect(completion.responseID == "resp_xcode")
        #expect(request.request.value(forHTTPHeaderField: "OpenAI-Beta") == "responses=experimental")
        #expect(toolNames == ["tool_local_exec", "tool_xcode_BuildProject"])
        #expect(!toolNames.contains("local.exec"))
        #expect(!toolNames.contains("xcode.BuildProject"))
        #expect(historyFunctionCall["name"] as? String == "tool_xcode_BuildProject")
        #expect(JSONValue(jsonObject: body).prettyPrinted().contains("xcode.BuildProject") == false)
        #expect(localToolCalls.map(\.name) == ["xcode.BuildProject"])
        #expect(localToolCalls.first?.argumentsObject["scheme"] as? String == "App")
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

    @Test
    func chatGPTSubscriptionCompactionReservesContextAndDropsContinuation() throws {
        let maxTokens = 30_000
        let maxOutputTokens = 1_000
        let policyMaxTokens = try #require(
            ChatGPTSubscriptionGenerationClient.compactionPolicyMaxTokens(
                for: maxTokens,
                maxOutputTokens: maxOutputTokens
            )
        )
        let triggerTokens = AgentConversationCompactionPolicy.triggerTokenCount(
            for: policyMaxTokens
        )
        let usableTokens = maxTokens - max(
            maxOutputTokens,
            ChatGPTSubscriptionGenerationClient.compactionReserveTokenCount
        )
        let priorMessages = chatGPTCompactionMessages()
        let messages = priorMessages + [
            RemoteGenerationClient.remoteMessage(
                role: "user",
                content: "current prompt after cached response",
                attachments: []
            )
        ]
        let staleContinuation = ChatGPTSubscriptionContinuationState(
            responseID: "resp_before_compaction",
            messageCount: priorMessages.count,
            instructions: "System prompt"
        )
        let preCompactionPayload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
            from: messages,
            continuation: staleContinuation
        )

        let result = ChatGPTSubscriptionGenerationClient.compactedMessagesIfNeeded(
            messages,
            maxTokens: maxTokens,
            maxOutputTokens: maxOutputTokens
        )
        let compactedMessages = RemoteGenerationClient.remoteMessages(
            compactionResult: result,
            preservingRecentFrom: messages
        )
        let payload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
            from: compactedMessages,
            continuation: staleContinuation
        )
        let body = ChatGPTSubscriptionRequestBuilder.requestBody(
            input: JSONValue.acpValue(from: payload.input),
            model: "gpt-5.5",
            instructions: payload.instructions ?? "",
            reasoningEffort: nil,
            textVerbosity: "low",
            sessionID: "session-after-compaction"
        )
        let cachedPayload = ChatGPTSubscriptionResponsesClient.webSocketRequestPayload(
            body: body,
            cachedInput: payload.cachedWebSocketInput.map { JSONValue.acpValue(from: $0) },
            previousResponseID: payload.previousResponseID,
            useCachedContinuation: true
        )

        #expect(triggerTokens <= usableTokens)
        #expect(preCompactionPayload.previousResponseID == "resp_before_compaction")
        #expect(preCompactionPayload.cachedWebSocketInput != nil)
        #expect(result.wasCompacted)
        #expect(result.maxTokens == policyMaxTokens)
        #expect(compactedMessages.count < messages.count)
        #expect(
            result.compactedSystemPrompt?.contains(
                AgentConversationCompactionSupport.memorySummaryHeader
            ) == true
        )
        #expect(payload.previousResponseID == nil)
        #expect(payload.cachedWebSocketInput == nil)
        #expect(cachedPayload["previous_response_id"] == nil)
        #expect((cachedPayload["input"] as? [Any])?.count == payload.input.count)
    }

    @Test
    func chatGPTSubscriptionPreflightCompactsWhenEstimatedPayloadExceedsUsableContext() throws {
        let maxTokens = 50_000
        let maxOutputTokens = 1_000
        let messages = chatGPTPreflightCompactionMessages()
        let normalResult = ChatGPTSubscriptionGenerationClient.compactedMessagesIfNeeded(
            messages,
            maxTokens: maxTokens,
            maxOutputTokens: maxOutputTokens
        )
        let requestPayload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
            from: messages,
            continuation: nil
        )
        let toolPayloads = RemoteToolWireCatalog(
            descriptors: [
                DirectToolDescriptor(
                    name: "local.exec",
                    description: String(repeating: "large tool description ", count: 7_000),
                    inputSchema: #"{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}"#
                )
            ]
        ).responsesToolPayloads
        let estimatedContextTokens = try #require(
            ChatGPTSubscriptionRequestBuilder.estimatedContextTokenCount(
                instructions: requestPayload.instructions,
                input: requestPayload.input,
                toolPayloads: toolPayloads
            )
        )
        let policyMaxTokens = try #require(
            ChatGPTSubscriptionGenerationClient.compactionPolicyMaxTokens(
                for: maxTokens,
                maxOutputTokens: maxOutputTokens
            )
        )
        let preflightResult = try #require(
            ChatGPTSubscriptionGenerationClient.compactedMessagesForEstimatedContextIfNeeded(
                messages,
                estimatedContextTokens: estimatedContextTokens,
                maxTokens: maxTokens,
                maxOutputTokens: maxOutputTokens
            )
        )
        let compactedMessages = RemoteGenerationClient.remoteMessages(
            compactionResult: preflightResult,
            preservingRecentFrom: messages
        )

        #expect(normalResult.wasCompacted == false)
        #expect(estimatedContextTokens > AgentConversationCompactionPolicy.triggerTokenCount(for: policyMaxTokens))
        #expect(preflightResult.wasCompacted)
        #expect(compactedMessages.count < messages.count)
        #expect(
            preflightResult.compactedSystemPrompt?.contains(
                AgentConversationCompactionSupport.memorySummaryHeader
            ) == true
        )
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

    private func remoteXcodeHistoryMessages() -> [[String: Any]] {
        RemoteGenerationClient.initialMessages(
            cwd: "/tmp/project",
            systemPrompt: "System prompt",
            history: [
                AgentRuntimeMessage(role: .user, content: "build the app"),
                AgentRuntimeMessage(
                    role: .assistant,
                    content: "",
                    toolCalls: [
                        AgentRuntimeToolCall(
                            id: "call_previous_xcode",
                            name: "xcode.BuildProject",
                            argumentsJSON: #"{"scheme":"Previous"}"#
                        )
                    ]
                ),
                AgentRuntimeMessage(
                    role: .tool,
                    content: "Previous build succeeded.",
                    toolCallID: "call_previous_xcode",
                    toolName: "xcode.BuildProject"
                )
            ],
            allowedToolNames: ["xcode."]
        )
    }

    private func remoteStreamingConfiguration() -> AgentRuntimeConfiguration {
        AgentRuntimeConfiguration(
            modelID: "unit-model",
            bearerToken: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
            maxToolRounds: 4,
            verboseLogging: false,
            toolAuthorizationHandler: nil
        )
    }

    private func borrowedXcodeMCPRuntime() async -> DirectMCPToolRuntime {
        let mcpRuntime = DirectMCPToolRuntime()
        let xcodeExecutor = XcodeToolExecutor(
            configuration: MCPServerConfiguration(
                executablePath: "/usr/bin/false",
                arguments: [],
                environment: [:]
            )
        )
        await mcpRuntime.installBorrowedXcodeExecutor(
            xcodeExecutor,
            tools: [
                ToolDescriptor(
                    name: "BuildProject",
                    description: "Builds an Xcode project.",
                    inputSchema: #"{"type":"object","properties":{"scheme":{"type":"string"}}}"#
                )
            ]
        )
        return mcpRuntime
    }

#if os(macOS)
    private func remoteXcodeToolCatalog() -> RemoteToolWireCatalog {
        RemoteToolWireCatalog(
            descriptors: [
                DirectToolDescriptor(
                    name: "local.exec",
                    description: "Run a shell command.",
                    inputSchema: #"{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}"#
                ),
                DirectToolDescriptor(
                    name: "xcode.BuildProject",
                    description: "Builds an Xcode project.",
                    inputSchema: #"{"type":"object","properties":{"scheme":{"type":"string"}}}"#
                )
            ]
        )
    }

    private func chatGPTSubscriptionTestCredentials() -> CodexAgentCredentials {
        CodexAgentCredentials(
            accessToken: "test-access-token",
            refreshToken: "test-refresh-token",
            expiresAt: Date().addingTimeInterval(3600),
            accountID: "test-account"
        )
    }

    private func subscriptionToolCalls(
        from objects: [[String: Any]]
    ) throws -> [DirectAgentToolCall] {
        var accumulator = RemoteToolCallAccumulator()
        for object in objects {
            for event in RemoteGenerationClient.parseResponsesStreamEvent(object) {
                switch event {
                case let .responseToolCallItem(item, outputIndex):
                    accumulator.ingestResponseToolCallItem(item, outputIndex: outputIndex)
                case let .responseToolCallArgumentsDelta(event):
                    accumulator.ingestResponseToolCallArgumentsDelta(event)
                case let .responseToolCallArgumentsDone(event):
                    accumulator.ingestResponseToolCallArgumentsDone(event)
                default:
                    continue
                }
            }
        }
        return try accumulator.finalize()
    }

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

    private func chatGPTPreflightCompactionMessages() -> [[String: Any]] {
        var messages: [[String: Any]] = [
            [
                "role": "system",
                "content": "System prompt"
            ]
        ]
        for index in 0..<6 {
            let role = index.isMultiple(of: 2) ? "user" : "assistant"
            messages.append(
                RemoteGenerationClient.remoteMessage(
                    role: role,
                    content: "brief message \(index) " + String(repeating: "detail ", count: 20),
                    attachments: []
                )
            )
        }
        return messages
    }

    private func chatGPTCompactionMessages() -> [[String: Any]] {
        var messages: [[String: Any]] = [
            [
                "role": "system",
                "content": "System prompt"
            ]
        ]
        for index in 0..<18 {
            messages.append(
                RemoteGenerationClient.remoteMessage(
                    role: "user",
                    content: "request \(index) " + String(repeating: "u", count: 1_800),
                    attachments: []
                )
            )
            messages.append(
                RemoteGenerationClient.remoteMessage(
                    role: "assistant",
                    content: "answer \(index) " + String(repeating: "a", count: 1_800),
                    attachments: []
                )
            )
        }
        return messages
    }
#endif
}

private final class CapturedDirectAgentEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DirectAgentEvent] = []

    func append(_ event: DirectAgentEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func contentText() -> String {
        lockedEvents().reduce(into: "") { text, event in
            if case let .content(delta) = event {
                text += delta
            }
        }
    }

    func thoughtText() -> String {
        lockedEvents().reduce(into: "") { text, event in
            if case let .thought(delta) = event {
                text += delta
            }
        }
    }

    private func lockedEvents() -> [DirectAgentEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private final class CapturedSubscriptionEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var objects: [[String: Any]] = []

    func append(_ object: [String: Any]) {
        lock.lock()
        objects.append(object)
        lock.unlock()
    }

    func all() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return objects
    }
}

private struct CapturedRemoteRequest: Sendable {
    let request: URLRequest
    let body: Data

    func jsonObject() throws -> [String: Any] {
        let value = try JSONDecoder().decode(JSONValue.self, from: body)
        return try #require(value.mlxObjectValue).mapValues(\.jsonObject)
    }
}

private final class RemoteRequestCapturingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var responseBody = Data()
    nonisolated(unsafe) private static var requests: [CapturedRemoteRequest] = []
    private static let lock = NSLock()

    static func urlSession(responseBody: Data) -> URLSession {
        lock.lock()
        self.responseBody = responseBody
        requests = []
        lock.unlock()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteRequestCapturingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func capturedRequests() -> [CapturedRemoteRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Self.bodyData(from: request) ?? Data()
        Self.lock.lock()
        Self.requests.append(CapturedRemoteRequest(request: request, body: body))
        let responseBody = Self.responseBody
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://unit.test")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else {
                break
            }
            data.append(buffer, count: read)
        }
        return data
    }
}
