//
//  MLXServerRuntime.swift
//  mlx-coder
//

import CryptoKit
import Foundation
import MLX
@preconcurrency import MLXLMCommon
import Tokenizers

public struct MLXServerChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable, Hashable {
        case system
        case user
        case assistant
        case tool
    }

    public var role: Role
    public var content: String
    public var reasoningContent: String?
    public var imageURLs: [URL]
    public var videoURLs: [URL]
    public var toolCalls: [MLXServerChatToolCall]
    public var toolCallID: String?
    public var toolName: String?

    public init(
        role: Role,
        content: String,
        reasoningContent: String? = nil,
        imageURLs: [URL] = [],
        videoURLs: [URL] = [],
        toolCalls: [MLXServerChatToolCall] = [],
        toolCallID: String? = nil,
        toolName: String? = nil
    ) {
        self.role = role
        self.content = content
        let trimmedReasoningContent = reasoningContent?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.reasoningContent = trimmedReasoningContent?.isEmpty == false
            ? trimmedReasoningContent
            : nil
        self.imageURLs = imageURLs
        self.videoURLs = videoURLs
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        let trimmedToolName = toolName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.toolName = trimmedToolName?.isEmpty == false ? trimmedToolName : nil
    }

    public static func system(_ content: String) -> Self {
        Self(role: .system, content: content)
    }

    public static func user(
        _ content: String,
        imageURLs: [URL] = [],
        videoURLs: [URL] = []
    ) -> Self {
        Self(role: .user, content: content, imageURLs: imageURLs, videoURLs: videoURLs)
    }

    public static func assistant(
        _ content: String,
        reasoningContent: String? = nil,
        toolCalls: [MLXServerChatToolCall] = []
    ) -> Self {
        Self(
            role: .assistant,
            content: content,
            reasoningContent: reasoningContent,
            toolCalls: toolCalls
        )
    }

    public static func tool(
        _ content: String,
        toolCallID: String? = nil,
        toolName: String? = nil
    ) -> Self {
        Self(role: .tool, content: content, toolCallID: toolCallID, toolName: toolName)
    }
}

public struct MLXServerChatToolCall: Sendable, Equatable {
    public var id: String?
    public var function: ToolCall.Function

    public init(
        id: String? = nil,
        function: ToolCall.Function
    ) {
        self.id = id
        self.function = function
    }

    public init(
        id: String? = nil,
        name: String,
        arguments: [String: any Sendable]
    ) {
        self.id = id
        self.function = .init(name: name, arguments: arguments)
    }

    public init(id: String? = nil, toolCall: ToolCall) {
        self.id = id
        self.function = toolCall.function
    }

    public var toolCall: ToolCall {
        ToolCall(function: function)
    }
}

public struct MLXServerGenerationRequest: Sendable {
    public var model: MLXServerModelDescriptor
    public var messages: [MLXServerChatMessage]
    public var parameters: GenerateParameters
    public var mediaResize: CGSize?
    public var tools: [ToolSpec]?
    public var additionalContext: [String: any Sendable]?
    public var retainsReasoningInHistory: Bool
    /// Client-provided session identifier used to key the in-memory
    /// `ChatSession` and the disk KV cache entry. When absent, a stable
    /// key is derived from the conversation opening.
    public var sessionID: String?

    public init(
        model: MLXServerModelDescriptor,
        messages: [MLXServerChatMessage],
        parameters: GenerateParameters = GenerateParameters(),
        mediaResize: CGSize? = nil,
        tools: [ToolSpec]? = nil,
        additionalContext: [String: any Sendable]? = nil,
        retainsReasoningInHistory: Bool = false,
        sessionID: String? = nil
    ) {
        self.model = model
        self.messages = messages
        self.parameters = parameters
        self.mediaResize = mediaResize
        self.tools = tools
        self.additionalContext = additionalContext
        self.retainsReasoningInHistory = retainsReasoningInHistory
        let trimmedSessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sessionID = trimmedSessionID?.isEmpty == false ? trimmedSessionID : nil
    }

    public var requiresVisionRuntime: Bool {
        messages.contains { message in
            !message.imageURLs.isEmpty || !message.videoURLs.isEmpty
        }
    }

    public var runtimeKind: MLXServerModelRuntimeKind {
        requiresVisionRuntime ? .vlm : model.runtimeKind
    }

    public var emitsThinking: Bool {
        additionalContext?["enable_thinking"] as? Bool ?? false
    }

    /// Effective session key: the client-provided identifier, or a stable
    /// derivation from the conversation opening for stateless clients.
    public var effectiveSessionKey: String {
        sessionID ?? MLXServerChatSessionTranscript.derivedSessionKey(messages: messages)
    }
}

public struct MLXServerGenerationParameterSnapshot: Sendable, Equatable {
    public var maxTokens: Int?
    public var maxKVSize: Int?
    public var kvBits: Int?
    public var kvGroupSize: Int
    public var quantizedKVStart: Int
    public var temperature: Float
    public var topP: Float
    public var topK: Int
    public var minP: Float
    public var repetitionPenalty: Float?
    public var repetitionContextSize: Int
    public var presencePenalty: Float?
    public var presenceContextSize: Int
    public var frequencyPenalty: Float?
    public var frequencyContextSize: Int
    public var prefillStepSize: Int

    public init(parameters: GenerateParameters) {
        self.maxTokens = parameters.maxTokens
        self.maxKVSize = parameters.maxKVSize
        self.kvBits = parameters.kvBits
        self.kvGroupSize = parameters.kvGroupSize
        self.quantizedKVStart = parameters.quantizedKVStart
        self.temperature = parameters.temperature
        self.topP = parameters.topP
        self.topK = parameters.topK
        self.minP = parameters.minP
        self.repetitionPenalty = parameters.repetitionPenalty
        self.repetitionContextSize = parameters.repetitionContextSize
        self.presencePenalty = parameters.presencePenalty
        self.presenceContextSize = parameters.presenceContextSize
        self.frequencyPenalty = parameters.frequencyPenalty
        self.frequencyContextSize = parameters.frequencyContextSize
        self.prefillStepSize = parameters.prefillStepSize
    }
}

public struct MLXServerModelLoadEvent: Sendable, Equatable {
    public var modelID: String
    public var runtimeKind: MLXServerModelRuntimeKind
    public var generationDefaults: MLXServerModelGenerationDefaults
    public var parameters: MLXServerGenerationParameterSnapshot

    public init(
        model: MLXServerModelDescriptor,
        runtimeKind: MLXServerModelRuntimeKind,
        parameters: GenerateParameters
    ) {
        self.modelID = model.id
        self.runtimeKind = runtimeKind
        self.generationDefaults = model.generationDefaults
        self.parameters = MLXServerGenerationParameterSnapshot(parameters: parameters)
    }
}

public struct MLXServerModelUnloadEvent: Sendable, Equatable {
    public var modelID: String

    public init(modelID: String) {
        self.modelID = modelID
    }
}

public enum MLXServerModelRetentionPolicy: Sendable, Equatable {
    case keepLoadedModels
    case unloadPreviousModel
}

public struct MLXServerGenerationOutput: Sendable {
    public var text: String
    public var toolCalls: [ToolCall]
    public var info: GenerateCompletionInfo?

    public init(text: String, toolCalls: [ToolCall] = [], info: GenerateCompletionInfo?) {
        self.text = text
        self.toolCalls = toolCalls
        self.info = info
    }
}

public enum MLXServerRuntimeError: LocalizedError, Sendable, Equatable {
    case emptyPrompt

    public var errorDescription: String? {
        switch self {
        case .emptyPrompt:
            "Prompt can not be empty."
        }
    }
}

public struct MLXServerChatCacheEvent: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        case memoryHit = "memory_hit"
        case diskHit = "disk_hit"
        case diskPrefixHit = "disk_prefix_hit"
        case miss
    }

    public var status: Status
    public var cachedSessionCount: Int
    public var modelSessionCount: Int
    public var priorTranscriptCount: Int
    public var bestCommonPrefixCount: Int
    public var bestCachedTranscriptCount: Int
    public var bestModelCommonPrefixCount: Int
    public var bestModelCachedTranscriptCount: Int
    public var bestModelSameSystemSignature: Bool?
    public var bestModelSameToolsSignature: Bool?
    public var bestModelSameAdditionalContextSignature: Bool?
    public var bestModelSameMediaResizeSignature: Bool?
    public var bestModelSameReasoningRetention: Bool?
    public var restoredPromptPrefixTokenCount: Int?
    public var cachedPromptTokenCount: Int?

    public init(
        status: Status,
        cachedSessionCount: Int,
        modelSessionCount: Int,
        priorTranscriptCount: Int,
        bestCommonPrefixCount: Int,
        bestCachedTranscriptCount: Int,
        bestModelCommonPrefixCount: Int = 0,
        bestModelCachedTranscriptCount: Int = 0,
        bestModelSameSystemSignature: Bool? = nil,
        bestModelSameToolsSignature: Bool? = nil,
        bestModelSameAdditionalContextSignature: Bool? = nil,
        bestModelSameMediaResizeSignature: Bool? = nil,
        bestModelSameReasoningRetention: Bool? = nil,
        restoredPromptPrefixTokenCount: Int? = nil,
        cachedPromptTokenCount: Int? = nil
    ) {
        self.status = status
        self.cachedSessionCount = cachedSessionCount
        self.modelSessionCount = modelSessionCount
        self.priorTranscriptCount = priorTranscriptCount
        self.bestCommonPrefixCount = bestCommonPrefixCount
        self.bestCachedTranscriptCount = bestCachedTranscriptCount
        self.bestModelCommonPrefixCount = bestModelCommonPrefixCount
        self.bestModelCachedTranscriptCount = bestModelCachedTranscriptCount
        self.bestModelSameSystemSignature = bestModelSameSystemSignature
        self.bestModelSameToolsSignature = bestModelSameToolsSignature
        self.bestModelSameAdditionalContextSignature = bestModelSameAdditionalContextSignature
        self.bestModelSameMediaResizeSignature = bestModelSameMediaResizeSignature
        self.bestModelSameReasoningRetention = bestModelSameReasoningRetention
        self.restoredPromptPrefixTokenCount = restoredPromptPrefixTokenCount
        self.cachedPromptTokenCount = cachedPromptTokenCount
    }
}

public protocol MLXServerRuntimeGenerating: Sendable {
    func generateChatSession(
        request: MLXServerGenerationRequest
    ) async throws -> AsyncThrowingStream<Generation, Error>

    func generateChatSessionText(
        request: MLXServerGenerationRequest
    ) async throws -> MLXServerGenerationOutput
}

public protocol MLXServerRuntimeCacheDiagnosing: Sendable {
    func consumeLastChatCacheEvent() async -> MLXServerChatCacheEvent?
}

extension MLXServerRuntime: MLXServerRuntimeGenerating {
    public func generateChatSession(
        request: MLXServerGenerationRequest
    ) async throws -> AsyncThrowingStream<Generation, Error> {
        try await generateChatSession(request: request, progressHandler: { _ in })
    }

    public func generateChatSessionText(
        request: MLXServerGenerationRequest
    ) async throws -> MLXServerGenerationOutput {
        try await generateChatSessionText(request: request, progressHandler: { _ in })
    }
}

extension MLXServerRuntime: MLXServerRuntimeCacheDiagnosing {
    public func consumeLastChatCacheEvent() async -> MLXServerChatCacheEvent? {
        defer {
            lastChatCacheEvent = nil
        }
        return lastChatCacheEvent
    }
}

public enum MLXServerReasoningTranscript {
    public static func reasoningSummary(_ text: String) -> String {
        "reasoning_summary:\n\(text)"
    }
}

public actor MLXServerRuntime {
    private var containers: [LoadedModelKey: ModelContainer] = [:]
    private var loadingTasks: [LoadedModelKey: ModelLoadingTask] = [:]

    /// In-memory chat sessions, keyed by session identity. The KV cache for
    /// each session is owned by MLXLMCommon's `ChatSession`; the runtime
    /// only tracks which transcript each session represents.
    private var chatSessions: [MLXServerChatSessionCacheKey: ChatSessionState] = [:]
    private var chatSessionAccessGeneration: UInt64 = 0
    private let maxChatSessionCount: Int

    private let generationGates = MLXServerPerModelGenerationGate()
    private let retentionPolicy: MLXServerModelRetentionPolicy
    private let diskKVCacheStore: MLXServerDiskKVCacheStore?
    private let modelLoadLogger: (@Sendable (MLXServerModelLoadEvent) -> Void)?
    private let modelUnloadLogger: (@Sendable (MLXServerModelUnloadEvent) -> Void)?
    private var lastChatCacheEvent: MLXServerChatCacheEvent?

    /// Default bound on resident chat sessions. Each session retains a full
    /// KV cache in unified memory, so the registry stays intentionally
    /// small. Disk persistence is explicit and tied to saved sessions.
    public static let defaultMaxChatSessionCount = 4

    public init(
        retentionPolicy: MLXServerModelRetentionPolicy = .keepLoadedModels,
        diskKVCacheConfiguration: MLXServerDiskKVCacheConfiguration = .init(),
        maxChatSessionCount: Int = MLXServerRuntime.defaultMaxChatSessionCount,
        modelLoadLogger: (@Sendable (MLXServerModelLoadEvent) -> Void)? = nil,
        modelUnloadLogger: (@Sendable (MLXServerModelUnloadEvent) -> Void)? = nil
    ) {
        self.retentionPolicy = retentionPolicy
        self.maxChatSessionCount = max(1, maxChatSessionCount)
        if diskKVCacheConfiguration.isEnabled {
            self.diskKVCacheStore = MLXServerDiskKVCacheStore(configuration: diskKVCacheConfiguration)
        } else {
            self.diskKVCacheStore = nil
        }
        self.modelLoadLogger = modelLoadLogger
        self.modelUnloadLogger = modelUnloadLogger
    }

    public var loadedModelIDs: [String] {
        containers.keys.map(\.displayName).sorted()
    }

    public func preloadModel(
        model: MLXServerModelDescriptor,
        runtimeKind: MLXServerModelRuntimeKind? = nil,
        parameters: GenerateParameters,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws {
        let generationLease = try await generationGates.acquire(modelID: model.id)
        do {
            _ = try await container(
                for: model,
                runtimeKind: runtimeKind ?? model.runtimeKind,
                parameters: parameters,
                progressHandler: progressHandler
            )
            await generationLease.release()
        } catch {
            await generationLease.release()
            throw error
        }
    }

    public func unloadAll() async {
        guard let generationLeases = try? await generationGates.acquireAll() else {
            return
        }
        let unloadedModelIDs = Set(containers.keys.map(\.modelID)).sorted()
        for loadingTask in loadingTasks.values {
            loadingTask.task.cancel()
        }
        containers.removeAll(keepingCapacity: true)
        loadingTasks.removeAll(keepingCapacity: true)
        chatSessions.removeAll(keepingCapacity: true)
        logUnloadedModels(unloadedModelIDs)
        await generationLeases.releaseAll()
    }

    public func generate(
        request: MLXServerGenerationRequest,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> AsyncStream<Generation> {
        let generationLease = try await generationGates.acquire(modelID: request.model.id)

        do {
            let container = try await container(
                for: request.model,
                runtimeKind: request.runtimeKind,
                parameters: request.parameters,
                progressHandler: progressHandler
            )
            let input = UserInput(
                chat: request.messages.map(\.mlxChatMessage),
                processing: .init(resize: request.mediaResize),
                tools: request.tools,
                additionalContext: request.additionalContext
            )
            let lmInput = try await container.prepare(input: input)
            let parameters = request.parameters
            let tools = request.tools
            let stream = try await container.perform(nonSendable: lmInput) { context, input in
                try MLXLMCommon.generate(
                    input: input,
                    parameters: parameters,
                    context: context,
                    tools: tools
                )
            }

            return AsyncStream { continuation in
                let task = Task {
                    for await event in stream {
                        if Task.isCancelled {
                            break
                        }
                        continuation.yield(event)
                    }
                    await generationLease.release()
                    continuation.finish()
                }
                continuation.onTermination = { _ in
                    task.cancel()
                }
            }
        } catch {
            await generationLease.release()
            throw error
        }
    }

    public func generateChatSession(
        request: MLXServerGenerationRequest,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> AsyncThrowingStream<Generation, Error> {
        guard request.messages.allSatisfy({ $0.imageURLs.isEmpty && $0.videoURLs.isEmpty }) else {
            let stream = try await generate(request: request, progressHandler: progressHandler)
            return AsyncThrowingStream { continuation in
                let task = Task {
                    for await item in stream {
                        if Task.isCancelled {
                            break
                        }
                        continuation.yield(item)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in
                    task.cancel()
                }
            }
        }
        guard !request.messages.isEmpty else {
            throw MLXServerRuntimeError.emptyPrompt
        }

        let generationLease = try await generationGates.acquire(modelID: request.model.id)

        let resolved: ResolvedChatSession
        do {
            let container = try await container(
                for: request.model,
                runtimeKind: request.runtimeKind,
                parameters: request.parameters,
                progressHandler: progressHandler
            )
            resolved = await resolveChatSession(request: request, container: container)
        } catch {
            await generationLease.release()
            throw error
        }

        let cacheKey = resolved.cacheKey
        let requestFingerprints = request.messages.map(\.transcriptFingerprint)
        let toolsSignature = MLXServerChatSessionRequestSignature.tools(request.tools)
        let contextSignature = MLXServerChatSessionRequestSignature.additionalContext(
            request.additionalContext
        )
        let sessionTransfer = resolved.sessionTransfer
        let cachedPromptTokenCount = resolved.cachedPromptTokenCount
        let throwingStream: AsyncStream<Generation>
        do {
            throwingStream = try await sessionTransfer.session.streamDetails(
                request: request,
                cachedPromptTokenCount: cachedPromptTokenCount,
                cachedPrefixMessageCount: resolved.cachedPrefixMessageCount
            )
        } catch {
            discardChatSession(for: cacheKey)
            await generationLease.release()
            throw error
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                var completionInfo: GenerateCompletionInfo?
                var wasCancelled = false
                for await item in throwingStream {
                    if Task.isCancelled {
                        wasCancelled = true
                        break
                    }
                    if case .info(let info) = item {
                        completionInfo = info
                    }
                    continuation.yield(item)
                }

                if wasCancelled || Task.isCancelled {
                    // A cancelled turn leaves a truncated assistant turn in
                    // the KV cache; storing it would make later requests
                    // continue on top of tokens that do not match the
                    // client transcript. Drop the session instead.
                    self.discardChatSession(for: cacheKey)
                    await generationLease.release()
                    continuation.finish(throwing: CancellationError())
                    return
                }

                self.finishChatSessionTurn(
                    cacheKey: cacheKey,
                    sessionTransfer: sessionTransfer,
                    requestFingerprints: requestFingerprints,
                    toolsSignature: toolsSignature,
                    contextSignature: contextSignature,
                    cachedPromptTokenCount: cachedPromptTokenCount,
                    completionInfo: completionInfo
                )
                await generationLease.release()
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func generateText(
        request: MLXServerGenerationRequest,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> MLXServerGenerationOutput {
        let stream = try await generate(request: request, progressHandler: progressHandler)
        return await Self.collectGenerationOutput(stream)
    }

    public func generateChatSessionText(
        request: MLXServerGenerationRequest,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> MLXServerGenerationOutput {
        let stream = try await generateChatSession(request: request, progressHandler: progressHandler)
        return try await Self.collectThrowingGenerationOutput(stream)
    }

    private static func collectGenerationOutput(
        _ stream: AsyncStream<Generation>
    ) async -> MLXServerGenerationOutput {
        var text = ""
        var toolCalls: [ToolCall] = []
        var info: GenerateCompletionInfo?

        for await event in stream {
            switch event {
            case .chunk(let chunk):
                text += chunk
            case .info(let completionInfo):
                info = completionInfo
            case .toolCall(let toolCall):
                toolCalls.append(toolCall)
            }
        }

        return MLXServerGenerationOutput(text: text, toolCalls: toolCalls, info: info)
    }

    private static func collectThrowingGenerationOutput(
        _ stream: AsyncThrowingStream<Generation, Error>
    ) async throws -> MLXServerGenerationOutput {
        var text = ""
        var toolCalls: [ToolCall] = []
        var info: GenerateCompletionInfo?

        for try await event in stream {
            switch event {
            case .chunk(let chunk):
                text += chunk
            case .info(let completionInfo):
                info = completionInfo
            case .toolCall(let toolCall):
                toolCalls.append(toolCall)
            }
        }

        return MLXServerGenerationOutput(text: text, toolCalls: toolCalls, info: info)
    }

    // MARK: - Chat session resolution

    private struct ChatSessionState {
        var sessionTransfer: ChatSessionTransfer
        var fingerprints: [MLXServerChatTranscriptFingerprint]
        var toolsSignature: String
        var contextSignature: String
        var contextTokenCount: Int?
        var lastAccessGeneration: UInt64
    }

    private struct ResolvedChatSession {
        var cacheKey: MLXServerChatSessionCacheKey
        var sessionTransfer: ChatSessionTransfer
        var cachedPrefixMessageCount: Int
        var cachedPromptTokenCount: Int?
    }

    /// Finds or builds the `ChatSession` able to serve the request:
    /// in-memory continuation first, then a fresh session that prefills the
    /// whole transcript. Disk restore is only performed when a previously
    /// saved session is explicitly loaded.
    private func resolveChatSession(
        request: MLXServerGenerationRequest,
        container: ModelContainer
    ) async -> ResolvedChatSession {
        let cacheKey = MLXServerChatSessionCacheKey(
            sessionKey: request.effectiveSessionKey,
            modelID: request.model.id,
            runtimeKind: request.runtimeKind,
            cacheLayoutSignature: MLXServerChatSessionCacheSignature.cacheLayout(request.parameters)
        )
        let requestFingerprints = request.messages.map(\.transcriptFingerprint)
        let toolsSignature = MLXServerChatSessionRequestSignature.tools(request.tools)
        let contextSignature = MLXServerChatSessionRequestSignature.additionalContext(
            request.additionalContext
        )
        let modelSessionCount = chatSessions.keys.count { $0.modelID == request.model.id }

        // 1. In-memory continuation via the live ChatSession.
        if let state = chatSessions[cacheKey] {
            if state.toolsSignature == toolsSignature,
               state.contextSignature == contextSignature,
               let suffixStartIndex = MLXServerChatSessionTranscript.continuationSuffixStartIndex(
                   stored: state.fingerprints,
                   request: requestFingerprints
               ) {
                // Check the session out of the registry for the duration of
                // the turn; it is re-inserted with updated fingerprints when
                // the turn finishes.
                chatSessions[cacheKey] = nil
                lastChatCacheEvent = MLXServerChatCacheEvent(
                    status: .memoryHit,
                    cachedSessionCount: 1,
                    modelSessionCount: modelSessionCount,
                    priorTranscriptCount: requestFingerprints.count,
                    bestCommonPrefixCount: suffixStartIndex,
                    bestCachedTranscriptCount: state.fingerprints.count,
                    cachedPromptTokenCount: state.contextTokenCount
                )
                return ResolvedChatSession(
                    cacheKey: cacheKey,
                    sessionTransfer: state.sessionTransfer,
                    cachedPrefixMessageCount: suffixStartIndex,
                    cachedPromptTokenCount: state.contextTokenCount
                )
            }
            // Same session key but incompatible signatures or a diverged
            // transcript: the cached session cannot serve this request.
            chatSessions[cacheKey] = nil
        }

        // 2. Fresh session: the whole transcript is prefilled this turn.
        let session = MLXServerRawChatSession(
            container,
            cache: nil
        )
        lastChatCacheEvent = MLXServerChatCacheEvent(
            status: .miss,
            cachedSessionCount: 0,
            modelSessionCount: modelSessionCount,
            priorTranscriptCount: requestFingerprints.count,
            bestCommonPrefixCount: 0,
            bestCachedTranscriptCount: 0
        )
        return ResolvedChatSession(
            cacheKey: cacheKey,
            sessionTransfer: ChatSessionTransfer(session: session),
            cachedPrefixMessageCount: 0,
            cachedPromptTokenCount: nil
        )
    }

    private static func chatSessionCacheKey(
        for request: MLXServerGenerationRequest
    ) -> MLXServerChatSessionCacheKey {
        MLXServerChatSessionCacheKey(
            sessionKey: request.effectiveSessionKey,
            modelID: request.model.id,
            runtimeKind: request.runtimeKind,
            cacheLayoutSignature: MLXServerChatSessionCacheSignature.cacheLayout(request.parameters)
        )
    }

    /// Runs the explicit disk lookup off the actor executor so heavy
    /// safetensors reads do not block other runtime requests.
    private static func diskChatSessionMatch(
        store: MLXServerDiskKVCacheStore?,
        key: MLXServerChatSessionCacheKey,
        toolsSignature: String,
        contextSignature: String,
        requestFingerprints: [MLXServerChatTranscriptFingerprint],
        acceptsCompleteMatch: Bool
    ) async -> MLXServerDiskChatSessionMatch? {
        guard let store, store.isEnabled else {
            return nil
        }
        return await Task.detached(priority: .userInitiated) {
            store.loadSession(
                for: key,
                toolsSignature: toolsSignature,
                contextSignature: contextSignature,
                requestFingerprints: requestFingerprints,
                acceptsCompleteMatch: acceptsCompleteMatch
            )
        }.value
    }

    /// Stores the session back into the registry at turn end.
    private func finishChatSessionTurn(
        cacheKey: MLXServerChatSessionCacheKey,
        sessionTransfer: ChatSessionTransfer,
        requestFingerprints: [MLXServerChatTranscriptFingerprint],
        toolsSignature: String,
        contextSignature: String,
        cachedPromptTokenCount: Int?,
        completionInfo: GenerateCompletionInfo?
    ) {
        let fingerprints = requestFingerprints
            + [MLXServerChatTranscriptFingerprint.generatedAssistantPlaceholder]
        let contextTokenCount = Self.contextTokenCount(
            cachedPromptTokenCount: cachedPromptTokenCount,
            completionInfo: completionInfo
        )
        chatSessionAccessGeneration += 1
        let state = ChatSessionState(
            sessionTransfer: sessionTransfer,
            fingerprints: fingerprints,
            toolsSignature: toolsSignature,
            contextSignature: contextSignature,
            contextTokenCount: contextTokenCount,
            lastAccessGeneration: chatSessionAccessGeneration
        )
        chatSessions[cacheKey] = state
        evictChatSessionsBeyondLimit()
    }

    private static func contextTokenCount(
        cachedPromptTokenCount: Int?,
        completionInfo: GenerateCompletionInfo?
    ) -> Int? {
        guard let completionInfo else {
            return cachedPromptTokenCount
        }
        return (cachedPromptTokenCount ?? 0)
            + completionInfo.promptTokenCount
            + completionInfo.generationTokenCount
    }

    private func discardChatSession(for cacheKey: MLXServerChatSessionCacheKey) {
        chatSessions[cacheKey] = nil
    }

    /// Evicts least-recently-used sessions beyond the registry bound. Each
    /// resident session retains a full KV cache in unified memory.
    private func evictChatSessionsBeyondLimit() {
        while chatSessions.count > maxChatSessionCount {
            guard let victim = chatSessions.min(by: {
                $0.value.lastAccessGeneration < $1.value.lastAccessGeneration
            }) else {
                return
            }
            chatSessions[victim.key] = nil
        }
    }

    // MARK: - Disk persistence

    /// Persists the live cache for one session. This is intentionally only
    /// called by the saved-session flow.
    public func saveChatSessionCacheToDisk(
        request: MLXServerGenerationRequest
    ) async -> Bool {
        guard diskKVCacheStore != nil,
              request.messages.allSatisfy({ $0.imageURLs.isEmpty && $0.videoURLs.isEmpty })
        else {
            return false
        }

        let cacheKey = Self.chatSessionCacheKey(for: request)
        guard let state = chatSessions[cacheKey] else {
            return false
        }
        return await persistChatSessionToDisk(
            cacheKey: cacheKey,
            sessionTransfer: state.sessionTransfer,
            fingerprints: state.fingerprints,
            toolsSignature: state.toolsSignature,
            contextSignature: state.contextSignature,
            contextTokenCount: state.contextTokenCount
        )
    }

    /// Restores the cache for a saved session into the in-memory registry.
    /// Normal generation never calls this; the next prompt after a saved
    /// session load can then continue from memory.
    public func restoreChatSessionCacheFromDisk(
        request: MLXServerGenerationRequest,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> Bool {
        guard diskKVCacheStore != nil,
              !request.messages.isEmpty,
              request.messages.allSatisfy({ $0.imageURLs.isEmpty && $0.videoURLs.isEmpty })
        else {
            return false
        }

        let cacheKey = Self.chatSessionCacheKey(for: request)
        let requestFingerprints = request.messages.map(\.transcriptFingerprint)
        let toolsSignature = MLXServerChatSessionRequestSignature.tools(request.tools)
        let contextSignature = MLXServerChatSessionRequestSignature.additionalContext(
            request.additionalContext
        )
        guard let diskMatch = await Self.diskChatSessionMatch(
            store: diskKVCacheStore,
            key: cacheKey,
            toolsSignature: toolsSignature,
            contextSignature: contextSignature,
            requestFingerprints: requestFingerprints,
            acceptsCompleteMatch: true
        ) else {
            return false
        }

        let container = try await container(
            for: request.model,
            runtimeKind: request.runtimeKind,
            parameters: request.parameters,
            progressHandler: progressHandler
        )
        let session = MLXServerRawChatSession(
            container,
            cache: diskMatch.cache
        )
        chatSessionAccessGeneration += 1
        chatSessions[cacheKey] = ChatSessionState(
            sessionTransfer: ChatSessionTransfer(session: session),
            fingerprints: diskMatch.fingerprints,
            toolsSignature: toolsSignature,
            contextSignature: contextSignature,
            contextTokenCount: diskMatch.contextTokenCount,
            lastAccessGeneration: chatSessionAccessGeneration
        )
        evictChatSessionsBeyondLimit()
        lastChatCacheEvent = MLXServerChatCacheEvent(
            status: .diskHit,
            cachedSessionCount: chatSessions.count,
            modelSessionCount: chatSessions.keys.count { $0.modelID == request.model.id },
            priorTranscriptCount: requestFingerprints.count,
            bestCommonPrefixCount: diskMatch.matchedPrefixEndIndex,
            bestCachedTranscriptCount: diskMatch.fingerprints.count,
            restoredPromptPrefixTokenCount: diskMatch.contextTokenCount,
            cachedPromptTokenCount: diskMatch.contextTokenCount
        )
        return true
    }

    private func persistChatSessionToDisk(
        cacheKey: MLXServerChatSessionCacheKey,
        sessionTransfer: ChatSessionTransfer,
        fingerprints: [MLXServerChatTranscriptFingerprint],
        toolsSignature: String,
        contextSignature: String,
        contextTokenCount: Int?
    ) async -> Bool {
        guard let diskKVCacheStore else {
            return false
        }
        guard diskKVCacheStore.needsPersistence(
            for: cacheKey,
            fingerprints: fingerprints
        ) else {
            return true
        }
        guard let target = try? diskKVCacheStore.preparePersistenceTarget(for: cacheKey) else {
            return false
        }

        return await Task.detached(priority: .utility) {
            do {
                try await sessionTransfer.session.saveCache(to: target.temporaryURL)
                try diskKVCacheStore.commitPersistedSession(
                    key: cacheKey,
                    toolsSignature: toolsSignature,
                    contextSignature: contextSignature,
                    fingerprints: fingerprints,
                    contextTokenCount: contextTokenCount,
                    target: target
                )
                return true
            } catch {
                diskKVCacheStore.discardPersistenceTarget(target)
                return false
            }
        }.value
    }

    // MARK: - Model containers

    private func container(
        for model: MLXServerModelDescriptor,
        runtimeKind: MLXServerModelRuntimeKind,
        parameters: GenerateParameters,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> ModelContainer {
        let key = LoadedModelKey(modelID: model.id, runtimeKind: runtimeKind)
        if let container = containers[key] {
            return container
        }

        if let loadingTask = loadingTasks[key] {
            let container = try await loadingTask.task.value
            guard containers[key] != nil || loadingTasks[key]?.id == loadingTask.id else {
                throw CancellationError()
            }
            return container
        }

        if retentionPolicy == .unloadPreviousModel {
            unloadOtherModelsBeforeLoading(key)
        }

        let task = Task {
            try await MLXServerModelLoading.loadContainer(
                configuration: model.configuration,
                runtimeKind: runtimeKind,
                progressHandler: progressHandler
            )
        }
        let loadingTask = ModelLoadingTask(id: UUID(), task: task)
        loadingTasks[key] = loadingTask

        do {
            let container = try await task.value
            guard loadingTasks[key]?.id == loadingTask.id else {
                throw CancellationError()
            }
            loadingTasks[key] = nil
            containers[key] = container
            modelLoadLogger?(
                MLXServerModelLoadEvent(
                    model: model,
                    runtimeKind: runtimeKind,
                    parameters: parameters
                )
            )
            return container
        } catch {
            if loadingTasks[key]?.id == loadingTask.id {
                loadingTasks[key] = nil
            }
            throw error
        }
    }

    private func unloadOtherModelsBeforeLoading(_ key: LoadedModelKey) {
        let unloadedModelIDs = Set(containers.keys.filter { $0 != key }.map(\.modelID)).sorted()
        containers = containers.filter { $0.key == key }
        chatSessions = chatSessions.filter { $0.key.modelID == key.modelID }
        for (loadingKey, loadingTask) in loadingTasks where loadingKey != key {
            loadingTask.task.cancel()
        }
        loadingTasks = loadingTasks.filter { $0.key == key }
        logUnloadedModels(unloadedModelIDs)
    }

    private func logUnloadedModels(_ modelIDs: [String]) {
        for modelID in modelIDs {
            modelUnloadLogger?(MLXServerModelUnloadEvent(modelID: modelID))
        }
    }
}

final class MLXServerRawChatSession: @unchecked Sendable {
    let container: ModelContainer
    var cache: [KVCache]?

    init(
        _ container: ModelContainer,
        cache: [KVCache]? = nil
    ) {
        self.container = container
        self.cache = cache
    }

    func streamDetails(
        request: MLXServerGenerationRequest,
        cachedPromptTokenCount: Int?,
        cachedPrefixMessageCount: Int
    ) async throws -> AsyncStream<Generation> {
        let plan = MLXServerRawChatSessionPlan(
            session: self,
            request: request,
            cachedPromptTokenCount: cachedPromptTokenCount,
            cachedPrefixMessageCount: cachedPrefixMessageCount
        )
        return try await container.perform(nonSendable: plan) { context, plan in
            let session = plan.session
            let tools = plan.request.tools
            let input = try await Self.input(
                for: plan,
                context: context
            )
            if session.cache == nil {
                session.cache = context.model.newCache(parameters: plan.request.parameters)
            }
            guard let cache = session.cache else {
                throw MLXServerRuntimeError.emptyPrompt
            }
            let tokenStream = try MLXLMCommon.generateTokens(
                input: input,
                cache: cache,
                parameters: plan.request.parameters,
                context: context
            )
            return Self.generationStream(
                from: tokenStream,
                tokenizer: context.tokenizer,
                toolCallFormat: context.configuration.toolCallFormat ?? .json,
                tools: tools
            )
        }
    }

    private static func input(
        for plan: MLXServerRawChatSessionPlan,
        context: ModelContext
    ) async throws -> LMInput {
        if plan.cachedPrefixMessageCount > 0 {
            return try await cachedContinuationInput(for: plan, context: context)
        }

        let rawMessages = plan.request.messages.map {
            $0.rawTemplateMessage(
                toolResultStyle: .style(for: plan.request.model)
            )
        }
        let renderedTokens = try context.tokenizer.applyChatTemplate(
            messages: rawMessages,
            tools: plan.request.tools,
            additionalContext: plan.request.additionalContext
        )
        guard !renderedTokens.isEmpty else {
            throw MLXServerRuntimeError.emptyPrompt
        }
        return LMInput(tokens: MLXArray(renderedTokens))
    }

    private static func cachedContinuationInput(
        for plan: MLXServerRawChatSessionPlan,
        context: ModelContext
    ) async throws -> LMInput {
        let suffixStartIndex = plan.cachedPrefixMessageCount
        guard suffixStartIndex < plan.request.messages.count else {
            throw MLXServerRuntimeError.emptyPrompt
        }
        guard plan.request.messages[suffixStartIndex].role == .tool else {
            let suffixMessages = suffixChatMessages(
                request: plan.request,
                cachedPrefixMessageCount: suffixStartIndex
            )
            guard !suffixMessages.isEmpty else {
                throw MLXServerRuntimeError.emptyPrompt
            }
            return try await context.processor.prepare(
                input: UserInput(
                    chat: suffixMessages,
                    processing: .init(resize: plan.request.mediaResize)
                )
            )
        }
        guard suffixStartIndex > 0,
              let tokenizer = context.tokenizer as? MLXServerChatTemplateTokenizing
        else {
            throw MLXServerRuntimeError.emptyPrompt
        }

        let templateSlice = cachedContinuationTemplateSlice(
            request: plan.request,
            cachedPrefixMessageCount: suffixStartIndex
        )
        let previousTokens = try tokenizer.applyChatTemplate(
            messages: templateSlice.cachedContextMessages,
            tools: nil,
            additionalContext: plan.request.additionalContext,
            addGenerationPrompt: false
        )
        let continuationTokens = try tokenizer.applyChatTemplate(
            messages: templateSlice.continuationContextMessages,
            tools: nil,
            additionalContext: plan.request.additionalContext,
            addGenerationPrompt: true
        )
        guard continuationTokens.count > previousTokens.count,
              continuationTokens.starts(with: previousTokens)
        else {
            throw MLXServerRuntimeError.emptyPrompt
        }

        let suffixTokens = Array(continuationTokens.dropFirst(previousTokens.count))
        guard !suffixTokens.isEmpty else {
            throw MLXServerRuntimeError.emptyPrompt
        }
        return LMInput(tokens: MLXArray(suffixTokens))
    }

    struct CachedContinuationTemplateSlice {
        var cachedContextMessages: [[String: any Sendable]]
        var continuationContextMessages: [[String: any Sendable]]
    }

    static func cachedContinuationTemplateSlice(
        request: MLXServerGenerationRequest,
        cachedPrefixMessageCount: Int
    ) -> CachedContinuationTemplateSlice {
        let contextStartIndex = cachedContinuationContextStartIndex(
            request: request,
            cachedPrefixMessageCount: cachedPrefixMessageCount
        )
        let style = MLXServerToolResultTemplateStyle.style(for: request.model)
        let cachedContextMessages = request.messages[contextStartIndex..<cachedPrefixMessageCount]
            .map { $0.rawTemplateMessage(toolResultStyle: style) }
        let continuationContextMessages = request.messages
            .dropFirst(contextStartIndex)
            .map { $0.rawTemplateMessage(toolResultStyle: style) }
        return CachedContinuationTemplateSlice(
            cachedContextMessages: cachedContextMessages,
            continuationContextMessages: continuationContextMessages
        )
    }

    private static func cachedContinuationContextStartIndex(
        request: MLXServerGenerationRequest,
        cachedPrefixMessageCount: Int
    ) -> Int {
        let prefix = request.messages.prefix(cachedPrefixMessageCount)
        return prefix.lastIndex { $0.role == .user } ?? (cachedPrefixMessageCount - 1)
    }

    static func suffixChatMessages(
        request: MLXServerGenerationRequest,
        cachedPrefixMessageCount: Int
    ) -> [Chat.Message] {
        guard cachedPrefixMessageCount > 0 else {
            return request.messages.map(\.mlxChatMessage)
        }
        return request.messages
            .dropFirst(cachedPrefixMessageCount)
            .map(\.mlxChatMessage)
    }

    private static func generationStream(
        from tokenStream: AsyncStream<TokenGeneration>,
        tokenizer: any MLXLMCommon.Tokenizer,
        toolCallFormat: ToolCallFormat,
        tools: [[String: any Sendable]]?
    ) -> AsyncStream<Generation> {
        AsyncStream { continuation in
            let task = Task {
                var detokenizer = NaiveStreamingDetokenizer(tokenizer: tokenizer)
                var toolCallProcessor = MLXServerToolCallStreamProcessor(
                    format: toolCallFormat,
                    tools: tools
                )
                var didFinishWithInfo = false

                func emitPendingToolCalls() {
                    for toolCall in toolCallProcessor.drainToolCalls() {
                        continuation.yield(.toolCall(toolCall))
                    }
                }

                func finishBufferedOutput() {
                    if let text = toolCallProcessor.processEOS(returnBufferedText: true),
                       !text.isEmpty {
                        continuation.yield(.chunk(text))
                    }
                    emitPendingToolCalls()
                }

                for await event in tokenStream {
                    guard !Task.isCancelled else {
                        break
                    }
                    switch event {
                    case .token(let token):
                        detokenizer.append(token: token)
                        if let chunk = detokenizer.next() {
                            if let text = toolCallProcessor.processChunk(chunk),
                               !text.isEmpty {
                                continuation.yield(.chunk(text))
                            }
                            emitPendingToolCalls()
                        }
                    case .info(let info):
                        finishBufferedOutput()
                        continuation.yield(.info(info))
                        didFinishWithInfo = true
                    }
                }

                if !didFinishWithInfo {
                    finishBufferedOutput()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func saveCache(to url: URL) async throws {
        guard let cache else {
            throw ChatSessionError.noCacheAvailable
        }
        try savePromptCache(url: url, cache: cache)
    }

}

private struct MLXServerRawChatSessionPlan {
    var session: MLXServerRawChatSession
    var request: MLXServerGenerationRequest
    var cachedPromptTokenCount: Int?
    var cachedPrefixMessageCount: Int
}

struct MLXServerToolCallStreamProcessor {
    private enum State {
        case normal
        case potentialTaggedToolCall
        case collectingTaggedToolCall
        case collectingJSONToolCall
    }

    private let parser: any ToolCallParser
    private let tools: [[String: any Sendable]]?
    private let supportsBareJSONFallback: Bool
    private let jsonObjectScanner = MLXServerJSONLeadingObjectScanner(startCharacter: "{")
    private var fallbackProcessor: ToolCallProcessor?
    private var fallbackToolCallDrainIndex = 0
    private var state = State.normal
    private var buffer = ""
    private var toolCalls: [ToolCall] = []

    init(format: ToolCallFormat, tools: [[String: any Sendable]]? = nil) {
        let parser = format.createParser()
        self.parser = parser
        self.tools = tools
        supportsBareJSONFallback = format == .json
        if parser.startTag == nil {
            fallbackProcessor = ToolCallProcessor(format: format, tools: tools)
        }
    }

    mutating func processChunk(_ chunk: String) -> String? {
        if let fallbackProcessor {
            return fallbackProcessor.processChunk(chunk)
        }
        return processTaggedChunk(chunk)
    }

    mutating func processEOS(returnBufferedText: Bool = true) -> String? {
        if let fallbackProcessor {
            return fallbackProcessor.processEOS(returnBufferedText: returnBufferedText)
        }

        guard !buffer.isEmpty else {
            state = .normal
            return nil
        }

        let buffered = buffer
        buffer = ""
        let parsedCalls: [ToolCall]
        switch state {
        case .normal, .potentialTaggedToolCall:
            parsedCalls = []
        case .collectingTaggedToolCall, .collectingJSONToolCall:
            parsedCalls = parser.parseEOS(buffered, tools: tools)
        }
        state = .normal
        toolCalls.append(contentsOf: parsedCalls)

        return returnBufferedText && parsedCalls.isEmpty ? buffered : nil
    }

    mutating func drainToolCalls() -> [ToolCall] {
        if let fallbackProcessor {
            let calls = Array(fallbackProcessor.toolCalls.dropFirst(fallbackToolCallDrainIndex))
            fallbackToolCallDrainIndex += calls.count
            return calls
        }

        guard !toolCalls.isEmpty else {
            return []
        }
        let drained = toolCalls
        toolCalls.removeAll(keepingCapacity: true)
        return drained
    }

    private mutating func processTaggedChunk(_ chunk: String) -> String? {
        buffer += chunk
        var emitted = ""

        scanLoop: while !buffer.isEmpty {
            switch state {
            case .normal:
                guard let startIndex = potentialStartIndex(in: buffer) else {
                    emitted += buffer
                    buffer = ""
                    continue
                }
                if startIndex > buffer.startIndex {
                    emitted += buffer[..<startIndex]
                    buffer.removeSubrange(buffer.startIndex..<startIndex)
                }
                if supportsBareJSONFallback,
                   buffer.first == jsonObjectScanner.startCharacter {
                    state = .collectingJSONToolCall
                } else {
                    state = .potentialTaggedToolCall
                }

            case .potentialTaggedToolCall:
                guard let startTag = parser.startTag else {
                    emitted += buffer
                    buffer = ""
                    state = .normal
                    continue
                }
                if buffer.hasPrefix(startTag) {
                    state = .collectingTaggedToolCall
                    continue
                }
                if startTag.hasPrefix(buffer) {
                    break scanLoop
                }
                emitted.append(buffer.removeFirst())
                state = .normal

            case .collectingTaggedToolCall:
                guard let endTag = parser.endTag,
                      let endRange = buffer.range(of: endTag) else {
                    break scanLoop
                }

                let taggedToolCall = String(buffer[..<endRange.upperBound])
                if let toolCall = parser.parse(content: taggedToolCall, tools: tools) {
                    toolCalls.append(toolCall)
                } else {
                    emitted += taggedToolCall
                }
                buffer.removeSubrange(buffer.startIndex..<endRange.upperBound)
                state = .normal

            case .collectingJSONToolCall:
                switch jsonObjectScanner.evaluatePrefix(in: buffer) {
                case .invalidObject:
                    emitted.append(buffer.removeFirst())
                    state = .normal
                case .needsMore:
                    break scanLoop
                case .validObject:
                    guard let split = jsonObjectScanner.splitLeadingObject(from: buffer) else {
                        break scanLoop
                    }
                    if let toolCall = parser.parse(content: split.object, tools: tools) {
                        toolCalls.append(toolCall)
                    } else {
                        emitted += split.object
                    }
                    buffer = split.trailing
                    state = .normal
                }
            }

        }

        return emitted.isEmpty ? nil : emitted
    }

    private func potentialStartIndex(in text: String) -> String.Index? {
        var indexes: [String.Index] = []
        if let startChar = parser.startTag?.first,
           let index = text.firstIndex(of: startChar) {
            indexes.append(index)
        }
        if supportsBareJSONFallback,
           let index = text.firstIndex(of: jsonObjectScanner.startCharacter) {
            indexes.append(index)
        }
        return indexes.min()
    }
}

private struct MLXServerJSONLeadingObjectScanner {
    enum PrefixState {
        case needsMore
        case validObject
        case invalidObject
    }

    let startCharacter: Character

    func evaluatePrefix(in buffer: String) -> PrefixState {
        guard let start = buffer.firstIndex(where: { !$0.isWhitespace }) else {
            return .invalidObject
        }
        return evaluatePrefix(in: buffer, from: start)
    }

    func evaluatePrefix(in buffer: String, from start: String.Index) -> PrefixState {
        var openingIndex = start
        while openingIndex < buffer.endIndex, buffer[openingIndex].isWhitespace {
            openingIndex = buffer.index(after: openingIndex)
        }
        guard openingIndex < buffer.endIndex,
              buffer[openingIndex] == startCharacter else {
            return .invalidObject
        }

        var index = buffer.index(after: openingIndex)
        while index < buffer.endIndex, buffer[index].isWhitespace {
            index = buffer.index(after: index)
        }
        guard index < buffer.endIndex else {
            return .needsMore
        }

        let firstToken = buffer[index]
        return firstToken == "\"" || firstToken == "}"
            ? .validObject
            : .invalidObject
    }

    func splitLeadingObject(from buffer: String) -> (object: String, trailing: String)? {
        guard let openingIndex = buffer.firstIndex(where: { !$0.isWhitespace }) else {
            return nil
        }
        guard buffer[openingIndex] == startCharacter else {
            return nil
        }

        var depth = 0
        var isEscaped = false
        var isInString = false
        var index = openingIndex
        while index < buffer.endIndex {
            let character = buffer[index]
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = isInString
            } else if character == "\"" {
                isInString.toggle()
            } else if !isInString {
                if character == startCharacter {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        let end = buffer.index(after: index)
                        return (
                            String(buffer[..<end]),
                            String(buffer[end...])
                        )
                    }
                }
            }
            index = buffer.index(after: index)
        }

        return nil
    }
}

/// The raw session owns a KV cache; the wrapper lets the runtime pass it
/// between the actor and detached persistence work.
struct ChatSessionTransfer: @unchecked Sendable {
    let session: MLXServerRawChatSession
}

private struct LoadedModelKey: Hashable, Sendable {
    var modelID: String
    var runtimeKind: MLXServerModelRuntimeKind

    var displayName: String {
        "\(modelID) [\(runtimeKind.rawValue)]"
    }
}

private struct ModelLoadingTask {
    var id: UUID
    var task: Task<ModelContainer, any Error>
}

public enum MLXServerChatSessionTranscriptText {
    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    public static func visibleAssistantContent(from generatedText: String, startsInThinking: Bool) -> String {
        var text = generatedText

        if startsInThinking, let closeRange = text.range(of: closeTag) {
            text.removeSubrange(text.startIndex..<closeRange.upperBound)
        } else if let closeRange = text.range(of: closeTag),
                  shouldDiscardPrefixThroughCloseTag(in: text, closeRange: closeRange) {
            text.removeSubrange(text.startIndex..<closeRange.upperBound)
        }

        var visible = ""
        while !text.isEmpty {
            guard let openRange = text.range(of: openTag) else {
                visible += text
                break
            }

            visible += text[..<openRange.lowerBound]
            text.removeSubrange(text.startIndex..<openRange.upperBound)

            guard let closeRange = text.range(of: closeTag) else {
                break
            }
            text.removeSubrange(text.startIndex..<closeRange.upperBound)

            if let strayCloseRange = text.range(of: closeTag),
               shouldDiscardPrefixThroughCloseTag(in: text, closeRange: strayCloseRange) {
                text.removeSubrange(text.startIndex..<strayCloseRange.upperBound)
            }
        }

        return visible
    }

    public static func visibleAssistantContentForHistory(
        from generatedText: String,
        startsInThinking: Bool
    ) -> String {
        guard startsInThinking else {
            return visibleAssistantContent(from: generatedText, startsInThinking: false)
        }
        guard let closeRange = generatedText.range(of: closeTag) else {
            return ""
        }

        let visibleStartIndex = closeRange.upperBound
        return visibleAssistantContent(
            from: String(generatedText[visibleStartIndex...]),
            startsInThinking: false
        )
    }

    public static func assistantHistoryMessages(
        from generatedText: String,
        startsInThinking: Bool,
        preservesThinking: Bool
    ) -> [MLXServerChatMessage] {
        let historyVisibleText = visibleAssistantContentForHistory(
            from: generatedText,
            startsInThinking: startsInThinking
        )
        let reasoningText = reasoningContent(
            from: generatedText,
            startsInThinking: startsInThinking
        )
        let trimmedReasoningText = reasoningText.trimmingCharacters(in: .whitespacesAndNewlines)
        var messages: [MLXServerChatMessage] = []
        if preservesThinking, !trimmedReasoningText.isEmpty {
            messages.append(
                .assistant(
                    MLXServerReasoningTranscript.reasoningSummary(trimmedReasoningText)
                )
            )
        }
        let historyReasoningText = preservesThinking ? trimmedReasoningText : nil
        if !historyVisibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || historyReasoningText?.isEmpty == false {
            messages.append(
                .assistant(
                    historyVisibleText,
                    reasoningContent: historyReasoningText
                )
            )
        }
        if messages.isEmpty {
            messages.append(.assistant(""))
        }
        return messages
    }

    public static func reasoningContent(from generatedText: String, startsInThinking: Bool) -> String {

        var text = generatedText
        var reasoning = ""

        if startsInThinking {
            if let closeRange = text.range(of: closeTag) {
                reasoning += strippingLeadingOpenTag(
                    String(text[..<closeRange.lowerBound])
                )
                text.removeSubrange(text.startIndex..<closeRange.upperBound)
            }
        }

        while !text.isEmpty {
            guard let openRange = text.range(of: openTag) else {
                break
            }
            text.removeSubrange(text.startIndex..<openRange.upperBound)

            guard let closeRange = text.range(of: closeTag) else {
                reasoning += text
                break
            }

            reasoning += text[..<closeRange.lowerBound]
            text.removeSubrange(text.startIndex..<closeRange.upperBound)
        }

        return reasoning
    }

    private static func strippingLeadingOpenTag(_ text: String) -> String {
        let trimmedPrefix = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPrefix.hasPrefix(openTag),
              let openRange = text.range(of: openTag) else {
            return text
        }
        var text = text
        text.removeSubrange(text.startIndex..<openRange.upperBound)
        return text
    }

    private static func shouldDiscardPrefixThroughCloseTag(
        in text: String,
        closeRange: Range<String.Index>
    ) -> Bool {
        guard let openRange = text.range(of: openTag) else {
            return true
        }
        return openRange.lowerBound > closeRange.lowerBound
    }
}

enum MLXServerToolResultTemplateStyle {
    case roleToolContent
    case toolResponses

    static func style(for model: MLXServerModelDescriptor) -> Self {
        let name = "\(model.id) \(model.displayName)".lowercased()
        return name.contains("gemma") ? .toolResponses : .roleToolContent
    }
}

extension MLXServerChatMessage {
    func rawTemplateMessage(
        toolResultStyle: MLXServerToolResultTemplateStyle
    ) -> [String: any Sendable] {
        switch role {
        case .system, .user:
            return [
                "role": role.rawValue,
                "content": content
            ]
        case .assistant:
            var message: [String: any Sendable] = [
                "role": role.rawValue,
                "content": content
            ]
            if let reasoningContent {
                message["reasoning_content"] = reasoningContent
            }
            if !toolCalls.isEmpty {
                message["tool_calls"] = toolCalls.map(Self.rawToolCallPayload)
            }
            return message
        case .tool:
            return rawToolResultMessage(style: toolResultStyle)
        }
    }

    private func rawToolResultMessage(
        style: MLXServerToolResultTemplateStyle
    ) -> [String: any Sendable] {
        var message: [String: any Sendable] = [
            "role": role.rawValue,
            "content": style == .toolResponses ? "" : content
        ]
        if let toolCallID {
            message["tool_call_id"] = toolCallID
        }
        if let toolName {
            message["name"] = toolName
        }
        if style == .toolResponses {
            message["tool_responses"] = [
                [
                    "name": toolName ?? "unknown",
                    "response": content
                ] as [String: any Sendable]
            ]
        }
        return message
    }

    private static func rawToolCallPayload(
        _ toolCall: MLXServerChatToolCall
    ) -> [String: any Sendable] {
        var payload: [String: any Sendable] = [
            "type": "function",
            "function": [
                "name": toolCall.function.name,
                "arguments": toolCall.function.arguments.mapValues(Self.sendableTemplateValue)
            ] as [String: any Sendable]
        ]
        if let id = toolCall.id?.trimmingCharacters(in: .whitespacesAndNewlines),
           !id.isEmpty {
            payload["id"] = id
        }
        return payload
    }

    private static func sendableTemplateValue(_ value: JSONValue) -> any Sendable {
        switch value {
        case .null:
            return "null"
        case .bool(let value):
            return value
        case .int(let value):
            return value
        case .double(let value):
            return value
        case .string(let value):
            return value
        case .array(let values):
            return values.map(Self.sendableTemplateValue)
        case .object(let values):
            return values.mapValues(Self.sendableTemplateValue)
        }
    }

    var mlxChatMessage: Chat.Message {
        Chat.Message(
            role: mlxRole,
            content: templateContent,
            images: imageURLs.map(UserInput.Image.url),
            videos: videoURLs.map(UserInput.Video.url)
        )
    }

    /// `Chat.Message` carries plain content only; assistant tool calls are
    /// rendered inline so transcript rehydration keeps the calls visible to
    /// the model even without template-native tool-call structures.
    private var templateContent: String {
        guard role == .assistant, !toolCalls.isEmpty else {
            return content
        }
        let renderedCalls = toolCalls.map(Self.toolCallTemplateContent)
        let callsText = renderedCalls.joined(separator: "\n")
        return content.isEmpty ? callsText : "\(content)\n\(callsText)"
    }

    private static func toolCallTemplateContent(_ toolCall: MLXServerChatToolCall) -> String {
        var lines = [
            "<tool_call>",
            "<function=\(toolCall.function.name)>"
        ]
        for key in toolCall.function.arguments.keys.sorted() {
            guard let value = toolCall.function.arguments[key] else {
                continue
            }
            lines.append("<parameter=\(key)>")
            lines.append(toolArgumentTemplateValue(value))
            lines.append("</parameter>")
        }
        lines.append("</function>")
        lines.append("</tool_call>")
        return lines.joined(separator: "\n")
    }

    private static func toolArgumentTemplateValue(_ value: JSONValue) -> String {
        if case .string(let string) = value {
            return string
        }
        guard JSONSerialization.isValidJSONObject(value.anyValue),
              let data = try? JSONSerialization.data(
                  withJSONObject: value.anyValue,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ) else {
            return String(describing: value.anyValue)
        }
        return String(decoding: data, as: UTF8.self)
    }

    var mlxRole: Chat.Message.Role {
        switch role {
        case .system:
            .system
        case .user:
            .user
        case .assistant:
            .assistant
        case .tool:
            .tool
        }
    }
}
