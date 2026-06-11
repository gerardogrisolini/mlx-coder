//
//  AnthropicSubscriptionGenerationClient.swift
//  MLXCoder
//
//  Created by Codex on 10/06/26.
//

#if os(macOS)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AnthropicSubscriptionRequestBuilder {
    public static func estimatedContextTokenCount(
        system: [[String: Any]],
        messages: [[String: Any]],
        tools: [[String: Any]]
    ) -> Int? {
        var payload: [String: Any] = [:]
        if !system.isEmpty {
            payload["system"] = system
        }
        if !messages.isEmpty {
            payload["messages"] = messages
        }
        if !tools.isEmpty {
            payload["tools"] = tools
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

    public static func usage(
        from value: Any?,
        previous: RemoteGenerationUsage? = nil
    ) -> RemoteGenerationUsage? {
        guard let object = value as? [String: Any],
              let parsed = RemoteGenerationClient.parsedUsage(from: object) else {
            return previous
        }
        return mergedUsage(parsed, previous: previous)
    }

    private static func mergedUsage(
        _ usage: RemoteGenerationUsage,
        previous: RemoteGenerationUsage?
    ) -> RemoteGenerationUsage {
        let promptTokens = usage.promptTokens ?? previous?.promptTokens
        let completionTokens = usage.completionTokens ?? previous?.completionTokens
        let computedTotalTokens = sum(promptTokens, completionTokens)

        return RemoteGenerationUsage(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: usage.totalTokens
                ?? computedTotalTokens
                ?? previous?.totalTokens,
            contextTokens: usage.contextTokens
                ?? computedTotalTokens
                ?? previous?.contextTokens,
            processedPromptTokens: usage.processedPromptTokens
                ?? previous?.processedPromptTokens,
            cachedPromptTokens: usage.cachedPromptTokens
                ?? previous?.cachedPromptTokens,
            promptTokensPerSecond: usage.promptTokensPerSecond
                ?? previous?.promptTokensPerSecond,
            completionTokensPerSecond: usage.completionTokensPerSecond
                ?? previous?.completionTokensPerSecond,
            responseDurationSeconds: usage.responseDurationSeconds
                ?? previous?.responseDurationSeconds
        )
    }

    private static func sum(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return lhs + rhs
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        default:
            return nil
        }
    }
}

public actor AnthropicSubscriptionGenerationClient: AgentRuntimeBackend {
    public struct AgentSession {
        public let id: String
        public let cwd: URL
        public var systemPrompt: String?
        public let cacheKey: String?
        public var allowedToolNames: Set<String>?
        public var thinkingSelection: AgentThinkingSelection?
        public var preserveThinking: Bool
        public var messages: [[String: Any]]
    }

    public static var isAvailable: Bool {
        AnthropicSubscriptionModel.isReady
    }

    private static let apiBaseURL = URL(string: "https://api.anthropic.com/v1")!
    private static let claudeCodeVersion = "2.1.75"
    private static let claudeCodeBetaHeader = "claude-code-20250219"
    private static let oauthBetaHeader = "oauth-2025-04-20"
    private static let interleavedThinkingBetaHeader = "interleaved-thinking-2025-05-14"
    private static let minimumOutputTokensForThinking = 1_024

    public let configuration: AgentRuntimeConfiguration
    public let provider: AgentRemoteProvider
    public let urlSession: URLSession
    public let toolExecutor: DirectToolExecutor
    public var sessions: [String: AgentSession] = [:]

    public init(
        configuration: AgentRuntimeConfiguration,
        provider: AgentRemoteProvider,
        urlSession: URLSession? = nil,
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime()
    ) {
        self.configuration = configuration
        self.provider = provider
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
                AnthropicSubscriptionGenerationClient(
                    configuration: configuration,
                    provider: provider,
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
        let cwdURL = URL(fileURLWithPath: cwd).standardizedFileURL
        sessions[id] = AgentSession(
            id: id,
            cwd: cwdURL,
            systemPrompt: systemPrompt,
            cacheKey: cacheKey,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking,
            messages: RemoteGenerationClient.initialMessages(
                cwd: cwdURL.path,
                systemPrompt: systemPrompt,
                history: history,
                allowedToolNames: allowedToolNames
            )
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

    public func closeSession(id: String) {
        sessions.removeValue(forKey: id)
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
        session.messages = RemoteGenerationClient.replacingSystemPrompt(
            in: session.messages,
            cwd: session.cwd.path,
            systemPrompt: systemPrompt,
            allowedToolNames: allowedToolNames
        )
        session.systemPrompt = systemPrompt
        session.allowedToolNames = allowedToolNames
        session.thinkingSelection = thinkingSelection
        session.preserveThinking = preserveThinking
        sessions[id] = session
    }

    public func updateBorrowedOrchestrationToolExecutor(
        _ executor: AgentBorrowedToolExecutor?
    ) async {
        await toolExecutor.updateBorrowedOrchestrationToolExecutor(executor)
    }

    public func updateToolProviders(_ providers: [AgentToolProvider]) async {
        await toolExecutor.updateToolProviders(providers)
    }

    public func shutdown() async {
        sessions.removeAll()
        await toolExecutor.shutdown()
    }

    public func preloadModel(
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        _ = try await AnthropicSubscriptionAuthService.loadValidCredentials()
        let modelLLMID = modelLLMID()
        await onEvent(.modelLoaded(AnthropicSubscriptionModel.selectionTitle(forLLMID: modelLLMID)))
        return modelLLMID
    }

    public func activeToolDescriptors() async -> [DirectToolDescriptor] {
        guard let session = sessions.values.first else {
            return await toolExecutor.descriptors(allowedToolNames: [])
        }
        return await toolExecutor.descriptors(
            allowedToolNames: session.allowedToolNames,
            preferredWorkspaceRootURL: session.cwd
        )
    }

    public func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        await toolExecutor.subAgentSnapshots()
    }

    public func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        guard let session = sessions[id] else {
            return nil
        }
        let splitMessages = RemoteGenerationClient.snapshotMessages(from: session.messages)
        return AgentRuntimeSessionSnapshot(
            sessionID: id,
            modelID: configuration.modelID ?? provider.modelID,
            workingDirectoryPath: session.cwd.path,
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
            createSession(id: sessionID, cwd: configuration.workingDirectory.path)
        }
        guard var session = sessions[sessionID] else {
            throw RemoteGenerationClientError.missingSession
        }

        let credentials = try await AnthropicSubscriptionAuthService.loadValidCredentials()
        let modelLLMID = modelLLMID()
        let modelID = AnthropicSubscriptionModel.modelID(fromLLMID: modelLLMID)
        await onEvent(.modelLoaded(AnthropicSubscriptionModel.selectionTitle(forLLMID: modelLLMID)))

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
                modelLLMID: modelLLMID
            ) {
                await onEvent(.diagnostic(Self.compactionDiagnostic(from: result)))
            }

            let streamResult = try await streamAnthropicMessages(
                session: &session,
                modelID: modelID,
                modelLLMID: modelLLMID,
                credentials: credentials,
                onEvent: onEvent
            )

            accumulatedText.append(streamResult.text)
            generationStats.append(streamResult.stats)
            appendAssistantMessage(streamResult: streamResult, to: &session.messages)
            if let metrics = RemoteGenerationClient.generationMetrics(generationStats) {
                await Self.publishAnthropicSubscriptionMetrics(
                    metrics,
                    maxTokens: resolvedContextWindowTokenLimit(forLLMID: modelLLMID),
                    modelID: modelID,
                    onEvent: onEvent
                )
            }

            if streamResult.toolCalls.isEmpty {
                if !configuration.appMode,
                   let summary = RemoteGenerationClient.generationSummary(generationStats) {
                    await onEvent(.diagnostic(summary))
                }
                sessions[sessionID] = session
                return DirectAgentResponse(
                    text: accumulatedText,
                    stopReason: streamResult.stopReason,
                    modelID: modelID
                )
            }

            for toolCall in streamResult.toolCalls {
                await onEvent(.toolCallStarted(toolCall))
                let result = await toolExecutor.execute(
                    sessionID: session.id,
                    toolCall: toolCall,
                    workingDirectory: session.cwd,
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
                throw RemoteGenerationClientError.tooManyToolRounds(configuration.maxToolRounds)
            }
        }
        sessions[sessionID] = session
        throw RemoteGenerationClientError.tooManyToolRounds(configuration.maxToolRounds)
    }

    private func streamAnthropicMessages(
        session: inout AgentSession,
        modelID: String,
        modelLLMID: String,
        credentials: AnthropicSubscriptionCredentials,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> RemoteStreamResult {
        let toolDescriptors = await toolExecutor.descriptors(
            allowedToolNames: session.allowedToolNames,
            preferredWorkspaceRootURL: session.cwd
        )
        if configuration.verboseLogging {
            await onEvent(.diagnostic(RemoteGenerationClient.toolExposureDiagnostic(from: toolDescriptors)))
        }
        let toolCatalog = RemoteToolWireCatalog(descriptors: toolDescriptors)
        var anthropicPayload = Self.anthropicMessagesPayload(
            from: toolCatalog.wireMessages(from: session.messages)
        )
        var requestMessages = Self.addingCacheControlToLastUserMessage(
            anthropicPayload.messages
        )
        var systemBlocks = Self.subscriptionSystemBlocks(
            userSystemPrompt: anthropicPayload.system
        )
        let tools = Self.anthropicTools(from: toolCatalog.bindings)
        let maxOutputTokens = resolvedMaxOutputTokens(
            forLLMID: modelLLMID,
            thinkingSelection: session.thinkingSelection
        )
        var estimatedContextTokens = AnthropicSubscriptionRequestBuilder
            .estimatedContextTokenCount(
                system: systemBlocks,
                messages: requestMessages,
                tools: tools
            )
        if let result = compactSessionForEstimatedContextIfNeeded(
            &session,
            estimatedContextTokens: estimatedContextTokens,
            modelLLMID: modelLLMID,
            maxOutputTokens: maxOutputTokens
        ) {
            await onEvent(.diagnostic(Self.compactionDiagnostic(from: result)))
            anthropicPayload = Self.anthropicMessagesPayload(
                from: toolCatalog.wireMessages(from: session.messages)
            )
            requestMessages = Self.addingCacheControlToLastUserMessage(
                anthropicPayload.messages
            )
            systemBlocks = Self.subscriptionSystemBlocks(
                userSystemPrompt: anthropicPayload.system
            )
            estimatedContextTokens = AnthropicSubscriptionRequestBuilder
                .estimatedContextTokenCount(
                    system: systemBlocks,
                    messages: requestMessages,
                    tools: tools
                )
        }
        if let estimatedContextTokens {
            await onEvent(
                .contextWindow(
                    DirectAgentContextWindowStatus(
                        usedTokens: estimatedContextTokens,
                        maxTokens: resolvedContextWindowTokenLimit(forLLMID: modelLLMID),
                        modelID: modelID,
                        isApproximate: true
                    )
                )
            )
        }

        var body: [String: Any] = [
            "model": modelID,
            "messages": requestMessages,
            "max_tokens": maxOutputTokens,
            "stream": true
        ]
        body["system"] = systemBlocks
        if !tools.isEmpty {
            body["tools"] = tools
        }
        applyThinkingSelection(
            session.thinkingSelection,
            to: &body,
            modelLLMID: modelLLMID
        )

        var request = URLRequest(url: Self.apiBaseURL.appendingPathComponent("messages"))
        request.httpMethod = "POST"
        request.timeoutInterval = 900
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(
            Self.oauthBetaHeader(forModelID: modelID),
            forHTTPHeaderField: "anthropic-beta"
        )
        request.setValue("true", forHTTPHeaderField: "anthropic-dangerous-direct-browser-access")
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("claude-cli/\(Self.claudeCodeVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("cli", forHTTPHeaderField: "x-app")
        request.httpBody = try JSONValue(jsonObject: body).jsonData(
            outputFormatting: [.withoutEscapingSlashes]
        )

        if !configuration.appMode {
            await onEvent(.diagnostic("Remote request: \(provider.displayTitle) \(modelID)."))
        }

        let requestStartedAt = Date()
        let (bytes, response) = try await urlSession.bytes(for: request)
        try await Self.validateHTTPResponse(response, bytes: bytes)

        var accumulatedText = ""
        var stopReason = "end_turn"
        var firstDeltaAt: Date?
        var usage: RemoteGenerationUsage?
        var contentNormalizer = ThinkingBoundarySpacingNormalizer()
        var toolAccumulator = AnthropicToolUseAccumulator()

        func markFirstDelta() {
            if firstDeltaAt == nil {
                firstDeltaAt = Date()
            }
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let payload = RemoteGenerationClient.ssePayload(from: line),
                  payload != "[DONE]",
                  let object = RemoteGenerationClient.jsonObject(from: payload) else {
                continue
            }

            let type = Self.stringValue(object["type"])?.lowercased() ?? ""
            switch type {
            case "message_start":
                if let message = object["message"] as? [String: Any],
                   let remoteUsage = Self.usage(from: message["usage"]) {
                    usage = remoteUsage
                }
            case "content_block_start":
                markFirstDelta()
                toolAccumulator.ingestContentBlockStart(object)
                if let text = Self.contentBlockText(from: object), !text.isEmpty {
                    let normalizedDelta = contentNormalizer.append(text)
                    if !normalizedDelta.isEmpty {
                        accumulatedText.append(normalizedDelta)
                        await onEvent(.content(normalizedDelta))
                    }
                }
            case "content_block_delta":
                markFirstDelta()
                if let index = Self.intValue(object["index"]),
                   let delta = object["delta"] as? [String: Any] {
                    let deltaType = Self.stringValue(delta["type"])?.lowercased() ?? ""
                    switch deltaType {
                    case "text_delta":
                        let text = Self.stringValue(delta["text"]) ?? ""
                        let normalizedDelta = contentNormalizer.append(text)
                        if !normalizedDelta.isEmpty {
                            accumulatedText.append(normalizedDelta)
                            await onEvent(.content(normalizedDelta))
                        }
                    case "thinking_delta":
                        let thinking = Self.stringValue(delta["thinking"]) ?? ""
                        if !thinking.isEmpty {
                            await onEvent(.thought(thinking))
                        }
                    case "input_json_delta":
                        toolAccumulator.ingestInputJSONDelta(
                            index: index,
                            partialJSON: Self.stringValue(delta["partial_json"]) ?? ""
                        )
                    default:
                        break
                    }
                }
            case "message_delta":
                if let delta = object["delta"] as? [String: Any],
                   let reason = Self.stringValue(delta["stop_reason"])?.nilIfBlank {
                    stopReason = reason
                }
                if let remoteUsage = Self.usage(from: object["usage"], previous: usage) {
                    usage = remoteUsage
                }
            case "error":
                throw RemoteGenerationClientError.remoteFailure(
                    Self.errorMessage(from: object) ?? "Anthropic Subscription request failed."
                )
            default:
                break
            }
        }

        let normalizedRemainder = contentNormalizer.finish()
        if !normalizedRemainder.isEmpty {
            markFirstDelta()
            accumulatedText.append(normalizedRemainder)
            await onEvent(.content(normalizedRemainder))
        }

        let toolCalls = toolAccumulator.finalize().map(toolCatalog.localToolCall)
        return RemoteStreamResult(
            text: accumulatedText,
            stopReason: toolCalls.isEmpty ? stopReason : "tool_calls",
            toolCalls: toolCalls,
            stats: RemoteGenerationStats(
                usage: usage,
                requestStartedAt: requestStartedAt,
                firstDeltaAt: firstDeltaAt,
                finishedAt: Date(),
                generatedCharacterCount: accumulatedText.count
            )
        )
    }

    private func compactSessionIfNeeded(
        _ session: inout AgentSession,
        modelLLMID: String
    ) -> AgentConversationCompactionResult? {
        let result = Self.compactedMessagesIfNeeded(
            session.messages,
            maxTokens: resolvedContextWindowTokenLimit(forLLMID: modelLLMID),
            maxOutputTokens: resolvedMaxOutputTokens(
                forLLMID: modelLLMID,
                thinkingSelection: session.thinkingSelection
            )
        )
        guard result.wasCompacted else {
            return nil
        }

        session.messages = RemoteGenerationClient.remoteMessages(
            compactionResult: result,
            preservingRecentFrom: session.messages
        )
        return result
    }

    private func compactSessionForEstimatedContextIfNeeded(
        _ session: inout AgentSession,
        estimatedContextTokens: Int?,
        modelLLMID: String,
        maxOutputTokens: Int
    ) -> AgentConversationCompactionResult? {
        guard let result = Self.compactedMessagesForEstimatedContextIfNeeded(
            session.messages,
            estimatedContextTokens: estimatedContextTokens,
            maxTokens: resolvedContextWindowTokenLimit(forLLMID: modelLLMID),
            maxOutputTokens: maxOutputTokens
        ) else {
            return nil
        }

        session.messages = RemoteGenerationClient.remoteMessages(
            compactionResult: result,
            preservingRecentFrom: session.messages
        )
        return result
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
        let outputReserve = max(maxOutputTokens ?? 0, 0)
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

    private func modelLLMID() -> String {
        configuration.modelID?.nilIfBlank ?? provider.modelID
    }

    private func resolvedContextWindowTokenLimit(forLLMID modelLLMID: String?) -> Int? {
        configuration.configuredContextWindowLimit
            ?? AnthropicSubscriptionModel.contextWindowTokenLimit(forLLMID: modelLLMID)
    }

    nonisolated static func anthropicSubscriptionVisibleMetrics(
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

    nonisolated private static func publishAnthropicSubscriptionMetrics(
        _ metrics: DirectAgentGenerationMetrics,
        maxTokens: Int?,
        modelID: String,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async {
        let visibleMetrics = anthropicSubscriptionVisibleMetrics(metrics)
        await onEvent(.metrics(visibleMetrics))
        guard let contextTokenCount = metrics.contextTokenCount else {
            return
        }
        await onEvent(
            .contextWindow(
                DirectAgentContextWindowStatus(
                    usedTokens: contextTokenCount,
                    maxTokens: maxTokens,
                    modelID: modelID,
                    isApproximate: true
                )
            )
        )
    }

    private func resolvedMaxOutputTokens(
        forLLMID modelLLMID: String?,
        thinkingSelection: AgentThinkingSelection? = nil
    ) -> Int {
        let modelID = AnthropicSubscriptionModel.modelID(fromLLMID: modelLLMID)
        let modelLimit = AnthropicSubscriptionModel.maxOutputTokens(forLLMID: modelLLMID)
        guard let configuredLimit = configuration.maxOutputTokens, configuredLimit > 0 else {
            return modelLimit
        }
        guard let thinkingSelection,
              thinkingSelection.isEnabled,
              Self.supportsThinking(modelID: modelID),
              !Self.usesAdaptiveThinking(modelID: modelID) else {
            return min(configuredLimit, modelLimit)
        }
        return min(
            configuredLimit + Self.thinkingBudgetTokens(for: thinkingSelection),
            modelLimit
        )
    }

    private func applyThinkingSelection(
        _ selection: AgentThinkingSelection?,
        to body: inout [String: Any],
        modelLLMID: String
    ) {
        let modelID = AnthropicSubscriptionModel.modelID(fromLLMID: modelLLMID)
        guard Self.supportsThinking(modelID: modelID) else {
            return
        }
        guard let selection, selection.isEnabled else {
            body["thinking"] = ["type": "disabled"]
            return
        }

        if Self.usesAdaptiveThinking(modelID: modelID) {
            body["thinking"] = [
                "type": "adaptive",
                "display": "summarized"
            ]
            if let effort = Self.adaptiveThinkingEffort(
                for: selection,
                modelID: modelID
            ) {
                body["output_config"] = ["effort": effort]
            }
            return
        }

        let maxTokens = resolvedMaxOutputTokens(
            forLLMID: modelLLMID,
            thinkingSelection: selection
        )
        let budget = Self.adjustedThinkingBudget(
            Self.thinkingBudgetTokens(for: selection),
            maxTokens: maxTokens
        )
        guard budget > 0 else {
            return
        }
        body["thinking"] = [
            "type": "enabled",
            "budget_tokens": budget,
            "display": "summarized"
        ]
    }

    private static func supportsThinking(modelID: String) -> Bool {
        AnthropicSubscriptionModel.option(forModelID: modelID).thinkingSupport != nil
    }

    private static func usesAdaptiveThinking(modelID: String) -> Bool {
        switch modelID {
        case "claude-fable-5",
             "claude-opus-4-6",
             "claude-opus-4-7",
             "claude-opus-4-8",
             "claude-sonnet-4-6":
            return true
        default:
            return false
        }
    }

    private static func adaptiveThinkingEffort(
        for selection: AgentThinkingSelection,
        modelID: String
    ) -> String? {
        switch selection {
        case .off, .enabled:
            return nil
        case .minimal, .low:
            return "low"
        case .medium:
            return "medium"
        case .high:
            return "high"
        case .xhigh:
            switch modelID {
            case "claude-fable-5", "claude-opus-4-7", "claude-opus-4-8":
                return "xhigh"
            case "claude-opus-4-6":
                return "max"
            default:
                return "high"
            }
        }
    }

    private static func thinkingBudgetTokens(for selection: AgentThinkingSelection) -> Int {
        switch selection {
        case .off:
            return 0
        case .enabled, .minimal:
            return 1_024
        case .low:
            return 2_048
        case .medium:
            return 8_192
        case .high, .xhigh:
            return 16_384
        }
    }

    private static func adjustedThinkingBudget(_ budget: Int, maxTokens: Int) -> Int {
        guard maxTokens <= budget else {
            return budget
        }
        return max(0, maxTokens - minimumOutputTokensForThinking)
    }

    private static func subscriptionSystemBlocks(userSystemPrompt: String?) -> [[String: Any]] {
        var blocks = [
            subscriptionSystemTextBlock(
                "You are Claude Code, Anthropic's official CLI for Claude."
            )
        ]
        if let userSystemPrompt = userSystemPrompt?.nilIfBlank {
            blocks.append(subscriptionSystemTextBlock(userSystemPrompt))
        }
        return blocks
    }

    private static func subscriptionSystemTextBlock(_ text: String) -> [String: Any] {
        [
            "type": "text",
            "text": text,
            "cache_control": cacheControl()
        ]
    }


    private static func cacheControl() -> [String: Any] {
        ["type": "ephemeral"]
    }

    private static func oauthBetaHeader(forModelID modelID: String) -> String {
        var headers = [claudeCodeBetaHeader, oauthBetaHeader]
        if !usesAdaptiveThinking(modelID: modelID) {
            headers.append(interleavedThinkingBetaHeader)
        }
        return headers.joined(separator: ",")
    }

    private func appendAssistantMessage(
        streamResult: RemoteStreamResult,
        to messages: inout [[String: Any]]
    ) {
        var message: [String: Any] = [
            "role": "assistant",
            "content": streamResult.text
        ]
        if !streamResult.toolCalls.isEmpty {
            message["tool_calls"] = streamResult.toolCalls.map { toolCall in
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

        let hasContent = !streamResult.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        if hasContent || !streamResult.toolCalls.isEmpty {
            messages.append(message)
        }
    }
}

private extension AnthropicSubscriptionGenerationClient {
    static func anthropicMessagesPayload(
        from messages: [[String: Any]]
    ) -> (system: String?, messages: [[String: Any]]) {
        var systemParts: [String] = []
        var anthropicMessages: [[String: Any]] = []

        for message in messages {
            let role = (message["role"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if role == "system" {
                if let text = RemoteGenerationClient.contentString(from: message["content"])?.nilIfBlank {
                    systemParts.append(text)
                }
                continue
            }

            switch role {
            case "assistant":
                let blocks = assistantContentBlocks(from: message)
                if !blocks.isEmpty {
                    anthropicMessages.append([
                        "role": "assistant",
                        "content": blocks
                    ])
                }
            case "tool":
                if let block = toolResultBlock(from: message) {
                    appendUserBlocks([block], to: &anthropicMessages)
                }
            default:
                let blocks = userContentBlocks(from: message["content"])
                if !blocks.isEmpty {
                    anthropicMessages.append([
                        "role": "user",
                        "content": blocks
                    ])
                }
            }
        }

        return (
            systemParts.joined(separator: "\n\n").nilIfBlank,
            anthropicMessages
        )
    }

    static func appendUserBlocks(_ blocks: [[String: Any]], to messages: inout [[String: Any]]) {
        guard !blocks.isEmpty else {
            return
        }
        if let last = messages.indices.last,
           (messages[last]["role"] as? String) == "user",
           var content = messages[last]["content"] as? [[String: Any]] {
            content.append(contentsOf: blocks)
            messages[last]["content"] = content
        } else {
            messages.append([
                "role": "user",
                "content": blocks
            ])
        }
    }


    static func addingCacheControlToLastUserMessage(
        _ messages: [[String: Any]]
    ) -> [[String: Any]] {
        var messages = messages
        guard let lastIndex = messages.indices.last,
              (messages[lastIndex]["role"] as? String) == "user" else {
            return messages
        }

        if var content = messages[lastIndex]["content"] as? [[String: Any]],
           let lastBlockIndex = content.indices.last {
            let blockType = stringValue(content[lastBlockIndex]["type"])?.lowercased()
            if blockType == "text" || blockType == "image" || blockType == "tool_result" {
                content[lastBlockIndex]["cache_control"] = cacheControl()
                messages[lastIndex]["content"] = content
            }
            return messages
        }

        if let text = stringValue(messages[lastIndex]["content"])?.nilIfBlank {
            messages[lastIndex]["content"] = [
                [
                    "type": "text",
                    "text": text,
                    "cache_control": cacheControl()
                ]
            ]
        }
        return messages
    }

    static func userContentBlocks(from value: Any?) -> [[String: Any]] {
        if let text = RemoteGenerationClient.contentString(from: value)?.nilIfBlank,
           !(value is [[String: Any]]) {
            return [["type": "text", "text": text]]
        }

        guard let items = value as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item in
            let type = stringValue(item["type"])?.lowercased()
            switch type {
            case "text", "input_text", "output_text":
                guard let text = stringValue(item["text"])?.nilIfBlank else {
                    return nil
                }
                return ["type": "text", "text": text]
            case "image_url", "input_image":
                guard let imageURL = RemoteGenerationClient.chatCompletionsImageURL(from: item)?.nilIfBlank,
                      let imageBlock = anthropicImageBlock(fromDataURL: imageURL) else {
                    return nil
                }
                return imageBlock
            default:
                return nil
            }
        }
    }

    static func assistantContentBlocks(from message: [String: Any]) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        if let text = RemoteGenerationClient.contentString(from: message["content"])?.nilIfBlank {
            blocks.append(["type": "text", "text": text])
        }
        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            blocks.append(contentsOf: toolCalls.compactMap(toolUseBlock(from:)))
        }
        return blocks
    }

    static func toolUseBlock(from toolCall: [String: Any]) -> [String: Any]? {
        guard let function = toolCall["function"] as? [String: Any],
              let name = stringValue(function["name"])?.nilIfBlank else {
            return nil
        }
        let id = stringValue(toolCall["id"])?.nilIfBlank ?? "toolu_\(UUID().uuidString.lowercased())"
        return [
            "type": "tool_use",
            "id": id,
            "name": name,
            "input": jsonObject(fromJSONString: stringValue(function["arguments"]) ?? "{}")
        ]
    }

    static func toolResultBlock(from message: [String: Any]) -> [String: Any]? {
        guard let toolUseID = stringValue(message["tool_call_id"])?.nilIfBlank else {
            return nil
        }
        return [
            "type": "tool_result",
            "tool_use_id": toolUseID,
            "content": RemoteGenerationClient.contentString(from: message["content"]) ?? ""
        ]
    }

    static func anthropicImageBlock(fromDataURL dataURL: String) -> [String: Any]? {
        guard dataURL.hasPrefix("data:"),
              let commaIndex = dataURL.firstIndex(of: ",") else {
            return nil
        }
        let header = String(dataURL[dataURL.index(dataURL.startIndex, offsetBy: "data:".count)..<commaIndex])
        let data = String(dataURL[dataURL.index(after: commaIndex)...])
        let mediaType = header.components(separatedBy: ";").first?.nilIfBlank ?? "image/png"
        return [
            "type": "image",
            "source": [
                "type": "base64",
                "media_type": mediaType,
                "data": data
            ]
        ]
    }

    static func anthropicTools(from bindings: [RemoteToolWireCatalog.Binding]) -> [[String: Any]] {
        bindings.enumerated().compactMap { index, binding in
            guard let schema = binding.descriptor.schemaObject else {
                return nil
            }
            var tool: [String: Any] = [
                "name": binding.wireName,
                "description": binding.descriptor.description,
                "eager_input_streaming": true,
                "input_schema": schema
            ]
            if index == bindings.count - 1 {
                tool["cache_control"] = cacheControl()
            }
            return tool
        }
    }

    static func contentBlockText(from object: [String: Any]) -> String? {
        guard let contentBlock = object["content_block"] as? [String: Any],
              stringValue(contentBlock["type"])?.lowercased() == "text" else {
            return nil
        }
        return stringValue(contentBlock["text"])
    }

    static func usage(from value: Any?, previous: RemoteGenerationUsage? = nil) -> RemoteGenerationUsage? {
        AnthropicSubscriptionRequestBuilder.usage(
            from: value,
            previous: previous
        )
    }

    static func errorMessage(from object: [String: Any]) -> String? {
        if let error = object["error"] as? [String: Any] {
            return stringValue(error["message"])
                ?? stringValue(error["type"])
        }
        return stringValue(object["message"])
    }

    static func validateHTTPResponse(
        _ response: URLResponse,
        bytes: URLSession.AsyncBytes
    ) async throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            return
        }
        guard !(200..<300).contains(httpResponse.statusCode) else {
            return
        }

        let body = try await collectErrorBody(from: bytes)
        var details: [String] = []
        if let message = errorMessage(fromJSONString: body)?.nilIfBlank {
            details.append(message)
        }
        if let retryAfter = httpResponse.value(forHTTPHeaderField: "retry-after")?.nilIfBlank {
            details.append("retry-after=\(retryAfter)")
        }
        if let requestID = httpResponse.value(forHTTPHeaderField: "request-id")?.nilIfBlank
            ?? httpResponse.value(forHTTPHeaderField: "x-request-id")?.nilIfBlank {
            details.append("request-id=\(requestID)")
        }
        let bodyDetail = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if details.isEmpty, !bodyDetail.isEmpty {
            details.append(bodyDetail)
        }

        let suffix = details.isEmpty ? "" : ": \(details.joined(separator: "; "))"
        throw RemoteGenerationClientError.remoteFailure(
            "Anthropic Subscription returned HTTP \(httpResponse.statusCode)\(suffix)"
        )
    }

    static func collectErrorBody(
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
    }

    static func errorMessage(fromJSONString string: String) -> String? {
        guard let data = string.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.mlxObjectValue else {
            return nil
        }
        let jsonObject = object.mapValues(\.jsonObject)
        if let error = jsonObject["error"] as? [String: Any] {
            let type = stringValue(error["type"])?.nilIfBlank
            let message = stringValue(error["message"])?.nilIfBlank
            return [type, message].compactMap { $0 }.joined(separator: ": ").nilIfBlank
        }
        return stringValue(jsonObject["message"])?.nilIfBlank
            ?? stringValue(jsonObject["type"])?.nilIfBlank
    }

    static func jsonObject(fromJSONString string: String) -> [String: Any] {
        guard let data = string.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.mlxObjectValue else {
            return [:]
        }
        return object.mapValues(\.jsonObject)
    }

    static func stringValue(_ value: Any?) -> String? {
        RemoteGenerationClient.stringValue(value)
    }

    static func intValue(_ value: Any?) -> Int? {
        JSONValue(jsonObject: value).intValue
    }
}

private struct AnthropicToolUseAccumulator {
    struct PartialToolUse {
        var id: String
        var name: String
        var inputObject: [String: Any]?
        var partialJSON = ""
    }

    private var partialsByIndex: [Int: PartialToolUse] = [:]

    mutating func ingestContentBlockStart(_ object: [String: Any]) {
        guard let index = AnthropicSubscriptionGenerationClient.intValue(object["index"]),
              let contentBlock = object["content_block"] as? [String: Any],
              AnthropicSubscriptionGenerationClient.stringValue(contentBlock["type"])?.lowercased() == "tool_use",
              let id = AnthropicSubscriptionGenerationClient.stringValue(contentBlock["id"])?.nilIfBlank,
              let name = AnthropicSubscriptionGenerationClient.stringValue(contentBlock["name"])?.nilIfBlank else {
            return
        }
        partialsByIndex[index] = PartialToolUse(
            id: id,
            name: name,
            inputObject: contentBlock["input"] as? [String: Any]
        )
    }

    mutating func ingestInputJSONDelta(index: Int, partialJSON: String) {
        guard !partialJSON.isEmpty else {
            return
        }
        var partial = partialsByIndex[index] ?? PartialToolUse(
            id: "toolu_\(UUID().uuidString.lowercased())",
            name: "tool",
            inputObject: nil
        )
        partial.partialJSON.append(partialJSON)
        partialsByIndex[index] = partial
    }

    func finalize() -> [DirectAgentToolCall] {
        partialsByIndex.keys.sorted().compactMap { index in
            guard let partial = partialsByIndex[index] else {
                return nil
            }
            let argumentsJSON: String
            let argumentsObject: [String: Any]
            if let object = partial.inputObject, partial.partialJSON.isEmpty {
                argumentsObject = object
                argumentsJSON = AgentJSONSupport.jsonString(from: object)
            } else {
                argumentsJSON = partial.partialJSON.nilIfBlank ?? "{}"
                argumentsObject = AnthropicSubscriptionGenerationClient.jsonObject(fromJSONString: argumentsJSON)
            }
            return DirectAgentToolCall(
                id: partial.id,
                name: partial.name,
                argumentsObject: argumentsObject,
                argumentsJSON: argumentsJSON
            )
        }
    }
}
#endif
