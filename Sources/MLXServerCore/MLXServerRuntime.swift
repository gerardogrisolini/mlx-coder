//
//  MLXServerRuntime.swift
//  mlx-server
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

    public init(
        role: Role,
        content: String,
        reasoningContent: String? = nil,
        imageURLs: [URL] = [],
        videoURLs: [URL] = [],
        toolCalls: [MLXServerChatToolCall] = [],
        toolCallID: String? = nil
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

    public static func tool(_ content: String, toolCallID: String? = nil) -> Self {
        Self(role: .tool, content: content, toolCallID: toolCallID)
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
    ) async throws -> AsyncStream<Generation>

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
    ) async throws -> AsyncStream<Generation> {
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
    private let diskKVCachePersistenceWriter: MLXServerDiskKVCachePersistenceWriter?
    private let modelLoadLogger: (@Sendable (MLXServerModelLoadEvent) -> Void)?
    private let modelUnloadLogger: (@Sendable (MLXServerModelUnloadEvent) -> Void)?
    private var lastChatCacheEvent: MLXServerChatCacheEvent?

    /// Default bound on resident chat sessions. Each session retains a full
    /// KV cache in unified memory, so the registry stays intentionally
    /// small; older sessions remain restorable from disk.
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
            self.diskKVCachePersistenceWriter = MLXServerDiskKVCachePersistenceWriter()
        } else {
            self.diskKVCacheStore = nil
            self.diskKVCachePersistenceWriter = nil
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
    ) async throws -> AsyncStream<Generation> {
        guard request.messages.allSatisfy({ $0.imageURLs.isEmpty && $0.videoURLs.isEmpty }) else {
            return try await generate(request: request, progressHandler: progressHandler)
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
        let suffixMessages = resolved.suffixMessages.map(\.mlxChatMessage)
        let cachedPromptTokenCount = resolved.cachedPromptTokenCount
        let throwingStream = sessionTransfer.session.streamDetails(
            to: suffixMessages
        )

        return AsyncStream { continuation in
            let task = Task {
                var completionInfo: GenerateCompletionInfo?
                do {
                    for try await item in throwingStream {
                        if Task.isCancelled {
                            break
                        }
                        if case .info(let info) = item {
                            completionInfo = info
                        }
                        continuation.yield(item)
                    }
                } catch {
                    // Mid-stream failures end the stream; the session is
                    // not stored so the next request starts clean.
                                        self.discardChatSession(for: cacheKey)
                    await generationLease.release()
                    continuation.finish()
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
        return await Self.collectGenerationOutput(stream)
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
        var suffixMessages: [MLXServerChatMessage]
        var cachedPromptTokenCount: Int?
    }

    /// Finds or builds the `ChatSession` able to serve the request:
    /// in-memory continuation first, then disk restore, then a fresh
    /// session that prefills the whole transcript.
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
                let session = state.sessionTransfer.session
                session.generateParameters = request.parameters
                // The cached prefix already contains the tool schemas for this
                // exact tools signature. Do not pass them again for the suffix,
                // otherwise the chat template re-prefills the huge tools block
                // on every cache hit.
                session.tools = nil
                session.additionalContext = request.additionalContext
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
                    suffixMessages: Array(request.messages.dropFirst(suffixStartIndex)),
                    cachedPromptTokenCount: state.contextTokenCount
                )
            }
            // Same session key but incompatible signatures or a diverged
            // transcript: the cached session cannot serve this request.
            // Persist the evicted session in the background if disk KV cache is
            // enabled, but keep it out of the live prompt path.
            chatSessions[cacheKey] = nil
            enqueueDiskChatSessionPersistence(cacheKey: cacheKey, state: state)
        }

        // 2. Disk restore: rebuild the ChatSession around the persisted
        // KV cache so a restarted server resumes without re-prefilling.
        if let diskMatch = await Self.diskChatSessionMatch(
            store: diskKVCacheStore,
            key: cacheKey,
            toolsSignature: toolsSignature,
            contextSignature: contextSignature,
            requestFingerprints: requestFingerprints
        ),
           let suffixStartIndex = MLXServerChatSessionTranscript.continuationSuffixStartIndex(
               stored: diskMatch.fingerprints,
               request: requestFingerprints
           ) {
            let session = ChatSession(
                container,
                cache: diskMatch.cache,
                generateParameters: request.parameters,
                processing: .init(resize: request.mediaResize),
                additionalContext: request.additionalContext,
                tools: nil
            )
            lastChatCacheEvent = MLXServerChatCacheEvent(
                status: .diskHit,
                cachedSessionCount: 0,
                modelSessionCount: modelSessionCount,
                priorTranscriptCount: requestFingerprints.count,
                bestCommonPrefixCount: suffixStartIndex,
                bestCachedTranscriptCount: diskMatch.fingerprints.count,
                restoredPromptPrefixTokenCount: diskMatch.contextTokenCount,
                cachedPromptTokenCount: diskMatch.contextTokenCount
            )
            return ResolvedChatSession(
                cacheKey: cacheKey,
                sessionTransfer: ChatSessionTransfer(session: session),
                suffixMessages: Array(request.messages.dropFirst(suffixStartIndex)),
                cachedPromptTokenCount: diskMatch.contextTokenCount
            )
        }

        // 3. Fresh session: the whole transcript is prefilled this turn.
        let session = ChatSession(
            container,
            generateParameters: request.parameters,
            processing: .init(resize: request.mediaResize),
            additionalContext: request.additionalContext,
            tools: request.tools
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
            suffixMessages: request.messages,
            cachedPromptTokenCount: nil
        )
    }

    /// Runs the disk lookup off the actor executor so heavy safetensors
    /// reads do not block other runtime requests.
    private static func diskChatSessionMatch(
        store: MLXServerDiskKVCacheStore?,
        key: MLXServerChatSessionCacheKey,
        toolsSignature: String,
        contextSignature: String,
        requestFingerprints: [MLXServerChatTranscriptFingerprint]
    ) async -> MLXServerDiskChatSessionMatch? {
        guard let store, store.isEnabled else {
            return nil
        }
        return await Task.detached(priority: .userInitiated) {
            store.loadSession(
                for: key,
                toolsSignature: toolsSignature,
                contextSignature: contextSignature,
                requestFingerprints: requestFingerprints
            )
        }.value
    }

    /// Stores the session back into the registry at turn end and schedules
    /// disk persistence of its KV cache.
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
    /// resident session retains a full KV cache in unified memory; evicted
    /// sessions remain restorable from their disk entry.
    private func evictChatSessionsBeyondLimit() {
        while chatSessions.count > maxChatSessionCount {
            guard let victim = chatSessions.min(by: {
                $0.value.lastAccessGeneration < $1.value.lastAccessGeneration
            }) else {
                return
            }
            chatSessions[victim.key] = nil
            enqueueDiskChatSessionPersistence(
                cacheKey: victim.key,
                state: victim.value
            )
        }
    }

    // MARK: - Disk persistence

    /// Disk persistence is intentionally limited to sessions that are no
    /// longer live in memory (LRU eviction or model unload). Persisting the
    /// active ChatSession would take its internal cache lock and make the next
    /// interactive prompt wait behind disk I/O.
        private func enqueueDiskChatSessionPersistence(
        cacheKey: MLXServerChatSessionCacheKey,
        state: ChatSessionState
    ) {
        guard diskKVCacheStore != nil, let diskKVCachePersistenceWriter else {
            return
        }
        // Coalesce per session entry: only rewrites of the same session
        // coalesce; pending persists of other sessions are preserved. The
        // closure captures the session so an LRU eviction before the writer
        // drains does not lose disk durability.
        diskKVCachePersistenceWriter.enqueue(coalescingKey: cacheKey.entryKey) { [weak self] in
            await self?.persistChatSessionToDisk(
                cacheKey: cacheKey,
                sessionTransfer: state.sessionTransfer,
                fingerprints: state.fingerprints,
                toolsSignature: state.toolsSignature,
                contextSignature: state.contextSignature,
                contextTokenCount: state.contextTokenCount,
                skipIfLive: true
            )
        }
    }

        /// Runs on the persistence writer's queue. Only sessions that have
    /// already left the live in-memory registry are serialized, so disk I/O
    /// never owns the active prompt path.
    private func persistChatSessionToDisk(
        cacheKey: MLXServerChatSessionCacheKey,
        sessionTransfer: ChatSessionTransfer,
        fingerprints: [MLXServerChatTranscriptFingerprint],
        toolsSignature: String,
        contextSignature: String,
        contextTokenCount: Int?,
        skipIfLive: Bool
    ) async {
        guard let diskKVCacheStore else {
            return
        }

        // Never persist a live in-memory session from the background writer.
        // Saving the ChatSession cache takes its serial cache lock; if a prompt
        // arrives at the same time it would block before generation starts.
        if skipIfLive, chatSessions[cacheKey] != nil {
            return
        }
        guard diskKVCacheStore.needsPersistence(
            for: cacheKey,
            fingerprints: fingerprints
        ) else {
            return
        }
        guard let target = try? diskKVCacheStore.preparePersistenceTarget(for: cacheKey) else {
            return
        }

        await Task.detached(priority: .utility) {
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
            } catch {
                diskKVCacheStore.discardPersistenceTarget(target)
            }
        }.value
    }

    public func persistChatSessionsToDisk() async {
        guard diskKVCacheStore != nil else {
            return
        }
        let states = chatSessions
        for (cacheKey, state) in states {
            await persistChatSessionToDisk(
                cacheKey: cacheKey,
                sessionTransfer: state.sessionTransfer,
                fingerprints: state.fingerprints,
                toolsSignature: state.toolsSignature,
                contextSignature: state.contextSignature,
                contextTokenCount: state.contextTokenCount,
                skipIfLive: false
            )
        }
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
        let evictedSessions = chatSessions.filter { $0.key.modelID != key.modelID }
        chatSessions = chatSessions.filter { $0.key.modelID == key.modelID }
        for (cacheKey, state) in evictedSessions {
            enqueueDiskChatSessionPersistence(cacheKey: cacheKey, state: state)
        }
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

/// `ChatSession` is a class with internal synchronization (its KV cache is
/// guarded by a serial-access container); the wrapper lets the runtime pass
/// it between the actor and detached persistence work.
struct ChatSessionTransfer: @unchecked Sendable {
    let session: ChatSession
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

extension MLXServerChatMessage {
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
        let renderedCalls = toolCalls.map { toolCall in
            let arguments = toolCall.function.arguments
                .map { key, value in "\"\(key)\": \(String(describing: value))" }
                .sorted()
                .joined(separator: ", ")
            return "{\"name\": \"\(toolCall.function.name)\", \"arguments\": {\(arguments)}}"
        }
        let callsText = renderedCalls
            .map { "<tool_call>\n\($0)\n</tool_call>" }
            .joined(separator: "\n")
        return content.isEmpty ? callsText : "\(content)\n\(callsText)"
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
