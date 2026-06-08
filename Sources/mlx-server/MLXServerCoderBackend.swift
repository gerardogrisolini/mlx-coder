//
//  MLXServerCoderBackend.swift
//  mlx-server
//

import Foundation
import MLXCoderCore
@preconcurrency import MLXLMCommon
import MLXServerCore

actor MLXServerCoderBackend: AgentRuntimeBackend {
    private struct SessionState {
        var cwd: URL
        var messages: [MLXServerChatMessage]
        var cacheKey: String?
        var allowedToolNames: Set<String>?
        var thinkingSelection: AgentThinkingSelection?
        var preserveThinking: Bool
    }

    private struct GenerationTurn {
        var visibleText: String
        var historyVisibleText: String
        var reasoningText: String
        var toolCalls: [ToolCall]
        var completionInfo: GenerateCompletionInfo?
    }

    private let configuration: AgentRuntimeConfiguration
    private let runtime: MLXServerRuntime
    private let model: MLXServerModelDescriptor
    private let kvCacheSettings: MLXServerKVCacheSettings
    private let toolExecutor: DirectToolExecutor

    private var sessions: [String: SessionState] = [:]
    private var didEmitLoadedModel = false

    init(
        configuration: AgentRuntimeConfiguration,
        runtime: MLXServerRuntime,
        model: MLXServerModelDescriptor,
        kvCacheSettings: MLXServerKVCacheSettings,
        mcpRuntime: DirectMCPToolRuntime
    ) {
        self.configuration = configuration
        self.runtime = runtime
        self.model = model
        self.kvCacheSettings = kvCacheSettings
        self.toolExecutor = DirectToolExecutor(
            outputLimit: 24_000,
            authorizationHandler: configuration.toolAuthorizationHandler,
            mcpRuntime: mcpRuntime,
            subAgentBackendFactory: {
                MLXServerCoderBackend(
                    configuration: configuration,
                    runtime: runtime,
                    model: model,
                    kvCacheSettings: kvCacheSettings,
                    mcpRuntime: mcpRuntime
                )
            }
        )
    }

    func createSession(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        sessions[id] = SessionState(
            cwd: URL(fileURLWithPath: cwd),
            messages: Self.initialMessages(
                systemPrompt: systemPrompt,
                history: history
            ),
            cacheKey: cacheKey,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func createSessionIfNeeded(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
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

    func updateSessionOptions(
        id: String,
        systemPrompt: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        guard var session = sessions[id] else {
            return
        }
        session.messages = Self.replacingSystemPrompt(
            in: session.messages,
            with: systemPrompt
        )
        session.allowedToolNames = allowedToolNames
        session.thinkingSelection = thinkingSelection
        session.preserveThinking = preserveThinking
        sessions[id] = session
    }

    func updateBorrowedOrchestrationToolExecutor(
        _ executor: AgentBorrowedToolExecutor?
    ) async {
        await toolExecutor.updateBorrowedOrchestrationToolExecutor(executor)
    }

    func updateToolProviders(_ providers: [AgentToolProvider]) async {
        await toolExecutor.updateToolProviders(providers)
    }

    func closeSession(id: String) {
        sessions.removeValue(forKey: id)
    }

    func shutdown() async {
        sessions.removeAll(keepingCapacity: false)
        await toolExecutor.shutdown()
    }

    func preloadModel(
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        guard !didEmitLoadedModel else {
            return model.id
        }
        try await runtime.preloadModel(
            model: model,
            runtimeKind: model.runtimeKind,
            parameters: generationParameters()
        )
        didEmitLoadedModel = true
        await onEvent(.modelLoadedDetails(loadedModelDetails()))
        if let contextWindow = model.generationDefaults.contextWindow
            ?? configuration.configuredContextWindowLimit {
            await onEvent(
                .contextWindow(
                    DirectAgentContextWindowStatus(
                        usedTokens: 0,
                        maxTokens: contextWindow,
                        modelID: model.id,
                        isApproximate: true
                    )
                )
            )
        }
        return model.id
    }

    private func loadedModelDetails() -> DirectAgentLoadedModelDetails {
        let defaults = model.generationDefaults
        let parameters = generationParameters()
        let generationLine = [
            "context_window=\(Self.formatModelDefault(defaults.contextWindow))",
            "max_output_tokens=\(Self.formatModelDefault(parameters.maxTokens))",
            "temperature=\(Self.format(parameters.temperature))",
            "top_p=\(Self.format(parameters.topP))",
            "top_k=\(parameters.topK)",
            "min_p=\(Self.format(parameters.minP))",
        ].joined(separator: ", ")
        let penaltiesLine = [
            "repetition=\(Self.formatModelDefault(parameters.repetitionPenalty))",
            "presence=\(Self.formatModelDefault(parameters.presencePenalty))",
            "frequency=\(Self.formatModelDefault(parameters.frequencyPenalty))",
        ].joined(separator: ", ")
        let kvCache = parameters.kvBits.map {
            "quantized(bits=\($0), group=\(parameters.kvGroupSize), start=\(parameters.quantizedKVStart))"
        } ?? "standard"

        return DirectAgentLoadedModelDetails(
            modelID: model.id,
            runtime: model.runtimeKind.rawValue,
            generation: generationLine,
            penalties: penaltiesLine,
            kvCache: "\(kvCache), prefill_step_size=\(parameters.prefillStepSize)"
        )
    }

    private static func formatModelDefault(_ value: Int?) -> String {
        value.map(String.init) ?? "model_default"
    }

    private static func formatModelDefault(_ value: Float?) -> String {
        value.map(format) ?? "model_default"
    }

    private static func format(_ value: Float) -> String {
        String(format: "%.4g", Double(value))
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        await toolExecutor.descriptors()
    }

    func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        await toolExecutor.subAgentSnapshots()
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        guard let session = sessions[id] else {
            return nil
        }
        let splitMessages = Self.snapshotMessages(from: session.messages)
        return AgentRuntimeSessionSnapshot(
            sessionID: id,
            modelID: model.id,
            workingDirectoryPath: session.cwd.path,
            systemPrompt: splitMessages.systemPrompt,
            cacheKey: session.cacheKey,
            history: splitMessages.history,
            allowedToolNames: session.allowedToolNames,
            thinkingSelection: session.thinkingSelection,
            preserveThinking: session.preserveThinking
        )
    }

    func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        if sessions[sessionID] == nil {
            createSession(
                id: sessionID,
                cwd: configuration.workingDirectory.path,
                systemPrompt: nil,
                history: [],
                cacheKey: nil,
                allowedToolNames: [],
                thinkingSelection: nil,
                preserveThinking: false
            )
        }
        guard var session = sessions[sessionID] else {
            throw MLXServerCoderBackendError.missingSession
        }

        _ = try await preloadModel(onEvent: onEvent)
        session.messages.append(
            Self.serverMessage(
                role: .user,
                content: prompt,
                attachments: attachments
            )
        )

        var accumulatedVisibleText = ""
        for _ in 0..<configuration.maxToolRounds {
            if let result = compactSessionIfNeeded(&session) {
                await onEvent(.diagnostic(Self.compactionDiagnostic(from: result)))
            }
            let request = await generationRequest(for: session)
            await onEvent(.modelRuntime(request.runtimeKind.rawValue))
            let turn = try await runGenerationTurn(
                request: request,
                onEvent: onEvent
            )
            let directToolCalls = turn.toolCalls.map(Self.directToolCall(from:))
            appendAssistantTurn(turn, directToolCalls: directToolCalls, to: &session)
            accumulatedVisibleText += turn.visibleText

            if let completionInfo = turn.completionInfo {
                await emitMetrics(completionInfo, onEvent: onEvent)
            }

            guard !turn.toolCalls.isEmpty else {
                sessions[sessionID] = session
                return DirectAgentResponse(
                    text: accumulatedVisibleText,
                    stopReason: "end_turn",
                    modelID: model.id
                )
            }

            for directToolCall in directToolCalls {
                await onEvent(.toolCallStarted(directToolCall))
                let result = await toolExecutor.execute(
                    sessionID: sessionID,
                    toolCall: directToolCall,
                    workingDirectory: session.cwd,
                    allowedToolNames: session.allowedToolNames
                )
                await onEvent(.toolCallCompleted(directToolCall, result))
                session.messages.append(
                    .tool(result.output, toolCallID: directToolCall.id)
                )
            }
        }

        sessions[sessionID] = session
        throw MLXServerCoderBackendError.tooManyToolRounds(configuration.maxToolRounds)
    }

    private func generationRequest(
        for session: SessionState
    ) async -> MLXServerGenerationRequest {
        let thinkingSelection = resolvedThinkingSelection(for: session)
        var additionalContext = model.thinking.additionalContext(for: thinkingSelection)
        additionalContext["preserve_thinking"] = session.preserveThinking
            && model.thinking.supportsPreserveThinking
            && thinkingSelection.isEnabled

        return MLXServerGenerationRequest(
            model: model,
            messages: session.messages,
            parameters: generationParameters(),
            tools: await toolSpecs(allowedToolNames: session.allowedToolNames),
            additionalContext: additionalContext,
            retainsReasoningInHistory: session.preserveThinking && thinkingSelection.isEnabled
        )
    }

    private func generationParameters() -> GenerateParameters {
        let overrides = configuration.generationParameterOverrides.normalized()
        var parameters = model.generationDefaults.generateParameters(
            maxTokens: configuration.maxOutputTokens ?? overrides.maxTokens,
            kvCacheSettings: kvCacheSettings
        )

        if let minP = overrides.minP {
            parameters.minP = Float(minP)
        }
        if let repetitionPenalty = overrides.repetitionPenalty {
            parameters.repetitionPenalty = Float(repetitionPenalty)
        }
        if let repetitionContextSize = overrides.repetitionContextSize {
            parameters.repetitionContextSize = repetitionContextSize
        }
        if let presenceContextSize = overrides.presenceContextSize {
            parameters.presenceContextSize = presenceContextSize
        }
        if let frequencyContextSize = overrides.frequencyContextSize {
            parameters.frequencyContextSize = frequencyContextSize
        }
        if let prefillStepSize = overrides.prefillStepSize {
            parameters.prefillStepSize = prefillStepSize
        }
        if let kvBits = overrides.kvBits {
            parameters.kvBits = kvBits
        }
        if let kvGroupSize = overrides.kvGroupSize {
            parameters.kvGroupSize = kvGroupSize
        }
        if let quantizedKVStart = overrides.quantizedKVStart {
            parameters.quantizedKVStart = quantizedKVStart
        }
        return parameters
    }

    private func resolvedThinkingSelection(
        for session: SessionState
    ) -> MLXServerThinkingSelection {
        guard let thinkingSelection = session.thinkingSelection else {
            return model.thinking.defaultEnabledSelection()
        }
        return model.thinking.selection(for: thinkingSelection.rawValue)
    }

    private func toolSpecs(
        allowedToolNames: Set<String>?
    ) async -> [ToolSpec]? {
        let descriptors = await toolExecutor.descriptors(
            allowedToolNames: allowedToolNames
        )
        guard !descriptors.isEmpty else {
            return nil
        }

        return descriptors.compactMap { descriptor in
            guard let parameters = Self.sendableJSONObject(from: descriptor.inputSchema) else {
                return nil
            }
            return [
                "type": "function",
                "function": [
                    "name": descriptor.name,
                    "description": descriptor.description,
                    "parameters": parameters
                ] as [String: any Sendable]
            ] as ToolSpec
        }
    }

    private func runGenerationTurn(
        request: MLXServerGenerationRequest,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> GenerationTurn {
        let stream = try await runtime.generateChatSession(request: request)
        var splitter = MLXServerCoderTranscriptSplitter(
            startsInThinking: request.emitsThinking
        )
        var rawText = ""
        var toolCalls: [ToolCall] = []
        var completionInfo: GenerateCompletionInfo?

        for await event in stream {
            switch event {
            case .chunk(let chunk):
                rawText += chunk
                for part in splitter.consume(chunk) {
                    await emitTranscriptPart(part, onEvent: onEvent)
                }
            case .toolCall(let toolCall):
                toolCalls.append(toolCall)
            case .info(let info):
                completionInfo = info
            }
        }

        for part in splitter.finish() {
            await emitTranscriptPart(part, onEvent: onEvent)
        }

        return GenerationTurn(
            visibleText: MLXServerChatSessionTranscriptText.visibleAssistantContent(
                from: rawText,
                startsInThinking: request.emitsThinking
            ),
            historyVisibleText: MLXServerChatSessionTranscriptText.visibleAssistantContentForHistory(
                from: rawText,
                startsInThinking: request.emitsThinking
            ),
            reasoningText: MLXServerChatSessionTranscriptText.reasoningContent(
                from: rawText,
                startsInThinking: request.emitsThinking
            ),
            toolCalls: toolCalls,
            completionInfo: completionInfo
        )
    }

    private func appendAssistantTurn(
        _ turn: GenerationTurn,
        directToolCalls: [DirectAgentToolCall],
        to session: inout SessionState
    ) {
        if !turn.reasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           session.preserveThinking {
            session.messages.append(
                .assistant(
                    MLXServerReasoningTranscript.reasoningSummary(turn.reasoningText)
                )
            )
        }
        let historyReasoningText = session.preserveThinking ? turn.reasoningText : nil
        let hasHistoryReasoningText = historyReasoningText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let structuredToolCalls = zip(turn.toolCalls, directToolCalls).map { toolCall, directToolCall in
            MLXServerChatToolCall(id: directToolCall.id, toolCall: toolCall)
        }
        if !turn.historyVisibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !structuredToolCalls.isEmpty {
            session.messages.append(
                .assistant(
                    turn.historyVisibleText,
                    reasoningContent: historyReasoningText,
                    toolCalls: structuredToolCalls
                )
            )
        }
        if turn.historyVisibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !hasHistoryReasoningText,
           turn.toolCalls.isEmpty {
            session.messages.append(.assistant(""))
        }
    }

    private func emitMetrics(
        _ info: GenerateCompletionInfo,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async {
        let cacheEvent = await runtime.consumeLastChatCacheEvent()
        let renderedPromptTokenCount = cacheEvent?.priorTranscriptCount
            ?? info.promptTokenCount
        let contextTokenCount = renderedPromptTokenCount + info.generationTokenCount
        await onEvent(
            .metrics(
                DirectAgentGenerationMetrics(
                    promptTokenCount: info.promptTokenCount,
                    cachedPromptTokenCount: cacheEvent?.cachedPromptTokenCount,
                    promptTokensPerSecond: info.promptTokensPerSecond,
                    completionTokenCount: info.generationTokenCount,
                    completionTokensPerSecond: info.tokensPerSecond,
                    responseDurationSeconds: info.promptTime + info.generateTime,
                    contextTokenCount: contextTokenCount
                )
            )
        )
        await onEvent(
            .contextWindow(
                DirectAgentContextWindowStatus(
                    usedTokens: contextTokenCount,
                    maxTokens: configuration.configuredContextWindowLimit
                        ?? model.generationDefaults.contextWindow,
                    modelID: model.id,
                    isApproximate: false
                )
            )
        )
    }

    private func emitTranscriptPart(
        _ part: MLXServerCoderTranscriptSplitter.Part,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async {
        switch part {
        case .content(let text):
            guard !text.isEmpty else {
                return
            }
            await onEvent(.content(text))
        case .thought(let text):
            guard !text.isEmpty else {
                return
            }
            await onEvent(.thought(text))
        }
    }

    private func compactSessionIfNeeded(
        _ session: inout SessionState
    ) -> AgentConversationCompactionResult? {
        let maxTokens = configuration.configuredContextWindowLimit
            ?? model.generationDefaults.contextWindow
        let result = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            session.messages.map(Self.agentRuntimeMessage(from:)),
            maxTokens: maxTokens
        )
        guard result.wasCompacted else {
            return nil
        }

        session.messages = result.messages.map(Self.serverMessage(from:))
        return result
    }

    private static func compactionDiagnostic(
        from result: AgentConversationCompactionResult
    ) -> String {
        "Compacted conversation history from \(result.originalEstimatedTokenCount) to \(result.estimatedTokenCount) estimated tokens."
    }

    private static func initialMessages(
        systemPrompt: String?,
        history: [AgentRuntimeMessage]
    ) -> [MLXServerChatMessage] {
        var messages: [MLXServerChatMessage] = []
        if let systemPrompt = systemPrompt?.nilIfBlank {
            messages.append(.system(systemPrompt))
        }
        messages.append(
            contentsOf: history.map { message in
                serverMessage(
                    role: message.role,
                    content: message.content,
                    reasoningContent: message.reasoningContent,
                    attachments: message.attachments
                )
            }
        )
        return messages
    }

    private static func replacingSystemPrompt(
        in messages: [MLXServerChatMessage],
        with systemPrompt: String?
    ) -> [MLXServerChatMessage] {
        let prompt = systemPrompt?.nilIfBlank
        var updatedMessages = messages
        if updatedMessages.first?.role == .system {
            if let prompt {
                updatedMessages[0] = .system(prompt)
            } else {
                updatedMessages.removeFirst()
            }
        } else if let prompt {
            updatedMessages.insert(.system(prompt), at: 0)
        }
        return updatedMessages
    }

    private static func snapshotMessages(
        from messages: [MLXServerChatMessage]
    ) -> (systemPrompt: String?, history: [AgentRuntimeMessage]) {
        var remainingMessages = messages[...]
        let systemPrompt: String?
        if remainingMessages.first?.role == .system {
            systemPrompt = remainingMessages.first?.content.nilIfBlank
            remainingMessages = remainingMessages.dropFirst()
        } else {
            systemPrompt = nil
        }

        return (
            systemPrompt,
            remainingMessages.map(snapshotMessage(from:))
        )
    }

    private static func snapshotMessage(
        from message: MLXServerChatMessage
    ) -> AgentRuntimeMessage {
        let attachments =
            message.imageURLs.map {
                AgentRuntimeAttachment(
                    kind: .image,
                    fileURL: $0,
                    originalFilename: $0.lastPathComponent
                )
            }
            + message.videoURLs.map {
                AgentRuntimeAttachment(
                    kind: .video,
                    fileURL: $0,
                    originalFilename: $0.lastPathComponent
                )
            }
        let toolCalls = message.toolCalls.map { toolCall in
            AgentRuntimeToolCall(
                id: toolCall.id,
                name: toolCall.function.name,
                argumentsJSON: jsonString(
                    from: toolCall.function.arguments.mapValues(\.anyValue)
                ) ?? "{}"
            )
        }
        return AgentRuntimeMessage(
            role: AgentRuntimeMessage.Role(rawValue: message.role.rawValue) ?? .user,
            content: message.content,
            reasoningContent: message.reasoningContent,
            attachments: attachments,
            toolCalls: toolCalls,
            toolCallID: message.toolCallID
        )
    }

    private static func agentRuntimeMessage(
        from message: MLXServerChatMessage
    ) -> AgentRuntimeMessage {
        let attachments =
            message.imageURLs.map {
                AgentRuntimeAttachment(
                    kind: .image,
                    fileURL: $0,
                    originalFilename: $0.lastPathComponent
                )
            }
            + message.videoURLs.map {
                AgentRuntimeAttachment(
                    kind: .video,
                    fileURL: $0,
                    originalFilename: $0.lastPathComponent
                )
            }
        return AgentRuntimeMessage(
            role: AgentRuntimeMessage.Role(rawValue: message.role.rawValue) ?? .user,
            content: Self.compactionContent(from: message),
            attachments: attachments
        )
    }

    private static func compactionContent(from message: MLXServerChatMessage) -> String {
        var sections: [String] = []
        if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(message.content)
        }
        if !message.toolCalls.isEmpty {
            let names = message.toolCalls.map(\.function.name).joined(separator: ", ")
            sections.append("Assistant requested tools: \(names).")
        }
        if message.role == .tool, let toolCallID = message.toolCallID?.nilIfBlank {
            sections.append("Tool result id: \(toolCallID).")
        }
        return sections.joined(separator: "\n\n")
    }

    private static func serverMessage(
        from message: AgentRuntimeMessage
    ) -> MLXServerChatMessage {
        serverMessage(
            role: message.role,
            content: message.content,
            reasoningContent: message.reasoningContent,
            attachments: message.attachments,
            toolCalls: message.toolCalls,
            toolCallID: message.toolCallID
        )
    }

    private static func serverMessage(
        role: AgentRuntimeMessage.Role,
        content: String,
        reasoningContent: String? = nil,
        attachments: [AgentRuntimeAttachment],
        toolCalls runtimeToolCalls: [AgentRuntimeToolCall] = [],
        toolCallID: String? = nil
    ) -> MLXServerChatMessage {
        let imageURLs = attachments.compactMap { attachment -> URL? in
            attachment.kind == .image ? attachment.fileURL : nil
        }
        let videoURLs = attachments.compactMap { attachment -> URL? in
            attachment.kind == .video ? attachment.fileURL : nil
        }

        switch role {
        case .system:
            return .system(content)
        case .user:
            return .user(content, imageURLs: imageURLs, videoURLs: videoURLs)
        case .assistant:
            let toolCalls = runtimeToolCalls.map { toolCall in
                MLXServerChatToolCall(
                    id: toolCall.id,
                    name: toolCall.name,
                    arguments: sendableJSONObject(from: toolCall.argumentsJSON) ?? [:]
                )
            }
            return .assistant(
                content,
                reasoningContent: reasoningContent,
                toolCalls: toolCalls
            )
        case .tool:
            return .tool(content, toolCallID: toolCallID)
        }
    }

    private static func directToolCall(from toolCall: ToolCall) -> DirectAgentToolCall {
        let argumentsObject = toolCall.function.arguments.mapValues(\.anyValue)
        return DirectAgentToolCall(
            id: "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())",
            name: toolCall.function.name,
            argumentsObject: argumentsObject,
            argumentsJSON: jsonString(from: argumentsObject) ?? "{}"
        )
    }

    private static func sendableJSONObject(from jsonString: String) -> [String: any Sendable]? {
        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONDecoder().decode(MLXCoderCore.JSONValue.self, from: data).mlxObjectValue else {
            return nil
        }
        var sendableObject: [String: any Sendable] = [:]
        for (key, value) in object {
            sendableObject[key] = value.sendableValue
        }
        return sendableObject
    }

    private static func jsonString(from object: [String: Any]) -> String? {
        JSONValue(jsonObject: object).compactString(sortedKeys: true)
    }
}

private extension MLXCoderCore.JSONValue {
    var sendableValue: any Sendable {
        switch self {
        case let .string(value):
            return value
        case let .number(value):
            return value
        case let .object(value):
            return value.mapValues(\.sendableValue)
        case let .array(value):
            return value.map(\.sendableValue)
        case let .bool(value):
            return value
        case .null:
            return self
        }
    }
}

private struct MLXServerCoderTranscriptSplitter {
    enum Part {
        case content(String)
        case thought(String)
    }

    private static let openTag = "<think>"
    private static let closeTag = "</think>"
    private var isThinking: Bool
    private var pending = ""

    init(startsInThinking: Bool) {
        self.isThinking = startsInThinking
    }

    mutating func consume(_ chunk: String) -> [Part] {
        pending += chunk
        var parts: [Part] = []

        while !pending.isEmpty {
            if isThinking {
                if let closeRange = pending.range(of: Self.closeTag) {
                    let thought = String(pending[..<closeRange.lowerBound])
                    if !thought.isEmpty {
                        parts.append(.thought(thought))
                    }
                    pending.removeSubrange(pending.startIndex..<closeRange.upperBound)
                    isThinking = false
                    continue
                }

                let safePrefix = pending.removingSuffixThatCanStart(Self.closeTag)
                guard !safePrefix.isEmpty else {
                    break
                }
                parts.append(.thought(safePrefix))
                pending.removeFirst(safePrefix.count)
            } else {
                if let openRange = pending.range(of: Self.openTag) {
                    let content = String(pending[..<openRange.lowerBound])
                    if !content.isEmpty {
                        parts.append(.content(content))
                    }
                    pending.removeSubrange(pending.startIndex..<openRange.upperBound)
                    isThinking = true
                    continue
                }

                let safePrefix = pending.removingSuffixThatCanStart(Self.openTag)
                guard !safePrefix.isEmpty else {
                    break
                }
                parts.append(.content(safePrefix))
                pending.removeFirst(safePrefix.count)
            }
        }

        return parts
    }

    mutating func finish() -> [Part] {
        guard !pending.isEmpty else {
            return []
        }
        let value = pending
        pending = ""
        return [isThinking ? .thought(value) : .content(value)]
    }
}

private enum MLXServerCoderBackendError: LocalizedError {
    case missingSession
    case tooManyToolRounds(Int)

    var errorDescription: String? {
        switch self {
        case .missingSession:
            return "The mlx-coder direct session is no longer available."
        case .tooManyToolRounds(let rounds):
            return "Stopped after \(rounds) tool rounds without a final assistant response."
        }
    }
}

private extension String {
    func removingSuffixThatCanStart(_ marker: String) -> String {
        var suffixLength = min(count, max(marker.count - 1, 0))
        while suffixLength > 0 {
            let suffix = String(suffix(suffixLength))
            if marker.hasPrefix(suffix) {
                return String(dropLast(suffixLength))
            }
            suffixLength -= 1
        }
        return self
    }
}
