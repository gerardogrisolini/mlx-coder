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
        var allowedToolNames: Set<String>?
        var thinkingSelection: AgentThinkingSelection?
        var preserveThinking: Bool
    }

    private struct GenerationTurn {
        var visibleText: String
        var reasoningText: String
        var toolCalls: [ToolCall]
        var completionInfo: GenerateCompletionInfo?
    }

    private let configuration: AgentRuntimeConfiguration
    private let runtime: MLXServerRuntime
    private let model: MLXServerModelDescriptor
    private let toolExecutor: DirectToolExecutor
    private var sessions: [String: SessionState] = [:]
    private var didEmitLoadedModel = false

    init(
        configuration: AgentRuntimeConfiguration,
        runtime: MLXServerRuntime,
        model: MLXServerModelDescriptor,
        mcpRuntime: DirectMCPToolRuntime
    ) {
        self.configuration = configuration
        self.runtime = runtime
        self.model = model
        self.toolExecutor = DirectToolExecutor(
            outputLimit: 24_000,
            authorizationHandler: configuration.toolAuthorizationHandler,
            mcpRuntime: mcpRuntime,
            subAgentBackendFactory: {
                MLXServerCoderBackend(
                    configuration: configuration,
                    runtime: runtime,
                    model: model,
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
        cacheKey _: String?,
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
        didEmitLoadedModel = true
        await onEvent(.modelLoaded(model.id))
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

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        await toolExecutor.descriptors()
    }

    func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        await toolExecutor.subAgentSnapshots()
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
            let turn = try await runGenerationTurn(
                request: request,
                onEvent: onEvent
            )
            appendAssistantTurn(turn, to: &session)
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

            for toolCall in turn.toolCalls {
                let directToolCall = Self.directToolCall(from: toolCall)
                await onEvent(.toolCallStarted(directToolCall))
                let result = await toolExecutor.execute(
                    sessionID: sessionID,
                    toolCall: directToolCall,
                    workingDirectory: session.cwd,
                    allowedToolNames: session.allowedToolNames
                )
                await onEvent(.toolCallCompleted(directToolCall, result))
                session.messages.append(
                    .tool(
                        MLXServerToolTranscript.toolOutput(
                            callID: directToolCall.id,
                            output: result.output
                        )
                    )
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
            maxTokens: configuration.maxOutputTokens ?? overrides.maxTokens
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
        if !turn.visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            session.messages.append(.assistant(turn.visibleText))
        }
        for toolCall in turn.toolCalls {
            session.messages.append(.assistant(MLXServerToolTranscript.toolCall(toolCall)))
        }
        if turn.visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           turn.reasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           turn.toolCalls.isEmpty {
            session.messages.append(.assistant(""))
        }
    }

    private func emitMetrics(
        _ info: GenerateCompletionInfo,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async {
        await onEvent(
            .metrics(
                DirectAgentGenerationMetrics(
                    promptTokenCount: info.promptTokenCount,
                    promptTokensPerSecond: info.promptTokensPerSecond,
                    completionTokenCount: info.generationTokenCount,
                    completionTokensPerSecond: info.tokensPerSecond,
                    contextTokenCount: info.promptTokenCount + info.generationTokenCount
                )
            )
        )
        await onEvent(
            .contextWindow(
                DirectAgentContextWindowStatus(
                    usedTokens: info.promptTokenCount + info.generationTokenCount,
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
                    attachments: message.attachments
                )
            }
        )
        return messages
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
            content: message.content,
            attachments: attachments
        )
    }

    private static func serverMessage(
        from message: AgentRuntimeMessage
    ) -> MLXServerChatMessage {
        serverMessage(
            role: message.role,
            content: message.content,
            attachments: message.attachments
        )
    }

    private static func serverMessage(
        role: AgentRuntimeMessage.Role,
        content: String,
        attachments: [AgentRuntimeAttachment]
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
            return .assistant(content)
        case .tool:
            return .tool(content)
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
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var sendableObject: [String: any Sendable] = [:]
        for (key, value) in object {
            sendableObject[key] = sendableJSONValue(value)
        }
        return sendableObject
    }

    private static func sendableJSONValue(_ value: Any) -> any Sendable {
        switch value {
        case let value as [String: Any]:
            var object: [String: any Sendable] = [:]
            for (key, nestedValue) in value {
                object[key] = sendableJSONValue(nestedValue)
            }
            return object
        case let value as [Any]:
            var array: [any Sendable] = []
            array.reserveCapacity(value.count)
            for nestedValue in value {
                array.append(sendableJSONValue(nestedValue))
            }
            return array
        case let value as String:
            return value
        case let value as Bool:
            return value
        case let value as Int:
            return value
        case let value as Double:
            return value
        case let value as NSNumber:
            let objectiveCType = String(cString: value.objCType)
            if objectiveCType == "c" || objectiveCType == "B" {
                return value.boolValue
            }
            if value.doubleValue.rounded() == value.doubleValue {
                return value.intValue
            }
            return value.doubleValue
        case is NSNull:
            return "null"
        default:
            return String(describing: value)
        }
    }

    private static func jsonString(from object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.sortedKeys]
              ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
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
