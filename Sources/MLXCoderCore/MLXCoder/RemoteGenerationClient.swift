//
//  RemoteGenerationClient.swift
//  MLXCoder
//
//  Created by Codex on 02/05/26.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor RemoteGenerationClient: AgentRuntimeBackend {
    public struct AgentSession {
        public let id: String
        public let cwd: URL
        public var allowedToolNames: Set<String>?
        public var thinkingSelection: AgentThinkingSelection?
        public var preserveThinking: Bool
        public var messages: [[String: Any]]
    }

    public let configuration: AgentRuntimeConfiguration
    public let provider: AgentRemoteProvider
    public let apiKey: String?
    public let urlSession: URLSession
    public let toolExecutor: DirectToolExecutor
    public var sessions: [String: AgentSession] = [:]
    public var didEmitLoadedModel = false

    public init(
        configuration: AgentRuntimeConfiguration,
        provider: AgentRemoteProvider,
        apiKey: String?,
        urlSession: URLSession? = nil,
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime()
    ) {
        self.configuration = configuration
        self.provider = provider
        self.apiKey = apiKey?.nilIfBlank
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
            subAgentBackendFactory: {
                RemoteGenerationClient(
                    configuration: configuration,
                    provider: provider,
                    apiKey: apiKey,
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
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking,
            messages: Self.initialMessages(
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
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        guard var session = sessions[id] else {
            return
        }
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
        try validateConfiguration()
        if !didEmitLoadedModel {
            didEmitLoadedModel = true
            await onEvent(.modelLoaded(provider.modelID))
        }
        return provider.modelID
    }

    public func activeToolDescriptors() async -> [DirectToolDescriptor] {
        await toolExecutor.descriptors()
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

        _ = try await preloadModel(onEvent: onEvent)
        session.messages.append(
            Self.remoteMessage(
                role: "user",
                content: prompt,
                attachments: attachments
            )
        )

        var accumulatedText = ""
        var generationStats: [RemoteGenerationStats] = []
        for round in 0..<configuration.maxToolRounds {
            let streamResult: RemoteStreamResult
            switch provider.chatEndpoint {
            case .chatCompletions:
                streamResult = try await streamChatCompletions(
                    messages: session.messages,
                    sessionID: session.id,
                    allowedToolNames: session.allowedToolNames,
                    thinkingSelection: session.thinkingSelection,
                    onEvent: onEvent
                )
            case .responses:
                streamResult = try await streamResponses(
                    messages: session.messages,
                    sessionID: session.id,
                    allowedToolNames: session.allowedToolNames,
                    thinkingSelection: session.thinkingSelection,
                    onEvent: onEvent
                )
            }

            accumulatedText.append(streamResult.text)
            generationStats.append(streamResult.stats)
            appendAssistantMessage(
                streamResult: streamResult,
                to: &session.messages
            )
            if let metrics = Self.generationMetrics(
                generationStats,
                estimateMissingRates: Self.shouldEstimateStreamingRates(
                    baseURL: provider.baseURL
                )
            ) {
                await Self.publishGenerationMetrics(
                    metrics,
                    maxTokens: configuration.configuredContextWindowLimit,
                    modelID: provider.modelID,
                    onEvent: onEvent
                )
            }

            if streamResult.toolCalls.isEmpty {
                guard Self.shouldStopGenerationLoop(afterDirectAnswer: accumulatedText) else {
                    if round == configuration.maxToolRounds - 1 {
                        sessions[sessionID] = session
                        throw RemoteGenerationClientError.tooManyToolRounds(configuration.maxToolRounds)
                    }
                    continue
                }

                if !configuration.appMode,
                   let summary = Self.generationSummary(
                       generationStats,
                       estimateMissingRates: Self.shouldEstimateStreamingRates(
                           baseURL: provider.baseURL
                       )
                   ) {
                    await onEvent(.diagnostic(summary))
                }
                sessions[sessionID] = session
                return DirectAgentResponse(
                    text: accumulatedText,
                    stopReason: streamResult.stopReason,
                    modelID: provider.modelID
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

    public static func shouldStopGenerationLoop(afterDirectAnswer text: String) -> Bool {
        guard let finalCharacter = text.lastSignificantGenerationCharacter else {
            return false
        }

        return finalCharacter == "?" || finalCharacter.isEmojiSymbol
    }
}

private extension String {
    var lastSignificantGenerationCharacter: Character? {
        reversed().first { !$0.isGenerationTrailer }
    }
}

private extension Character {
    var isGenerationTrailer: Bool {
        unicodeScalars.allSatisfy { scalar in
            scalar.properties.isWhitespace
                || scalar.properties.generalCategory == .format
                || scalar.properties.generalCategory == .control
        }
    }

    var isEmojiSymbol: Bool {
        unicodeScalars.contains { scalar in
            scalar.properties.isEmoji
                && scalar.properties.generalCategory == .otherSymbol
        }
    }
}
