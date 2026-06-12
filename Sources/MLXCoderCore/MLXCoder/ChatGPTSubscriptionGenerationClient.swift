//
//  ChatGPTSubscriptionGenerationClient.swift
//  SwiftMLX
//
//  Created by Codex on 13/05/26.
//

#if os(macOS)
import Foundation
import os

private struct ChatGPTSubscriptionToolCallUpdate: Sendable {
    let id: String
    let title: String
    let status: String
    let rawInput: String?
    let output: String?
}

private enum ChatGPTSubscriptionStreamEvent: Sendable {
    case thought(String)
    case content(String)
    case toolCall(ChatGPTSubscriptionToolCallUpdate)
    case modelLoaded(String)
    case contextWindow(DirectAgentContextWindowStatus)
    case completed(stopReason: String?)
}

public struct ChatGPTSubscriptionContinuationState: Equatable, Sendable {
    public let responseID: String
    public let messageCount: Int
    public let instructions: String

    public init(responseID: String, messageCount: Int, instructions: String) {
        self.responseID = responseID
        self.messageCount = messageCount
        self.instructions = instructions
    }
}

public enum ChatGPTSubscriptionRequestBuilder {
    public static func requestInputPayload(
        from messages: [[String: Any]],
        continuation: ChatGPTSubscriptionContinuationState?
    ) -> (instructions: String?, input: [Any], cachedWebSocketInput: [Any]?, previousResponseID: String?) {
        let fullPayload = RemoteGenerationClient.responsesInputPayload(from: messages)
        let normalizedInstructions = fullPayload.instructions?.nilIfBlank

        guard let continuation,
              continuation.messageCount >= 0,
              continuation.messageCount <= messages.count,
              !continuation.responseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              continuation.instructions == (normalizedInstructions ?? "") else {
            return (
                normalizedInstructions,
                fullPayload.input,
                nil,
                nil
            )
        }

        let deltaMessages = Array(messages[continuation.messageCount...])
        let deltaPayload = RemoteGenerationClient.responsesInputPayload(from: deltaMessages)
        guard deltaPayload.instructions?.nilIfBlank == nil,
              !deltaPayload.input.isEmpty else {
            return (
                normalizedInstructions,
                fullPayload.input,
                nil,
                nil
            )
        }

        return (
            normalizedInstructions,
            fullPayload.input,
            deltaPayload.input,
            continuation.responseID
        )
    }

    public static func requestBody(
        input: JSONValue,
        model: String,
        instructions: String,
        reasoningEffort: String?,
        textVerbosity: String,
        sessionID: String,
        toolPayloads: JSONValue = .array([]),
        maxOutputTokens: Int? = nil
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "store": false,
            "stream": true,
            "instructions": instructions,
            "input": input.acpJSONObject,
            "text": [
                "verbosity": textVerbosity
            ],
            "include": [
                "reasoning.encrypted_content"
            ],
            "prompt_cache_key": sessionID
        ]

        if case let .array(tools) = toolPayloads, !tools.isEmpty {
            body["tools"] = toolPayloads.acpJSONObject
            body["tool_choice"] = "auto"
            body["parallel_tool_calls"] = true
        }

        if let maxOutputTokens, maxOutputTokens > 0 {
            body["max_output_tokens"] = maxOutputTokens
        }

        let normalizedReasoningEffort = reasoningEffort?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
        if let normalizedReasoningEffort,
           normalizedReasoningEffort != "none" {
            body["reasoning"] = [
                "effort": normalizedReasoningEffort,
                "summary": "auto"
            ]
        }

        return body
    }

    public static func estimatedContextTokenCount(
        instructions: String?,
        input: [Any],
        toolPayloads: [[String: Any]]
    ) -> Int? {
        var payload: [String: Any] = [:]
        if let instructions = instructions?.nilIfBlank {
            payload["instructions"] = instructions
        }
        if !input.isEmpty {
            payload["input"] = input
        }
        if !toolPayloads.isEmpty {
            payload["tools"] = toolPayloads
        }

        guard !payload.isEmpty,
              let data = try? JSONValue(jsonObject: payload).jsonData(
                  outputFormatting: [.withoutEscapingSlashes]
              ),
              !data.isEmpty else {
            return nil
        }
        return max(Int((Double(data.count) / 4.0).rounded(.up)), 1)
    }
}

public actor ChatGPTSubscriptionGenerationClient: AgentRuntimeBackend {
    public static var isAvailable: Bool {
        CodexAgentModel.isReady
    }

    private struct AgentSession {
        let id: String
        let cwd: String
        var systemPrompt: String?
        let cacheKey: String?
        var messages: [[String: Any]]
        var allowedToolNames: Set<String>?
        var thinkingSelection: AgentThinkingSelection?
        var preserveThinking: Bool
        var continuation: ChatGPTSubscriptionContinuationState?
        var chatGPTSessionID: String?
    }

    private struct RequestConfiguration {
        let modelID: String?
        let workingDirectory: String
        let systemPrompt: String
        let sessionKey: String
        let history: [AgentRuntimeMessage]
        let allowedToolNames: Set<String>?
        let thinkingSelection: AgentThinkingSelection?
        let appMode: Bool
    }

    private struct SessionIdentity: Codable, Hashable, Sendable {
        let sessionKey: String
        let modelID: String
        let workingDirectory: String
        let systemPrompt: String
        let toolSelection: String?
        let appMode: Bool

        init(configuration: RequestConfiguration) {
            let key = configuration.sessionKey
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let model = CodexAgentModel.selectionID(
                forModelID: CodexAgentModel.modelID(fromLLMID: configuration.modelID)
            )
                .trimmingCharacters(in: .whitespacesAndNewlines)

            sessionKey = key.isEmpty ? "default" : key
            modelID = model.isEmpty ? CodexAgentModel.defaultLLMID : model
            workingDirectory = configuration.workingDirectory
            systemPrompt = configuration.systemPrompt
            toolSelection = Self.toolSelectionSignature(
                configuration.allowedToolNames
            )
            appMode = configuration.appMode
        }

        init?(storageKey: String) {
            guard let data = Data(base64Encoded: storageKey),
                  let value = try? JSONDecoder().decode(Self.self, from: data) else {
                return nil
            }
            self = value
        }

        var storageKey: String {
            guard let data = try? JSONEncoder().encode(self) else {
                return [
                    sessionKey,
                    modelID,
                    workingDirectory,
                    systemPrompt,
                    toolSelection ?? "tools:any",
                    appMode ? "app" : "cli"
                ].joined(separator: "\u{1f}")
            }
            return data.base64EncodedString()
        }

        private static func toolSelectionSignature(_ allowedToolNames: Set<String>?) -> String? {
            guard let allowedToolNames else {
                return nil
            }

            let names = allowedToolNames
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .sorted()
            guard !names.isEmpty else {
                return "tools:none"
            }
            return "tools:\(names.joined(separator: "\u{1e}"))"
        }
        }

    private struct StreamAccumulatorResult {
        let text: String
        let reasoningText: String
        let stopReason: String
        let toolCalls: [DirectAgentToolCall]
        let usage: RemoteGenerationUsage?
        let firstDeltaAt: Date?
        let latestResponseID: String?
    }

    private final class StreamAccumulator: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock()
        private var responseText = ""
        private var responseReasoningText = ""
        private var stopReason = "end_turn"
        private var toolCallAccumulator = RemoteToolCallAccumulator()
        private var requestUsage: RemoteGenerationUsage?
        private var firstDeltaAt: Date?
        private var didReceiveContentDelta = false
        private var latestResponseID: String?

        func ingest(_ object: [String: Any]) throws -> [DirectAgentEvent] {
            lock.lock()
            defer {
                lock.unlock()
            }

            if let errorMessage = ChatGPTSubscriptionGenerationClient.responseErrorMessage(from: object) {
                throw ChatGPTSubscriptionGenerationError.responseFailed(errorMessage)
            }

            if let responseID = ChatGPTSubscriptionGenerationClient.responseID(from: object) {
                latestResponseID = responseID
            }

            var events: [DirectAgentEvent] = []
            var didParseReasoningDeltaFromResponsesEvent = false
            for event in RemoteGenerationClient.parseResponsesStreamEvent(object) {
                switch event {
                case let .content(delta):
                    guard !delta.isEmpty else {
                        continue
                    }
                    markFirstDelta()
                    didReceiveContentDelta = true
                    responseText.append(delta)
                    events.append(.content(delta))
                case let .reasoning(delta):
                    guard !delta.isEmpty else {
                        continue
                    }
                    didParseReasoningDeltaFromResponsesEvent = true
                    markFirstDelta()
                    responseReasoningText.append(delta)
                    events.append(.thought(delta))
                case let .responseToolCallItem(item, outputIndex):
                    markFirstDelta()
                    toolCallAccumulator.ingestResponseToolCallItem(
                        item,
                        outputIndex: outputIndex
                    )
                case let .responseToolCallArgumentsDelta(event):
                    markFirstDelta()
                    toolCallAccumulator.ingestResponseToolCallArgumentsDelta(event)
                case let .responseToolCallArgumentsDone(event):
                    markFirstDelta()
                    toolCallAccumulator.ingestResponseToolCallArgumentsDone(event)
                case let .stop(reason):
                    stopReason = reason
                case let .failure(message):
                    throw ChatGPTSubscriptionGenerationError.responseFailed(message)
                case let .usage(remoteUsage):
                    requestUsage = remoteUsage
                case .toolCallDelta, .ignored:
                    continue
                }
            }

            let normalizedType = (object["type"] as? String)
                .map(ChatGPTSubscriptionGenerationClient.normalizedEventType) ?? ""
            switch normalizedType {
            case "response_output_text_delta",
                 "response_content_part_delta":
                guard !didReceiveContentDelta,
                      let delta = ChatGPTSubscriptionGenerationClient.responseContentDelta(from: object),
                      !delta.isEmpty else {
                    return events
                }
                markFirstDelta()
                didReceiveContentDelta = true
                responseText.append(delta)
                events.append(.content(delta))
            case "response_reasoning_summary_text_delta",
                 "response_reasoning_text_delta",
                 "response_reasoning_delta",
                 "response_reasoning_summary_delta",
                 "response_reasoning_raw_content_delta":
                if !didParseReasoningDeltaFromResponsesEvent,
                   let delta = ChatGPTSubscriptionGenerationClient.responseReasoningDelta(from: object),
                   !delta.isEmpty {
                    markFirstDelta()
                    responseReasoningText.append(delta)
                    events.append(.thought(delta))
                }
            case "response_completed",
                 "response_done",
                 "response_incomplete":
                if !didReceiveContentDelta,
                   let completedText = ChatGPTSubscriptionGenerationClient.completedResponseText(from: object),
                   !completedText.isEmpty {
                    markFirstDelta()
                    didReceiveContentDelta = true
                    responseText.append(completedText)
                    events.append(.content(completedText))
                }
            default:
                break
            }

            return events
        }

        func recordCompletionResponseID(_ responseID: String?) {
            guard let responseID = responseID?.nilIfBlank else {
                return
            }
            lock.lock()
            latestResponseID = responseID
            lock.unlock()
        }

        func result(toolCatalog: RemoteToolWireCatalog) throws -> StreamAccumulatorResult {
            lock.lock()
            defer {
                lock.unlock()
            }

            let remoteToolCalls = try toolCallAccumulator.finalize()
            return StreamAccumulatorResult(
                text: responseText,
                reasoningText: responseReasoningText,
                stopReason: stopReason,
                toolCalls: remoteToolCalls.map(toolCatalog.localToolCall),
                usage: requestUsage,
                firstDeltaAt: firstDeltaAt,
                latestResponseID: latestResponseID
            )
        }

        private func markFirstDelta() {
            if firstDeltaAt == nil {
                firstDeltaAt = Date()
            }
        }
    }

    private static let sessionStoreUserDefaultsKey =
        "ChatGPTSubscriptionGenerationClient.sessionIDsByIdentity.v1"
    static let compactionReserveTokenCount = 20_000

    private let configuration: AgentRuntimeConfiguration
    private let urlSession: URLSession
    private let toolExecutor: DirectToolExecutor
    private let webSocketPool = ChatGPTSubscriptionWebSocketPool()
    private var sessions: [String: AgentSession] = [:]
    private var sessionIDsByIdentity = ChatGPTSubscriptionGenerationClient.loadStoredSessionIDs()

    public init(
        configuration: AgentRuntimeConfiguration,
        urlSession: URLSession? = nil,
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime()
    ) {
        self.configuration = configuration
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.timeoutIntervalForRequest = 900
            sessionConfiguration.timeoutIntervalForResource = 900
            self.urlSession = URLSession(configuration: sessionConfiguration)
        }
        self.toolExecutor = DirectToolExecutor(
            outputLimit: 24_000,
            authorizationHandler: configuration.toolAuthorizationHandler,
            mcpRuntime: mcpRuntime,
            preferredWorkspaceRootURL: configuration.workingDirectory,
            subAgentBackendFactory: {
                ChatGPTSubscriptionGenerationClient(
                    configuration: configuration,
                    urlSession: urlSession,
                    mcpRuntime: mcpRuntime
                )
            }
        )
    }

    public func createSession(
        id: String,
        cwd: String,
        systemPrompt: String? = nil,
        history: [AgentRuntimeMessage] = [],
        cacheKey: String? = nil,
        allowedToolNames: Set<String>? = nil,
        thinkingSelection: AgentThinkingSelection? = nil,
        preserveThinking: Bool = false
    ) {
        sessions[id] = AgentSession(
            id: id,
            cwd: cwd,
            systemPrompt: systemPrompt,
            cacheKey: cacheKey,
            messages: RemoteGenerationClient.initialMessages(
                cwd: cwd,
                systemPrompt: systemPrompt,
                history: history,
                allowedToolNames: allowedToolNames
            ),
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking,
            continuation: nil,
            chatGPTSessionID: nil
        )
    }

    public func createSessionIfNeeded(
        id: String,
        cwd: String,
        systemPrompt: String? = nil,
        history: [AgentRuntimeMessage] = [],
        cacheKey: String? = nil,
        allowedToolNames: Set<String>? = nil,
        thinkingSelection: AgentThinkingSelection? = nil,
        preserveThinking: Bool = false
    ) {
        guard sessions[id] == nil else {
            return
        }
        createSession(
            id: id,
            cwd: cwd,
            systemPrompt: systemPrompt,
            history: history,
            cacheKey: cacheKey,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    public func updateSessionOptions(
        id: String,
        systemPrompt: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        guard var session = sessions[id] else {
            return
        }
        let oldSystemPrompt = session.systemPrompt
        let oldAllowedToolNames = session.allowedToolNames
        session.systemPrompt = systemPrompt

        session.messages = RemoteGenerationClient.replacingSystemPrompt(
            in: session.messages,
            cwd: session.cwd,
            systemPrompt: systemPrompt,
            allowedToolNames: allowedToolNames
        )
        session.allowedToolNames = allowedToolNames
        session.thinkingSelection = thinkingSelection
        session.preserveThinking = preserveThinking
        if oldSystemPrompt != systemPrompt || oldAllowedToolNames != allowedToolNames {
            if let chatGPTSessionID = session.chatGPTSessionID {
                webSocketPool.closeSession(sessionID: chatGPTSessionID)
            }
            session.continuation = nil
            session.chatGPTSessionID = nil
        }

        sessions[id] = session
    }

    public func closeSession(id: String) async {
        let session = sessions.removeValue(forKey: id)
        if let chatGPTSessionID = session?.chatGPTSessionID {
            webSocketPool.closeSession(sessionID: chatGPTSessionID)
        }
    }

    public func shutdown() async {
        sessions.removeAll()
        webSocketPool.closeAll()
        await toolExecutor.shutdown()
    }

    public func updateBorrowedOrchestrationToolExecutor(
        _ executor: AgentBorrowedToolExecutor?
    ) async {
        await toolExecutor.updateBorrowedOrchestrationToolExecutor(executor)
    }

    public func updateToolProviders(_ providers: [AgentToolProvider]) async {
        await toolExecutor.updateToolProviders(providers)
    }

    public func preloadModel(
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        _ = try await CodexAgentModel.loadValidCredentials()
        let modelLLMID = modelLLMID()
        await onEvent(.modelLoaded(CodexAgentModel.selectionTitle(forLLMID: modelLLMID)))
        return modelLLMID
    }

    public func activeToolDescriptors() async -> [DirectToolDescriptor] {
        guard let session = sessions.values.first else {
            return await toolExecutor.descriptors(allowedToolNames: [])
        }
        return await toolExecutor.descriptors(
            allowedToolNames: session.allowedToolNames,
            preferredWorkspaceRootURL: URL(fileURLWithPath: session.cwd)
        )
    }

    public func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        await toolExecutor.subAgentSnapshots()
    }

    public func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        guard let session = sessions[id] else {
            return nil
        }
        let splitMessages = RemoteGenerationClient.snapshotMessages(
            from: session.messages
        )
        return AgentRuntimeSessionSnapshot(
            sessionID: id,
            modelID: configuration.modelID,
            workingDirectoryPath: session.cwd,
            systemPrompt: splitMessages.systemPrompt ?? session.systemPrompt,
            cacheKey: session.cacheKey,
            history: splitMessages.history,
            allowedToolNames: session.allowedToolNames,
            thinkingSelection: session.thinkingSelection,
            preserveThinking: session.preserveThinking
        )
    }

    public func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        if sessions[sessionID] == nil {
            createSession(
                id: sessionID,
                cwd: configuration.workingDirectory.path,
                systemPrompt: nil
            )
        }
        guard var session = sessions[sessionID] else {
            throw ChatGPTSubscriptionGenerationError.missingSession
        }

        let credentials = try await CodexAgentModel.loadValidCredentials()
        let modelLLMID = modelLLMID()
        let modelID = CodexAgentModel.modelID(fromLLMID: modelLLMID)
        await onEvent(.modelLoaded(CodexAgentModel.selectionTitle(forLLMID: modelLLMID)))
        let requestConfiguration = RequestConfiguration(
            modelID: modelLLMID,
            workingDirectory: session.cwd,
            systemPrompt: session.systemPrompt ?? "",
            sessionKey: session.cacheKey?.nilIfBlank ?? session.id,
            history: [],
            allowedToolNames: session.allowedToolNames,
            thinkingSelection: session.thinkingSelection,
            appMode: configuration.appMode
                )
        let sessionIdentity = SessionIdentity(configuration: requestConfiguration)
        let chatGPTSessionID = sessionIDsByIdentity[sessionIdentity] ?? UUID().uuidString
        storeSessionID(chatGPTSessionID, for: sessionIdentity)
        session.chatGPTSessionID = chatGPTSessionID
        sessions[sessionID] = session

        let client = ChatGPTSubscriptionResponsesClient(
            credentials: credentials,
            urlSession: urlSession,
            webSocketPool: webSocketPool
        )
        let reasoningEffort = session.thinkingSelection
            .flatMap(Self.chatGPTReasoningEffort(for:))
        let maxContextWindowTokens = resolvedContextWindowTokenLimit(
            forLLMID: modelLLMID
        )

        session.messages.append(
            RemoteGenerationClient.remoteMessage(
                role: AgentRuntimeMessage.Role.user.rawValue,
                content: prompt,
                attachments: attachments
            )
        )

        var accumulatedText = ""
        var generationStats: [RemoteGenerationStats] = []

        for round in 0..<configuration.maxToolRounds {
            if let result = compactSessionIfNeeded(
                &session,
                maxTokens: maxContextWindowTokens,
                maxOutputTokens: configuration.maxOutputTokens,
                sessionIdentity: sessionIdentity
            ) {
                await onEvent(.diagnostic(Self.compactionDiagnostic(from: result)))
            }
            let toolCatalog = RemoteToolWireCatalog(
                descriptors: await toolExecutor.descriptors(
                    allowedToolNames: session.allowedToolNames,
                    preferredWorkspaceRootURL: URL(fileURLWithPath: session.cwd)
                )
            )
            if configuration.verboseLogging {
                await onEvent(
                    .diagnostic(
                        RemoteGenerationClient.toolExposureDiagnostic(
                            from: toolCatalog.bindings.map(\.descriptor)
                        )
                    )
                )
            }
            var requestPayload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
                from: toolCatalog.wireMessages(from: session.messages),
                continuation: session.continuation
            )
            var instructions = requestPayload.instructions?.nilIfBlank
                ?? "You are a helpful coding assistant."
            let toolPayloads = toolCatalog.responsesToolPayloads
            var estimatedContextTokens = ChatGPTSubscriptionRequestBuilder.estimatedContextTokenCount(
                instructions: instructions,
                input: requestPayload.input,
                toolPayloads: toolPayloads
            )
            if let result = compactSessionForEstimatedContextIfNeeded(
                &session,
                estimatedContextTokens: estimatedContextTokens,
                maxTokens: maxContextWindowTokens,
                maxOutputTokens: configuration.maxOutputTokens,
                sessionIdentity: sessionIdentity
            ) {
                await onEvent(.diagnostic(Self.compactionDiagnostic(from: result)))
                requestPayload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
                    from: toolCatalog.wireMessages(from: session.messages),
                    continuation: session.continuation
                )
                instructions = requestPayload.instructions?.nilIfBlank
                    ?? "You are a helpful coding assistant."
                estimatedContextTokens = ChatGPTSubscriptionRequestBuilder.estimatedContextTokenCount(
                    instructions: instructions,
                    input: requestPayload.input,
                    toolPayloads: toolPayloads
                )
            }
            if let estimatedContextTokens {
                await onEvent(
                    .contextWindow(
                        DirectAgentContextWindowStatus(
                            usedTokens: estimatedContextTokens,
                            maxTokens: maxContextWindowTokens,
                            modelID: modelLLMID,
                            isApproximate: true
                        )
                    )
                )
            }

            let requestStartedAt = Date()
            let streamAccumulator = StreamAccumulator()

            let completion = try await client.streamEvents(
                input: JSONValue.acpValue(from: requestPayload.input),
                model: modelID,
                instructions: instructions,
                reasoningEffort: reasoningEffort,
                textVerbosity: "low",
                sessionID: session.chatGPTSessionID ?? chatGPTSessionID,
                cachedWebSocketInput: requestPayload.cachedWebSocketInput.map {
                    JSONValue.acpValue(from: $0)
                },
                previousResponseID: requestPayload.previousResponseID,
                toolPayloads: JSONValue.acpValue(from: toolPayloads),
                maxOutputTokens: configuration.maxOutputTokens
            ) { object in
                try Task.checkCancellation()
                let events = try streamAccumulator.ingest(object)
                for event in events {
                    await onEvent(event)
                }
            }

            streamAccumulator.recordCompletionResponseID(completion.responseID)
            let streamResult = try streamAccumulator.result(toolCatalog: toolCatalog)
            generationStats.append(
                RemoteGenerationStats(
                    usage: streamResult.usage,
                    requestStartedAt: requestStartedAt,
                    firstDeltaAt: streamResult.firstDeltaAt,
                    finishedAt: Date(),
                    generatedCharacterCount: streamResult.text.count
                )
            )
            accumulatedText.append(streamResult.text)

            Self.appendAssistantMessage(
                text: streamResult.text,
                reasoningText: streamResult.reasoningText,
                toolCalls: streamResult.toolCalls,
                to: &session.messages
            )
            if let responseID = streamResult.latestResponseID?.nilIfBlank {
                session.continuation = ChatGPTSubscriptionContinuationState(
                    responseID: responseID,
                    messageCount: session.messages.count,
                    instructions: instructions
                )
            } else {
                session.continuation = nil
            }

            if let metrics = RemoteGenerationClient.generationMetrics(generationStats) {
                await Self.publishChatGPTSubscriptionMetrics(
                    metrics,
                    estimatedContextTokens: estimatedContextTokens,
                    completionTokens: streamResult.usage?.completionTokens,
                    generatedText: streamResult.text,
                    maxTokens: maxContextWindowTokens,
                    modelID: modelLLMID,
                    onEvent: onEvent
                )
            }

            if streamResult.toolCalls.isEmpty {
                sessions[sessionID] = session
                return DirectAgentResponse(
                    text: accumulatedText,
                    stopReason: streamResult.stopReason,
                    modelID: modelLLMID
                )
            }

            for toolCall in streamResult.toolCalls {
                await onEvent(.toolCallStarted(toolCall))
                let result = await toolExecutor.execute(
                    sessionID: session.id,
                    toolCall: toolCall,
                    workingDirectory: URL(fileURLWithPath: session.cwd),
                    allowedToolNames: session.allowedToolNames
                )
                await onEvent(.toolCallCompleted(toolCall, result))
                session.messages.append([
                    "role": "tool",
                    "tool_call_id": toolCall.id,
                    "name": toolCall.name,
                    "content": result.output
                ])
            }

            if round == configuration.maxToolRounds - 1 {
                sessions[sessionID] = session
                throw ChatGPTSubscriptionGenerationError.tooManyToolRounds(
                    configuration.maxToolRounds
                )
            }
        }

        sessions[sessionID] = session
        throw ChatGPTSubscriptionGenerationError.tooManyToolRounds(configuration.maxToolRounds)
    }

    private func compactSessionIfNeeded(
        _ session: inout AgentSession,
        maxTokens: Int?,
        maxOutputTokens: Int?,
        sessionIdentity: SessionIdentity
    ) -> AgentConversationCompactionResult? {
        let result = Self.compactedMessagesIfNeeded(
            session.messages,
            maxTokens: maxTokens,
            maxOutputTokens: maxOutputTokens
        )

        guard result.wasCompacted else {
            return nil
        }

        session.messages = RemoteGenerationClient.remoteMessages(
            compactionResult: result,
            preservingRecentFrom: session.messages
        )
        resetContinuationAfterCompaction(
            session: &session,
            sessionIdentity: sessionIdentity
        )
        return result
    }

    private func compactSessionForEstimatedContextIfNeeded(
        _ session: inout AgentSession,
        estimatedContextTokens: Int?,
        maxTokens: Int?,
        maxOutputTokens: Int?,
        sessionIdentity: SessionIdentity
    ) -> AgentConversationCompactionResult? {
        guard let result = Self.compactedMessagesForEstimatedContextIfNeeded(
            session.messages,
            estimatedContextTokens: estimatedContextTokens,
            maxTokens: maxTokens,
            maxOutputTokens: maxOutputTokens
        ) else {
            return nil
        }

        session.messages = RemoteGenerationClient.remoteMessages(
            compactionResult: result,
            preservingRecentFrom: session.messages
        )
        resetContinuationAfterCompaction(
            session: &session,
            sessionIdentity: sessionIdentity
        )
        return result
    }

    private func resetContinuationAfterCompaction(
        session: inout AgentSession,
        sessionIdentity: SessionIdentity
    ) {
        session.continuation = nil
        if let chatGPTSessionID = session.chatGPTSessionID {
            webSocketPool.closeSession(sessionID: chatGPTSessionID)
        }
        let replacementSessionID = UUID().uuidString
        session.chatGPTSessionID = replacementSessionID
        storeSessionID(replacementSessionID, for: sessionIdentity)
    }

    static func compactedMessagesIfNeeded(
        _ messages: [[String: Any]],
        maxTokens: Int?,
        maxOutputTokens: Int? = nil,
        force: Bool = false
    ) -> AgentConversationCompactionResult {
        let compactionLimit = compactionPolicyMaxTokens(
            for: maxTokens,
            maxOutputTokens: maxOutputTokens
        )
        return AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            RemoteGenerationClient.agentRuntimeMessages(from: messages),
            maxTokens: compactionLimit,
            force: force
        )
    }

    static func compactedMessagesForEstimatedContextIfNeeded(
        _ messages: [[String: Any]],
        estimatedContextTokens: Int?,
        maxTokens: Int?,
        maxOutputTokens: Int? = nil
    ) -> AgentConversationCompactionResult? {
        guard shouldCompactEstimatedContext(
            estimatedContextTokens: estimatedContextTokens,
            maxTokens: maxTokens,
            maxOutputTokens: maxOutputTokens,
            messageCount: conversationMessageCount(in: messages)
        ) else {
            return nil
        }

        let result = compactedMessagesIfNeeded(
            messages,
            maxTokens: maxTokens,
            maxOutputTokens: maxOutputTokens,
            force: true
        )
        return result.wasCompacted ? result : nil
    }

    static func compactionPolicyMaxTokens(
        for maxTokens: Int?,
        maxOutputTokens: Int? = nil
    ) -> Int? {
        guard let maxTokens, maxTokens > 0 else {
            return nil
        }
        let outputReserve = max(maxOutputTokens ?? 0, compactionReserveTokenCount)
        let usableTokens = max(1, maxTokens - outputReserve)
        let adjustedMaxTokens = Double(usableTokens)
            / AgentConversationCompactionPolicy.triggerFraction
        return max(1, Int(adjustedMaxTokens.rounded(.up)))
    }

    private static func shouldCompactEstimatedContext(
        estimatedContextTokens: Int?,
        maxTokens: Int?,
        maxOutputTokens: Int?,
        messageCount: Int
    ) -> Bool {
        guard let estimatedContextTokens,
              let compactionLimit = compactionPolicyMaxTokens(
                  for: maxTokens,
                  maxOutputTokens: maxOutputTokens
              ) else {
            return false
        }
        return AgentConversationCompactionPolicy.shouldCompactHistory(
            usedTokens: estimatedContextTokens,
            maxTokens: compactionLimit,
            messageCount: messageCount
        )
    }

    private static func conversationMessageCount(in messages: [[String: Any]]) -> Int {
        if let firstRole = messages.first?["role"] as? String,
           firstRole.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "system" {
            return max(messages.count - 1, 0)
        }
        return messages.count
    }

    private static func compactionDiagnostic(
        from result: AgentConversationCompactionResult
    ) -> String {
        "Compacted conversation history from \(result.originalEstimatedTokenCount) to \(result.estimatedTokenCount) estimated tokens."
    }

    private func resolvedContextWindowTokenLimit(forLLMID modelLLMID: String) -> Int? {
        configuration.configuredContextWindowLimit
            ?? CodexAgentModel.contextWindowTokenLimit(forLLMID: modelLLMID)
    }

    private static func publishChatGPTSubscriptionMetrics(
        _ metrics: DirectAgentGenerationMetrics,
        estimatedContextTokens: Int?,
        completionTokens: Int?,
        generatedText: String,
        maxTokens: Int?,
        modelID: String,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async {
        await onEvent(.metrics(chatGPTSubscriptionVisibleMetrics(metrics)))
        await onEvent(
            .contextWindow(
                DirectAgentContextWindowStatus(
                    usedTokens: chatGPTSubscriptionContextTokenCount(
                        metrics,
                        estimatedContextTokens: estimatedContextTokens,
                        completionTokens: completionTokens,
                        generatedText: generatedText
                    ),
                    maxTokens: maxTokens,
                    modelID: modelID,
                    isApproximate: true
                )
            )
        )
    }

    nonisolated static func chatGPTSubscriptionVisibleMetrics(
        _ metrics: DirectAgentGenerationMetrics
    ) -> DirectAgentGenerationMetrics {
        DirectAgentGenerationMetrics(
            promptTokenCount: nil,
            cachedPromptTokenCount: nil,
            promptTokensPerSecond: nil,
            completionTokenCount: metrics.completionTokenCount,
            completionTokensPerSecond: metrics.completionTokensPerSecond,
            responseDurationSeconds: metrics.responseDurationSeconds,
            contextTokenCount: metrics.contextTokenCount,
            clearsPromptMetrics: true
        )
    }

    private static func chatGPTSubscriptionContextTokenCount(
        _ metrics: DirectAgentGenerationMetrics,
        estimatedContextTokens: Int?,
        completionTokens: Int?,
        generatedText: String
    ) -> Int? {
        if let contextTokenCount = metrics.contextTokenCount {
            return contextTokenCount
        }

        let generatedTokenCount = completionTokens
            ?? estimatedTokenCount(forText: generatedText)
        let estimatedTotalTokenCount = estimatedContextTokens.map {
            $0 + (generatedTokenCount ?? 0)
        }
        let reportedPromptTokenCount = metrics.promptTokenCount.map {
            $0 + (metrics.cachedPromptTokenCount ?? 0) + (generatedTokenCount ?? 0)
        }

        return [
            estimatedTotalTokenCount,
            reportedPromptTokenCount,
            estimatedContextTokens
        ]
        .compactMap { $0 }
        .max()
    }

    private static func estimatedTokenCount(forText text: String) -> Int? {
        let byteCount = text.data(using: .utf8)?.count ?? text.utf8.count
        guard byteCount > 0 else {
            return nil
        }
        return max(Int((Double(byteCount) / 4.0).rounded(.up)), 1)
    }

    private func storeSessionID(_ sessionID: String, for identity: SessionIdentity) {
        sessionIDsByIdentity[identity] = sessionID
        Self.storeSessionIDs(sessionIDsByIdentity)
    }

    private static func loadStoredSessionIDs() -> [SessionIdentity: String] {
        guard let rawValues =
            UserDefaults.standard.dictionary(forKey: sessionStoreUserDefaultsKey) as? [String: String]
        else {
            return [:]
        }

        return rawValues.reduce(into: [:]) { result, entry in
            guard let identity = SessionIdentity(storageKey: entry.key) else {
                return
            }
            result[identity] = entry.value
        }
    }

    private static func storeSessionIDs(_ values: [SessionIdentity: String]) {
        let rawValues = Dictionary(
            uniqueKeysWithValues: values.map { identity, sessionID in
                (identity.storageKey, sessionID)
            }
        )
        UserDefaults.standard.set(rawValues, forKey: sessionStoreUserDefaultsKey)
    }

    private func modelLLMID() -> String {
        CodexAgentModel.selectionID(
            forModelID: CodexAgentModel.modelID(fromLLMID: configuration.modelID)
        )
    }

    private static func chatGPTReasoningEffort(
        for selection: AgentThinkingSelection
    ) -> String? {
        switch selection {
        case .off:
            return nil
        case .enabled:
            return AgentThinkingSelection.medium.rawValue
        case .minimal:
            return AgentThinkingSelection.low.rawValue
        case .low, .medium, .high, .xhigh:
            return selection.rawValue
        }
    }

    private static func promptPayload(
        prompt: String,
        configuration: RequestConfiguration,
        attachments: [AgentRuntimeAttachment],
        includesHistory: Bool
    ) -> String {
        var sections: [String] = []
        let history = includesHistory ? renderedHistory(configuration.history) : ""
        if includesHistory,
           !history.isEmpty {
            sections.append(
                """
                Conversation so far:
                \(history)
                """
            )
        }

        let attachmentText = renderedAttachments(attachments)
        if !attachmentText.isEmpty {
            sections.append(
                """
                Attachments:
                \(attachmentText)
                """
            )
        }

        let requestSettings = renderedRequestSettings(configuration)
        if !requestSettings.isEmpty {
            sections.append(
                """
                Request settings:
                \(requestSettings)
                """
            )
        }

        sections.append(
            """
            Current request:
            \(prompt)
            """
        )
        return sections.joined(separator: "\n\n")
    }

    private static func renderedRequestSettings(
        _ configuration: RequestConfiguration
    ) -> String {
        [
            renderedThinkingSetting(configuration.thinkingSelection),
            renderedDeveloperToolSetting()
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    private static func renderedThinkingSetting(
        _ selection: AgentThinkingSelection?
    ) -> String {
        guard let selection else {
            return ""
        }

        switch selection {
        case .off:
            return "- Thinking: off. Answer directly and avoid extra deliberation."
        case .enabled:
            return "- Thinking: on."
        case .minimal:
            return "- Thinking effort: minimal."
        case .low:
            return "- Thinking effort: low."
        case .medium:
            return "- Thinking effort: medium."
        case .high:
            return "- Thinking effort: high."
        case .xhigh:
            return "- Thinking effort: xhigh."
        }
    }

    private static func renderedDeveloperToolSetting() -> String {
        "- Xcode projects: `xcodebuild` is allowed. When building from the macOS app sandbox, keep build products inside the workspace, for example with `-derivedDataPath .mlx-coder/DerivedData`. If Xcode reports that its license has not been accepted, stop and report that host setup issue."
    }

    private static func renderedHistory(
        _ history: [AgentRuntimeMessage]
    ) -> String {
        history
            .suffix(12)
            .map { message in
                let role = message.role.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else {
                    return ""
                }
                return "\(role.capitalized): \(content)"
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private static func renderedAttachments(
        _ attachments: [AgentRuntimeAttachment]
    ) -> String {
        attachments.map { attachment in
            if let fileURL = attachment.fileURL {
                return "- \(attachment.originalFilename): \(fileURL.path)"
            }
            return "- \(attachment.originalFilename): embedded \(attachment.kind.rawValue)"
        }
        .joined(separator: "\n")
    }

    private static func sessionID(from object: [String: Any]) -> String? {
        let normalizedType = (object["type"] as? String)
            .map(normalizedEventType) ?? ""
        let directKeys = [
            "session_id",
            "sessionId",
            "thread_id",
            "threadId",
            "conversation_id",
            "conversationId"
        ]

        for key in directKeys {
            if let value = normalizedSessionID(object[key]) {
                return value
            }
        }

        if [
            "thread_started",
            "session_configured",
            "session_started",
            "conversation_started"
        ].contains(normalizedType),
           let value = normalizedSessionID(object["id"]) {
            return value
        }

        for key in ["session", "thread", "conversation"] {
            guard let nested = object[key] as? [String: Any] else {
                continue
            }
            for nestedKey in directKeys + ["id"] {
                if let value = normalizedSessionID(nested[nestedKey]) {
                    return value
                }
            }
        }

        return nil
    }

    private static func normalizedSessionID(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func responseID(from object: [String: Any]) -> String? {
        if let response = object["response"] as? [String: Any] {
            for key in ["response_id", "responseId", "id"] {
                if let value = normalizedSessionID(response[key]) {
                    return value
                }
            }
        }

        for key in ["response_id", "responseId"] {
            if let value = normalizedSessionID(object[key]) {
                return value
            }
        }

        let normalizedType = (object["type"] as? String)
            .map(normalizedEventType) ?? ""
        if normalizedType == "response_created"
            || normalizedType == "response_in_progress"
            || normalizedType == "response_completed"
            || normalizedType == "response_done"
            || normalizedType == "response_incomplete" {
            return normalizedSessionID(object["id"])
        }

        return nil
    }

    private static func events(
        from object: [String: Any],
        modelLLMID: String
    ) -> [ChatGPTSubscriptionStreamEvent] {
        guard let type = object["type"] as? String else {
            return []
        }
        let normalizedType = normalizedEventType(type)

        switch normalizedType {
        case "thread_started",
             "session_configured":
            return []
        case "turn_started",
             "task_started":
            return []
        case "turn_completed",
             "turn_complete",
             "task_complete":
            var events: [ChatGPTSubscriptionStreamEvent] = []
            if let contextWindowStatus = contextWindowStatus(
                from: usageObject(from: object),
                modelLLMID: modelLLMID
            ) {
                events.append(.contextWindow(contextWindowStatus))
            }
            events.append(.completed(stopReason: "completed"))
            return events
        case "token_count":
            return contextWindowStatus(
                from: usageObject(from: object) ?? object,
                modelLLMID: modelLLMID
            ).map { [.contextWindow($0)] } ?? []
        case "agent_message_content_delta":
            return stringValue(for: ["delta", "text", "content"], in: object)
                .map { [.content($0)] } ?? []
        case "agent_reasoning",
             "agent_reasoning_raw_content",
             "agent_reasoning_section_break",
             "reasoning_content_delta",
             "reasoning_raw_content_delta",
             "reasoning_summary_delta",
             "reasoning_summary_part_added":
            return reasoningText(from: object)
            .map { [.thought($0)] } ?? []
        case "item_started":
            guard let item = object["item"] as? [String: Any],
                  let update = toolCallUpdate(from: item, status: "in_progress") else {
                return []
            }
            return [.toolCall(update)]
        case "item_completed":
            guard let item = object["item"] as? [String: Any] else {
                return []
            }
            return completedItemEvents(from: item)
        case "raw_response_item":
            guard let item = object["item"] as? [String: Any] else {
                return []
            }
            return completedItemEvents(from: item)
        default:
            return []
        }
    }

    private static func responseErrorMessage(from object: [String: Any]) -> String? {
        let normalizedType = (object["type"] as? String)
            .map(normalizedEventType) ?? ""
        if normalizedType == "error" {
            return errorMessage(from: object["error"])
                ?? textContent(from: object["message"])
                ?? textContent(from: object["detail"])
                ?? "ChatGPT Subscription request failed."
        }

        guard let response = object["response"] as? [String: Any] else {
            return nil
        }
        let status = (response["status"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedType == "response_failed" || status == "failed" else {
            return nil
        }
        return errorMessage(from: response["error"])
            ?? textContent(from: response["message"])
            ?? "ChatGPT Subscription request failed."
    }

    private static func errorMessage(from value: Any?) -> String? {
        if let text = textContent(from: value) {
            return text
        }
        guard let object = value as? [String: Any] else {
            return nil
        }
        return stringValue(
            for: ["message", "detail", "code", "type"],
            in: object
        )
    }

    private static func responseContentDelta(from object: [String: Any]) -> String? {
        textContent(from: object["delta"])
            ?? textContent(from: object["text"])
            ?? textContent(from: object["content"])
    }

    private static func responseReasoningDelta(from object: [String: Any]) -> String? {
        reasoningText(from: object)
    }

    private static func completedResponseText(from object: [String: Any]) -> String? {
        if let text = textContent(from: object["output_text"]) {
            return text
        }

        let response = object["response"] as? [String: Any] ?? object
        if let text = textContent(from: response["output_text"]) {
            return text
        }

        guard let output = response["output"] as? [Any] else {
            return nil
        }
        let text = output
            .compactMap { item -> String? in
                guard let item = item as? [String: Any] else {
                    return textContent(from: item)
                }
                if let content = item["content"] as? [Any] {
                    return content
                        .compactMap(textContent)
                        .joined(separator: "")
                        .nilIfBlank
                }
                return textContent(from: item["text"])
                    ?? textContent(from: item["content"])
            }
            .joined(separator: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.nilIfBlank
    }

    private static func responseUsageObject(from object: [String: Any]) -> [String: Any]? {
        usageObject(from: object)
            ?? (object["response"] as? [String: Any]).flatMap(usageObject(from:))
    }

    private static func normalizedEventType(_ type: String) -> String {
        type.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
    }

    private static func usageObject(from object: [String: Any]) -> [String: Any]? {
        for key in ["usage", "token_usage", "tokenUsage", "tokens"] {
            if let usage = object[key] as? [String: Any] {
                return usage
            }
        }
        return nil
    }

    private static func reasoningText(from object: [String: Any]) -> String? {
        stringValue(
            for: [
                "delta",
                "text",
                "summary_text",
                "summaryText",
                "raw_content",
                "rawContent",
                "reasoning_text",
                "reasoningText",
                "content",
                "summary"
            ],
            in: object
        )
        ?? (object["item"] as? [String: Any]).flatMap {
            stringValue(
                for: [
                    "delta",
                    "text",
                    "summary_text",
                    "summaryText",
                    "raw_content",
                    "rawContent",
                    "reasoning_text",
                    "reasoningText",
                    "content",
                    "summary"
                ],
                in: $0
            )
        }
    }

    private static func completedItemEvents(from item: [String: Any]) -> [ChatGPTSubscriptionStreamEvent] {
        let itemType = (item["type"] as? String ?? "").lowercased()
        let text = stringValue(
            for: [
                "text",
                "content",
                "summary",
                "summary_text",
                "summaryText",
                "raw_content",
                "rawContent",
                "reasoning_text",
                "reasoningText"
            ],
            in: item
        )

        if itemType == "agent_message" || itemType == "message" {
            return text.map { [.content($0)] } ?? []
        }
        if itemType.contains("reasoning") || itemType.contains("thought") {
            return text.map { [.thought($0)] } ?? []
        }
        if let update = toolCallUpdate(from: item, status: "completed") {
            return [.toolCall(update)]
        }
        return []
    }

    private static func toolCallUpdate(
        from item: [String: Any],
        status: String
    ) -> ChatGPTSubscriptionToolCallUpdate? {
        let itemType = (item["type"] as? String ?? "").lowercased()
        guard itemType != "agent_message",
              itemType != "message",
              !itemType.contains("reasoning"),
              !itemType.contains("thought") else {
            return nil
        }

        let id = (item["id"] as? String)?.nilIfBlank ?? UUID().uuidString
        let title = stringValue(for: ["title", "name", "command"], in: item)
            ?? displayTitle(forItemType: itemType)
        let rawInput = compactJSONString(from: item["input"] ?? item["arguments"] ?? item)
        let output = stringValue(for: ["output", "result", "text", "content"], in: item)
        return ChatGPTSubscriptionToolCallUpdate(
            id: id,
            title: title,
            status: status,
            rawInput: rawInput,
            output: output
        )
    }

    private static func directToolCall(
        from update: ChatGPTSubscriptionToolCallUpdate
    ) -> DirectAgentToolCall {
        let argumentsObject = argumentsObject(from: update.rawInput)
        return DirectAgentToolCall(
            id: update.id,
            name: update.title,
            argumentsObject: argumentsObject,
            argumentsJSON: update.rawInput ?? "{}"
        )
    }

    private static func argumentsObject(from rawInput: String?) -> [String: Any] {
        guard let rawInput = rawInput?.nilIfBlank,
              let data = rawInput.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.mlxObjectValue else {
            return [:]
        }
        return object.mapValues(\.jsonObject)
    }

    private static func contextWindowStatus(
        from usage: [String: Any]?,
        modelLLMID: String
    ) -> DirectAgentContextWindowStatus? {
        guard let usage else {
            return nil
        }
        let inputTokens = boundedCodexTokenCount(
            totalInputTokenCount(from: usage),
            modelLLMID: modelLLMID
        )
        guard let inputTokens,
              let maxTokens = CodexAgentModel.contextWindowTokenLimit(forLLMID: modelLLMID) else {
            return nil
        }

        return DirectAgentContextWindowStatus(
            usedTokens: inputTokens,
            maxTokens: maxTokens,
            modelID: modelLLMID,
            isApproximate: true
        )
    }

    private static func totalInputTokenCount(from usage: [String: Any]) -> Int? {
        if let totalInputTokens = intValue(
            for: ["prompt_tokens", "total_input_tokens", "promptTokens", "totalInputTokens"],
            in: usage
        ) {
            return totalInputTokens
        }

        let inputTokens = intValue(
            for: ["input_tokens", "inputTokens"],
            in: usage
        )
        let cacheReadInputTokens = intValue(
            for: ["cache_read_input_tokens", "cacheReadInputTokens"],
            in: usage
        )
        let cacheCreationInputTokens = intValue(
            for: ["cache_creation_input_tokens", "cacheCreationInputTokens"],
            in: usage
        )

        if cacheReadInputTokens != nil || cacheCreationInputTokens != nil,
           let inputTokens {
            return inputTokens
                + (cacheReadInputTokens ?? 0)
                + (cacheCreationInputTokens ?? 0)
        }
        return inputTokens
    }

    private static func boundedCodexTokenCount(
        _ value: Int?,
        modelLLMID: String
    ) -> Int? {
        guard let value, value >= 0 else {
            return nil
        }
        guard let maxTokens = CodexAgentModel.contextWindowTokenLimit(forLLMID: modelLLMID),
              value <= maxTokens else {
            return nil
        }
        return value
    }

    private static func stringValue(
        for keys: [String],
        in object: [String: Any]
    ) -> String? {
        for key in keys {
            if let normalizedValue = textContent(from: object[key]) {
                return normalizedValue
            }
        }
        return nil
    }

    private static func textContent(from value: Any?) -> String? {
        if let value = value as? String {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedValue.isEmpty ? nil : value
        }
        if let values = value as? [Any] {
            let text = values
                .compactMap(textContent)
                .joined(separator: "\n")
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedText.isEmpty ? nil : text
        }
        if let object = value as? [String: Any] {
            return stringValue(
                for: [
                    "text",
                    "summary_text",
                    "raw_content",
                    "reasoning_text",
                    "content",
                    "delta",
                    "summary"
                ],
                in: object
            )
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        JSONValue(jsonObject: value).intValue
    }

    private static func intValue(
        for keys: [String],
        in object: [String: Any]
    ) -> Int? {
        for key in keys {
            if let value = intValue(object[key]) {
                return value
            }
        }
        return nil
    }

    private static func compactJSONString(from value: Any?) -> String? {
        guard let value else {
            return nil
        }
        return JSONValue(jsonObject: value).compactString(sortedKeys: true)
    }

    private static func displayTitle(forItemType itemType: String) -> String {
        if itemType.isEmpty {
            return "ChatGPT action"
        }
        return itemType
            .split(separator: "_")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    private static func appendAssistantMessage(
        text: String,
        reasoningText: String,
        toolCalls: [DirectAgentToolCall],
        to messages: inout [[String: Any]]
    ) {
        var message: [String: Any] = [
            "role": "assistant",
            "content": text
        ]
        if let reasoningText = reasoningText.nilIfBlank {
            message["reasoning_content"] = reasoningText
        }
        if !toolCalls.isEmpty {
            message["tool_calls"] = toolCalls.map { toolCall in
                [
                    "id": toolCall.id,
                    "type": "function",
                    "function": [
                        "name": toolCall.name,
                        "arguments": toolCall.argumentsJSON
                    ]
                ] as [String: Any]
            }
        }

        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasReasoning = reasoningText.nilIfBlank != nil
        if hasContent || hasReasoning || !toolCalls.isEmpty {
            messages.append(message)
        }
    }

}

public struct ChatGPTSubscriptionResponsesClient {
    public struct StreamCompletion: Sendable {
        public let responseID: String?
    }

    fileprivate struct WebSocketLease {
        let sessionID: String
        let task: URLSessionWebSocketTask
        let isCached: Bool
        let isReused: Bool
    }

    private struct WebSocketFailure: Error {
        let underlying: Error
        let didEmitEvents: Bool
    }

    private struct WebSocketIdleTimeoutError: LocalizedError {
        let timeoutNanoseconds: UInt64

        var errorDescription: String? {
            let seconds = timeoutNanoseconds / 1_000_000_000
            return "WebSocket idle timeout after \(seconds)s"
        }
    }

    public let credentials: CodexAgentCredentials
    public let baseURL: URL
    public let urlSession: URLSession
    public let webSocketPool: ChatGPTSubscriptionWebSocketPool

    private static let maxRetries = 3
    private static let baseRetryDelayNanoseconds: UInt64 = 1_000_000_000
    private static let webSocketBetaHeader = "responses_websockets=2026-02-06"
    static let webSocketIdleTimeoutNanoseconds: UInt64? = nil

    public init(
        credentials: CodexAgentCredentials,
        baseURL: URL = URL(string: "https://chatgpt.com/backend-api")!,
        urlSession: URLSession = .shared,
        webSocketPool: ChatGPTSubscriptionWebSocketPool = ChatGPTSubscriptionWebSocketPool()
    ) {
        self.credentials = credentials
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.webSocketPool = webSocketPool
    }

    public func streamEvents(
        input: JSONValue,
        model: String,
        instructions: String,
        reasoningEffort: String?,
        textVerbosity: String,
        sessionID: String,
        cachedWebSocketInput: JSONValue? = nil,
        previousResponseID: String? = nil,
        toolPayloads: JSONValue = .array([]),
        maxOutputTokens: Int? = nil,
        onEvent: ([String: Any]) async throws -> Void
    ) async throws -> StreamCompletion {
        let body = ChatGPTSubscriptionRequestBuilder.requestBody(
            input: input,
            model: model,
            instructions: instructions,
            reasoningEffort: reasoningEffort,
            textVerbosity: textVerbosity,
            sessionID: sessionID,
            toolPayloads: toolPayloads,
            maxOutputTokens: maxOutputTokens
        )

        if !webSocketPool.isFallbackToSSEActive(sessionID: sessionID) {
            do {
                return try await streamEventsOverWebSocket(
                    body: body,
                    cachedInput: cachedWebSocketInput,
                    previousResponseID: previousResponseID,
                    sessionID: sessionID,
                    onEvent: onEvent
                )
            } catch is CancellationError {
                throw ChatGPTSubscriptionGenerationError.cancelled
            } catch let error as WebSocketFailure {
                if error.didEmitEvents {
                    throw error.underlying
                }
                webSocketPool.activateSSEFallback(sessionID: sessionID)
            }
        }

        for attempt in 0...Self.maxRetries {
            try Task.checkCancellation()

            do {
                let request = try request(for: body, sessionID: sessionID)
                let (bytes, response) = try await urlSession.bytes(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw ChatGPTSubscriptionGenerationError.invalidResponse
                }
                guard (200..<300).contains(httpResponse.statusCode) else {
                    let output = try await Self.collectErrorBody(from: bytes)
                    if attempt < Self.maxRetries,
                       Self.isRetryable(status: httpResponse.statusCode, output: output) {
                        try await Self.sleepForRetry(attempt: attempt)
                        continue
                    }
                    throw ChatGPTSubscriptionGenerationError.http(
                        status: httpResponse.statusCode,
                        output: output
                    )
                }

                var eventName: String?
                var dataLines: [String] = []
                var responseID: String?

                func flushEvent() async throws {
                    guard !dataLines.isEmpty else {
                        eventName = nil
                        return
                    }
                    defer {
                        eventName = nil
                        dataLines.removeAll(keepingCapacity: true)
                    }

                    let payload = dataLines.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !payload.isEmpty, payload != "[DONE]" else {
                        return
                    }
                    guard let data = payload.data(using: .utf8) else {
                        return
                    }

                    let objects = try Self.decodedJSONObjectSequence(from: data)
                    guard !objects.isEmpty else {
                        return
                    }

                    for var object in objects {
                        if object["type"] == nil,
                           let eventName {
                            object["type"] = eventName
                        }
                        if responseID == nil {
                            responseID = ChatGPTSubscriptionGenerationClient.responseID(from: object)
                        }
                        try await onEvent(object)
                    }
                }

                for try await rawLine in bytes.lines {
                    try Task.checkCancellation()
                    let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                    if line.isEmpty {
                        try await flushEvent()
                        continue
                    }
                    guard !line.hasPrefix(":") else {
                        continue
                    }
                    if line.hasPrefix("event:") {
                        eventName = String(line.dropFirst("event:".count))
                            .trimmingCharacters(in: .whitespaces)
                        continue
                    }
                    if line.hasPrefix("data:") {
                        dataLines.append(
                            String(line.dropFirst("data:".count))
                                .trimmingCharacters(in: .whitespaces)
                        )
                    }
                }
                try await flushEvent()
                return StreamCompletion(responseID: responseID)
            } catch is CancellationError {
                throw ChatGPTSubscriptionGenerationError.cancelled
            } catch let error as ChatGPTSubscriptionGenerationError {
                throw error
            } catch {
                if attempt < Self.maxRetries, Self.isRetryable(error: error) {
                    try await Self.sleepForRetry(attempt: attempt)
                    continue
                }
                throw error
            }
        }

        throw ChatGPTSubscriptionGenerationError.invalidResponse
    }

    private func streamEventsOverWebSocket(
        body: [String: Any],
        cachedInput: JSONValue?,
        previousResponseID: String?,
        sessionID: String,
        onEvent: ([String: Any]) async throws -> Void
    ) async throws -> StreamCompletion {
        let request = webSocketRequest(sessionID: sessionID)
        let lease = webSocketPool.acquire(
            sessionID: sessionID,
            request: request,
            urlSession: urlSession
        )
        var keepConnection = false
        var didEmitEvents = false
        var responseID: String?
        var didReceiveTerminalEvent = false

        defer {
            webSocketPool.release(
                lease,
                keepAlive: keepConnection && didReceiveTerminalEvent
            )
        }

        do {
            let payload = try JSONValue(
                jsonObject: Self.webSocketRequestPayload(
                    body: body,
                    cachedInput: cachedInput,
                    previousResponseID: previousResponseID,
                    useCachedContinuation: lease.isReused
                )
            ).jsonData(
                outputFormatting: [.withoutEscapingSlashes]
            )
            guard let text = String(data: payload, encoding: .utf8) else {
                throw ChatGPTSubscriptionGenerationError.invalidResponse
            }
            try await lease.task.send(
                URLSessionWebSocketTask.Message.string(text)
            )

            while !didReceiveTerminalEvent {
                try Task.checkCancellation()
                let message = try await Self.receiveWebSocketMessage(
                    from: lease.task,
                    timeoutNanoseconds: Self.webSocketIdleTimeoutNanoseconds
                )
                guard let data = Self.webSocketData(from: message) else {
                    continue
                }
                let objects = try Self.decodedJSONObjectSequence(from: data)
                for object in objects {
                    if responseID == nil {
                        responseID = ChatGPTSubscriptionGenerationClient.responseID(from: object)
                    }
                    didEmitEvents = true
                    try await onEvent(object)
                    if Self.isTerminalEvent(object) {
                        didReceiveTerminalEvent = true
                    }
                }
            }

            keepConnection = true
            return StreamCompletion(responseID: responseID)
        } catch is CancellationError {
            throw ChatGPTSubscriptionGenerationError.cancelled
        } catch {
            throw WebSocketFailure(
                underlying: error,
                didEmitEvents: didEmitEvents
            )
        }
    }

    private static func receiveWebSocketMessage(
        from task: URLSessionWebSocketTask,
        timeoutNanoseconds: UInt64?
    ) async throws -> URLSessionWebSocketTask.Message {
        guard let timeoutNanoseconds, timeoutNanoseconds > 0 else {
            return try await task.receive()
        }
        return try await withThrowingTaskGroup(
            of: URLSessionWebSocketTask.Message.self
        ) { group in
            group.addTask {
                try await task.receive()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                task.cancel(with: .normalClosure, reason: nil)
                throw WebSocketIdleTimeoutError(
                    timeoutNanoseconds: timeoutNanoseconds
                )
            }

            do {
                guard let message = try await group.next() else {
                    throw ChatGPTSubscriptionGenerationError.invalidResponse
                }
                group.cancelAll()
                return message
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func request(
        for body: [String: Any],
        sessionID: String
    ) throws -> URLRequest {
        var request = URLRequest(url: Self.codexResponsesURL(baseURL: baseURL))
        request.httpMethod = "POST"
        request.httpBody = try JSONValue(jsonObject: body).jsonData(
            outputFormatting: [.withoutEscapingSlashes]
        )
        request.timeoutInterval = 600
        request.setValue(
            "Bearer \(credentials.accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            credentials.accountID,
            forHTTPHeaderField: "chatgpt-account-id"
        )
        request.setValue("mlx-coder", forHTTPHeaderField: "originator")
        request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(sessionID, forHTTPHeaderField: "session_id")
        request.setValue(sessionID, forHTTPHeaderField: "x-client-request-id")
        return request
    }

    private func webSocketRequest(sessionID: String) -> URLRequest {
        var request = URLRequest(url: Self.codexWebSocketURL(baseURL: baseURL))
        request.timeoutInterval = 600
        request.setValue(
            "Bearer \(credentials.accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            credentials.accountID,
            forHTTPHeaderField: "chatgpt-account-id"
        )
        request.setValue("mlx-coder", forHTTPHeaderField: "originator")
        request.setValue(
            Self.webSocketBetaHeader,
            forHTTPHeaderField: "OpenAI-Beta"
        )
        request.setValue(sessionID, forHTTPHeaderField: "session_id")
        request.setValue(sessionID, forHTTPHeaderField: "x-client-request-id")
        return request
    }

    private static func isRetryable(
        status: Int,
        output: String
    ) -> Bool {
        if [429, 500, 502, 503, 504].contains(status) {
            return true
        }
        let normalizedOutput = output.lowercased()
        return normalizedOutput.contains("rate limit")
            || normalizedOutput.contains("overloaded")
            || normalizedOutput.contains("service unavailable")
            || normalizedOutput.contains("upstream connect")
            || normalizedOutput.contains("connection refused")
    }

    private static func isRetryable(error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .networkConnectionLost,
                 .dnsLookupFailed,
                 .notConnectedToInternet,
                 .resourceUnavailable:
                return true
            default:
                return false
            }
        }
        return false
    }

    private static func sleepForRetry(attempt: Int) async throws {
        let multiplier = UInt64(max(1, 1 << attempt))
        try await Task.sleep(
            nanoseconds: baseRetryDelayNanoseconds * multiplier
        )
    }

    private static func codexResponsesURL(baseURL: URL) -> URL {
        var value = baseURL.absoluteString
        while value.hasSuffix("/") {
            value.removeLast()
        }
        if value.hasSuffix("/codex/responses") {
            return URL(string: value)!
        }
        if value.hasSuffix("/codex") {
            return URL(string: "\(value)/responses")!
        }
        return URL(string: "\(value)/codex/responses")!
    }

    public static func codexWebSocketURL(baseURL: URL) -> URL {
        guard var components = URLComponents(
            url: codexResponsesURL(baseURL: baseURL),
            resolvingAgainstBaseURL: false
        ) else {
            return codexResponsesURL(baseURL: baseURL)
        }

        switch components.scheme?.lowercased() {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        default:
            break
        }
        return components.url ?? codexResponsesURL(baseURL: baseURL)
    }

    static func webSocketRequestPayload(
        body: [String: Any],
        cachedInput: JSONValue? = nil,
        previousResponseID: String? = nil,
        useCachedContinuation: Bool = false
    ) -> [String: Any] {
        var payload = body
        if useCachedContinuation,
           let previousResponseID = previousResponseID?.nilIfBlank,
           let cachedInput {
            payload["previous_response_id"] = previousResponseID
            payload["input"] = cachedInput.acpJSONObject
        }
        payload["type"] = "response.create"
        return payload
    }

    private static func collectErrorBody(
        from bytes: URLSession.AsyncBytes,
        limit: Int = 64 * 1024
    ) async throws -> String {
        var data = Data()
        for try await byte in bytes {
            if data.count < limit {
                data.append(byte)
            }
        }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodedJSONObjectSequence(from data: Data) throws -> [[String: Any]] {
        if isDoneMarker(data) {
            return []
        }

        if let value = try? JSONDecoder().decode(JSONValue.self, from: data),
           let jsonObject = value.mlxObjectValue {
            return [jsonObject.mapValues(\.jsonObject)]
        }

        var buffer = data
        var objects: [[String: Any]] = []

        while true {
            trimLeadingWhitespaceAndNewlines(from: &buffer)
            if buffer.isEmpty || isDoneMarker(buffer) {
                break
            }

            guard let nextObjectData = extractNextJSONObject(from: &buffer) else {
                break
            }
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: nextObjectData),
                  let jsonObject = value.mlxObjectValue else {
                continue
            }
            objects.append(jsonObject.mapValues(\.jsonObject))
        }

        if objects.isEmpty {
            _ = try JSONDecoder().decode(JSONValue.self, from: data)
        }
        return objects
    }

    private static func extractNextJSONObject(from buffer: inout Data) -> Data? {
        trimLeadingWhitespaceAndNewlines(from: &buffer)
        guard !buffer.isEmpty else {
            return nil
        }

        var index = buffer.startIndex
        var startIndex: Data.Index?
        var braceDepth = 0
        var bracketDepth = 0
        var inString = false
        var isEscaped = false

        while index < buffer.endIndex {
            let byte = buffer[index]

            if startIndex == nil {
                if byte == 0x7B || byte == 0x5B {
                    startIndex = index
                    if byte == 0x7B {
                        braceDepth = 1
                    } else {
                        bracketDepth = 1
                    }
                }
                index = buffer.index(after: index)
                continue
            }

            if inString {
                if isEscaped {
                    isEscaped = false
                } else if byte == 0x5C {
                    isEscaped = true
                } else if byte == 0x22 {
                    inString = false
                }
            } else {
                switch byte {
                case 0x22:
                    inString = true
                case 0x7B:
                    braceDepth += 1
                case 0x7D:
                    braceDepth -= 1
                case 0x5B:
                    bracketDepth += 1
                case 0x5D:
                    bracketDepth -= 1
                default:
                    break
                }

                if braceDepth == 0,
                   bracketDepth == 0,
                   let startIndex {
                    let endIndex = buffer.index(after: index)
                    let objectData = buffer.subdata(in: startIndex ..< endIndex)
                    buffer.removeSubrange(buffer.startIndex ..< endIndex)
                    return objectData
                }
            }

            index = buffer.index(after: index)
        }

        return nil
    }

    private static func trimLeadingWhitespaceAndNewlines(from buffer: inout Data) {
        while let firstByte = buffer.first,
              firstByte == 0x20 || firstByte == 0x09 || firstByte == 0x0A || firstByte == 0x0D {
            buffer.removeFirst()
        }
    }

    private static func isDoneMarker(_ data: Data) -> Bool {
        guard let payload = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return payload == "[DONE]"
    }

    private static func webSocketData(
        from message: URLSessionWebSocketTask.Message
    ) -> Data? {
        switch message {
        case let .data(data):
            return data
        case let .string(text):
            return text.data(using: .utf8)
        @unknown default:
            return nil
        }
    }

    private static func isTerminalEvent(_ object: [String: Any]) -> Bool {
        let normalizedType = (object["type"] as? String)
            .map(normalizedEventType) ?? ""
        if [
            "response_completed",
            "response_done",
            "response_incomplete",
            "response_failed"
        ].contains(normalizedType) {
            return true
        }

        guard let response = object["response"] as? [String: Any],
              let status = (response["status"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() else {
            return false
        }

        return [
            "completed",
            "incomplete",
            "failed",
            "cancelled"
        ].contains(status)
    }

    private static func normalizedEventType(_ type: String) -> String {
        type.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
    }
}

public final class ChatGPTSubscriptionWebSocketPool: @unchecked Sendable {
    private struct Entry {
        let task: URLSessionWebSocketTask
        var lastUsedAt: Date
        var isBusy: Bool
    }

    private let idleTTL: TimeInterval = 5 * 60
    private let lock = OSAllocatedUnfairLock()
    private var entries: [String: Entry] = [:]
    private var sseFallbackSessionIDs: Set<String> = []

    public init() {}

    public func isFallbackToSSEActive(sessionID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sseFallbackSessionIDs.contains(sessionID)
    }

    public func activateSSEFallback(sessionID: String) {
        lock.lock()
        sseFallbackSessionIDs.insert(sessionID)
        let entry = entries.removeValue(forKey: sessionID)
        lock.unlock()
        if let entry {
            Self.close(entry.task)
        }
    }

    fileprivate func acquire(
        sessionID: String,
        request: URLRequest,
        urlSession: URLSession
    ) -> ChatGPTSubscriptionResponsesClient.WebSocketLease {
        lock.lock()
        defer { lock.unlock() }

        if let existing = entries[sessionID],
           !existing.isBusy,
           Self.isReusable(existing.task),
           Date().timeIntervalSince(existing.lastUsedAt) < idleTTL {
            var updated = existing
            updated.lastUsedAt = Date()
            updated.isBusy = true
            entries[sessionID] = updated
            return ChatGPTSubscriptionResponsesClient.WebSocketLease(
                sessionID: sessionID,
                task: existing.task,
                isCached: true,
                isReused: true
            )
        }

        if let existing = entries.removeValue(forKey: sessionID) {
            let task = existing.task
            DispatchQueue.global().async {
                Self.close(task)
            }
        }

        let task = urlSession.webSocketTask(with: request)
        task.resume()
        entries[sessionID] = Entry(
            task: task,
            lastUsedAt: Date(),
            isBusy: true
        )
        return ChatGPTSubscriptionResponsesClient.WebSocketLease(
            sessionID: sessionID,
            task: task,
            isCached: true,
            isReused: false
        )
    }

    fileprivate func release(
        _ lease: ChatGPTSubscriptionResponsesClient.WebSocketLease,
        keepAlive: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }

        if keepAlive,
           lease.isCached,
           var entry = entries[lease.sessionID],
           entry.task === lease.task,
           Self.isReusable(entry.task) {
            entry.lastUsedAt = Date()
            entry.isBusy = false
            entries[lease.sessionID] = entry
            return
        }

        if lease.isCached,
           let entry = entries[lease.sessionID],
           entry.task === lease.task {
            entries.removeValue(forKey: lease.sessionID)
        }
        Self.close(lease.task)
    }

    public func closeSession(sessionID: String) {
        lock.lock()
        sseFallbackSessionIDs.remove(sessionID)
        let entry = entries.removeValue(forKey: sessionID)
        lock.unlock()
        if let entry {
            Self.close(entry.task)
        }
    }

    public func closeAll() {
        lock.lock()
        let openTasks = entries.values.map(\.task)
        entries.removeAll()
        sseFallbackSessionIDs.removeAll()
        lock.unlock()

        for task in openTasks {
            Self.close(task)
        }
    }

    private static func isReusable(
        _ task: URLSessionWebSocketTask
    ) -> Bool {
        task.closeCode == .invalid
    }

    private static func close(
        _ task: URLSessionWebSocketTask
    ) {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

private enum ChatGPTSubscriptionGenerationError: LocalizedError {
    case missingSession
    case cancelled
    case invalidResponse
    case http(status: Int, output: String)
    case responseFailed(String)
    case tooManyToolRounds(Int)

    var errorDescription: String? {
        switch self {
        case .missingSession:
            return "The ChatGPT Subscription agent session is missing."
        case .cancelled:
            return "The ChatGPT Subscription request was cancelled."
        case .invalidResponse:
            return "ChatGPT Subscription returned an invalid response."
        case let .http(status, output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "ChatGPT Subscription request failed with HTTP \(status)."
            }
            return "ChatGPT Subscription request failed with HTTP \(status): \(detail)"
        case let .responseFailed(message):
            return message
        case let .tooManyToolRounds(limit):
            return "The ChatGPT Subscription model requested tools for \(limit) rounds without finishing."
        }
    }
}
#endif
