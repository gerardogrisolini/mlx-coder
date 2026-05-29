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
    public var imageURLs: [URL]
    public var videoURLs: [URL]
    public var toolCalls: [MLXServerChatToolCall]
    public var toolCallID: String?

    public init(
        role: Role,
        content: String,
        imageURLs: [URL] = [],
        videoURLs: [URL] = [],
        toolCalls: [MLXServerChatToolCall] = [],
        toolCallID: String? = nil
    ) {
        self.role = role
        self.content = content
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
        toolCalls: [MLXServerChatToolCall] = []
    ) -> Self {
        Self(role: .assistant, content: content, toolCalls: toolCalls)
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

    public init(
        model: MLXServerModelDescriptor,
        messages: [MLXServerChatMessage],
        parameters: GenerateParameters = GenerateParameters(),
        mediaResize: CGSize? = nil,
        tools: [ToolSpec]? = nil,
        additionalContext: [String: any Sendable]? = nil,
        retainsReasoningInHistory: Bool = false
    ) {
        self.model = model
        self.messages = messages
        self.parameters = parameters
        self.mediaResize = mediaResize
        self.tools = tools
        self.additionalContext = additionalContext
        self.retainsReasoningInHistory = retainsReasoningInHistory
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
        bestModelCommonPrefixCount: Int,
        bestModelCachedTranscriptCount: Int,
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
    private var loadingTasks: [LoadedModelKey: Task<ModelContainer, any Error>] = [:]
    private var promptPrefixCaches: [PromptPrefixCacheKey: [PromptPrefixCacheState]] = [:]
    private var promptPrefixCacheGeneration: UInt64 = 0
    private let generationGate = MLXServerGenerationGate()
    private let retentionPolicy: MLXServerModelRetentionPolicy
    private let diskKVCacheStore: MLXServerDiskKVCacheStore?
    private let modelLoadLogger: (@Sendable (MLXServerModelLoadEvent) -> Void)?
    private let modelUnloadLogger: (@Sendable (MLXServerModelUnloadEvent) -> Void)?
    private var lastChatCacheEvent: MLXServerChatCacheEvent?

    public init(
        retentionPolicy: MLXServerModelRetentionPolicy = .keepLoadedModels,
        diskKVCacheConfiguration: MLXServerDiskKVCacheConfiguration = .init(),
        modelLoadLogger: (@Sendable (MLXServerModelLoadEvent) -> Void)? = nil,
        modelUnloadLogger: (@Sendable (MLXServerModelUnloadEvent) -> Void)? = nil
    ) {
        self.retentionPolicy = retentionPolicy
        self.diskKVCacheStore = diskKVCacheConfiguration.isEnabled
            ? MLXServerDiskKVCacheStore(configuration: diskKVCacheConfiguration)
            : nil
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
        _ = try await container(
            for: model,
            runtimeKind: runtimeKind ?? model.runtimeKind,
            parameters: parameters,
            progressHandler: progressHandler
        )
    }

    public func unloadAll() {
        let unloadedModelIDs = Set(containers.keys.map(\.modelID)).sorted()
        containers.removeAll(keepingCapacity: true)
        loadingTasks.removeAll(keepingCapacity: true)
        promptPrefixCaches.removeAll(keepingCapacity: true)
        logUnloadedModels(unloadedModelIDs)
    }

    public func generate(
        request: MLXServerGenerationRequest,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> AsyncStream<Generation> {
        await generationGate.acquire()

        let container = try await container(
            for: request.model,
            runtimeKind: request.runtimeKind,
            parameters: request.parameters,
            progressHandler: progressHandler
        )
        do {
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
                    await generationGate.release()
                    continuation.finish()
                }
                continuation.onTermination = { _ in
                    task.cancel()
                }
            }
        } catch {
            await generationGate.release()
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

        await generationGate.acquire()

        let container: ModelContainer
        let rendering: PromptPrefixRendering
        let cacheKey: PromptPrefixCacheKey
        let cache: [KVCache]
        let cachedPromptTokenCount: Int
        let tokenStream: AsyncStream<TokenGeneration>
        let generationTask: Task<Void, Never>
        let tokenizer: any MLXLMCommon.Tokenizer
        let toolCallFormat: ToolCallFormat
        let toolCallSchemas = request.tools

        do {
            container = try await self.container(
                for: request.model,
                runtimeKind: request.runtimeKind,
                parameters: request.parameters,
                progressHandler: progressHandler
            )
            rendering = try await renderedPrompt(
                for: request,
                container: container
            )
            guard !rendering.tokenIDs.isEmpty else {
                throw MLXServerRuntimeError.emptyPrompt
            }
            tokenizer = rendering.tokenizer
            toolCallFormat = rendering.toolCallFormat
            cacheKey = PromptPrefixCacheKey(
                modelID: request.model.id,
                runtimeKind: request.runtimeKind,
                cacheLayoutSignature: PromptPrefixSignature.cacheLayout(request.parameters)
            )

            let cacheProbe = promptPrefixCacheProbe(
                key: cacheKey,
                promptTokenIDs: rendering.tokenIDs
            )

            let selectedCache: [KVCache]
            let selectedCachedPromptTokenCount: Int
            let selectedCacheStatus: MLXServerChatCacheEvent.Status

            if let memoryMatch = promptPrefixMemoryMatch(
                key: cacheKey,
                promptTokenIDs: rendering.tokenIDs
            ) {
                selectedCache = memoryMatch.cache
                selectedCachedPromptTokenCount = memoryMatch.prefixTokenCount
                selectedCacheStatus = .memoryHit
            } else if let diskMatch = diskKVCacheStore?.loadLongestPromptPrefix(
                for: MLXServerDiskKVCachePrefixQuery(
                    modelID: request.model.id,
                    runtimeKind: request.runtimeKind,
                    cacheLayoutSignature: PromptPrefixSignature.cacheLayout(request.parameters),
                    promptTokenIDs: rendering.tokenIDs
                )
            ) {
                selectedCache = diskMatch.cache
                selectedCachedPromptTokenCount = diskMatch.promptTokenCount
                selectedCacheStatus = .diskPrefixHit
            } else {
                selectedCache = try await newPromptCache(
                    container: container,
                    parameters: request.parameters
                )
                selectedCachedPromptTokenCount = 0
                selectedCacheStatus = .miss
            }

            let effectiveCache = effectivePromptPrefixCache(
                selectedCache,
                cachedPromptTokenCount: selectedCachedPromptTokenCount,
                promptTokenCount: rendering.tokenIDs.count
            )
            if effectiveCache.cache.isEmpty {
                cache = try await newPromptCache(
                    container: container,
                    parameters: request.parameters
                )
                cachedPromptTokenCount = 0
            } else {
                cache = effectiveCache.cache
                cachedPromptTokenCount = effectiveCache.prefixTokenCount
            }
            let effectiveCacheStatus: MLXServerChatCacheEvent.Status =
                cachedPromptTokenCount > 0 ? selectedCacheStatus : .miss
            lastChatCacheEvent = cacheProbe.event(
                status: effectiveCacheStatus,
                restoredPromptPrefixTokenCount: cachedPromptTokenCount > 0 ? cachedPromptTokenCount : nil,
                cachedPromptTokenCount: cachedPromptTokenCount > 0 ? cachedPromptTokenCount : nil
            )

            let suffixTokenIDs = Array(rendering.tokenIDs.dropFirst(cachedPromptTokenCount))
            guard !suffixTokenIDs.isEmpty else {
                throw MLXServerRuntimeError.emptyPrompt
            }

            let generation = try await promptPrefixTokenStream(
                cache: cache,
                suffixTokenIDs: suffixTokenIDs,
                parameters: request.parameters,
                container: container
            )
            tokenStream = generation.stream
            generationTask = generation.task
        } catch {
            await generationGate.release()
            throw error
        }

        let promptTokenIDs = rendering.tokenIDs
        let parameters = request.parameters
        return AsyncStream { continuation in
            let task = Task {
                var detokenizer = NaiveStreamingDetokenizer(tokenizer: tokenizer)
                let toolCallProcessor = ToolCallProcessor(
                    format: toolCallFormat,
                    tools: toolCallSchemas
                )
                var generatedTokenIDs: [Int] = []
                var toolCalls: [ToolCall] = []
                var completionInfo: GenerateCompletionInfo?

                for await event in tokenStream {
                    if Task.isCancelled {
                        break
                    }
                    switch event {
                    case .token(let token):
                        generatedTokenIDs.append(token)
                        detokenizer.append(token: token)
                        guard let chunk = detokenizer.next() else {
                            continue
                        }
                        if let text = toolCallProcessor.processChunk(chunk) {
                            continuation.yield(.chunk(text))
                        }
                        if let toolCall = toolCallProcessor.toolCalls.popLast() {
                            toolCalls.append(toolCall)
                            continuation.yield(.toolCall(toolCall))
                        }
                    case .info(let info):
                        completionInfo = info
                    }
                }

                toolCallProcessor.processEOS()
                for toolCall in toolCallProcessor.toolCalls {
                    toolCalls.append(toolCall)
                    continuation.yield(.toolCall(toolCall))
                }

                await generationTask.value

                if let completionInfo, !Task.isCancelled {
                    await self.finishPromptPrefixGeneration(
                        key: cacheKey,
                        cache: cache,
                        promptTokenIDs: promptTokenIDs,
                        generatedTokenIDs: generatedTokenIDs,
                        parameters: parameters
                    )
                    continuation.yield(.info(completionInfo))
                }

                await self.generationGate.release()
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                generationTask.cancel()
            }
        }
    }

    public func generateText(
        request: MLXServerGenerationRequest,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> MLXServerGenerationOutput {
        let stream = try await generate(request: request, progressHandler: progressHandler)
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

    public func generateChatSessionText(
        request: MLXServerGenerationRequest,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> MLXServerGenerationOutput {
        let stream = try await generateChatSession(request: request, progressHandler: progressHandler)
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

        if let task = loadingTasks[key] {
            return try await task.value
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
        loadingTasks[key] = task

        do {
            let container = try await task.value
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
            loadingTasks[key] = nil
            throw error
        }
    }

    private func unloadOtherModelsBeforeLoading(_ key: LoadedModelKey) {
        let unloadedModelIDs = Set(containers.keys.filter { $0 != key }.map(\.modelID)).sorted()
        containers = containers.filter { $0.key == key }
        promptPrefixCaches.removeAll(keepingCapacity: true)
        for (loadingKey, task) in loadingTasks where loadingKey != key {
            task.cancel()
        }
        loadingTasks = loadingTasks.filter { $0.key == key }
        logUnloadedModels(unloadedModelIDs)
    }

    private func logUnloadedModels(_ modelIDs: [String]) {
        for modelID in modelIDs {
            modelUnloadLogger?(MLXServerModelUnloadEvent(modelID: modelID))
        }
    }

    private func renderedPrompt(
        for request: MLXServerGenerationRequest,
        container: ModelContainer
    ) async throws -> PromptPrefixRendering {
        let payload = PromptPrefixRenderingPayload(
            messages: request.messages.map {
                PromptPrefixRenderingMessage(
                    role: $0.role.rawValue,
                    content: $0.content,
                    toolCalls: $0.toolCalls,
                    toolCallID: $0.toolCallID
                )
            },
            tools: request.tools,
            additionalContext: request.additionalContext
        )

        return try await container.perform(values: payload) { context, payload in
            let messages: [[String: any Sendable]] = payload.messages.map { message in
                var rendered: [String: any Sendable] = [
                    "role": message.role,
                    "content": message.content
                ]
                if !message.toolCalls.isEmpty {
                    rendered["tool_calls"] = message.toolCalls.map(\.chatTemplatePayload)
                }
                if let toolCallID = message.toolCallID, !toolCallID.isEmpty {
                    rendered["tool_call_id"] = toolCallID
                }
                return rendered
            }

            let tokenIDs: [Int]
            do {
                tokenIDs = try context.tokenizer.applyChatTemplate(
                    messages: messages,
                    tools: payload.tools,
                    additionalContext: payload.additionalContext
                )
            } catch {
                guard let tokenizerError = error as? MLXLMCommon.TokenizerError,
                      case .missingChatTemplate = tokenizerError else {
                    throw error
                }
                tokenIDs = context.tokenizer.encode(
                    text: messages
                        .compactMap { $0["content"] as? String }
                        .joined(separator: "\n\n")
                )
            }

            return PromptPrefixRendering(
                tokenIDs: tokenIDs,
                tokenizer: context.tokenizer,
                toolCallFormat: context.configuration.toolCallFormat ?? .json
            )
        }
    }

    private func newPromptCache(
        container: ModelContainer,
        parameters: GenerateParameters
    ) async throws -> [KVCache] {
        let transfer = await container.perform(values: parameters) { context, parameters in
            MLXServerKVCacheTransfer(
                cache: context.model.newCache(parameters: parameters)
            )
        }
        return transfer.cache
    }

    private func promptPrefixTokenStream(
        cache: [KVCache],
        suffixTokenIDs: [Int],
        parameters: GenerateParameters,
        container: ModelContainer
    ) async throws -> PromptPrefixTokenGeneration {
        guard !suffixTokenIDs.isEmpty, !cache.isEmpty else {
            throw MLXServerRuntimeError.emptyPrompt
        }
        let payload = PromptPrefixTokenGenerationPayload(
            cache: cache,
            suffixTokenIDs: suffixTokenIDs,
            parameters: parameters
        )

        return try await container.perform(values: payload) { context, payload in
            let input = LMInput(tokens: MLXArray(payload.suffixTokenIDs))
            let (stream, task) = try MLXLMCommon.generateTokensTask(
                input: input,
                cache: payload.cache,
                parameters: payload.parameters,
                context: context
            )
            return PromptPrefixTokenGeneration(stream: stream, task: task)
        }
    }

    private func effectivePromptPrefixCache(
        _ cache: [KVCache],
        cachedPromptTokenCount: Int,
        promptTokenCount: Int
    ) -> PromptPrefixMemoryMatch {
        guard promptTokenCount > 0,
              cachedPromptTokenCount >= promptTokenCount else {
            return PromptPrefixMemoryMatch(
                cache: cache,
                prefixTokenCount: cachedPromptTokenCount
            )
        }

        let targetCachedPromptTokenCount = promptTokenCount - 1
        guard targetCachedPromptTokenCount > 0 else {
            return PromptPrefixMemoryMatch(cache: [], prefixTokenCount: 0)
        }

        let cacheCopy = cache.map { $0.copy() }
        let tokensToTrim = cachedPromptTokenCount - targetCachedPromptTokenCount
        guard tokensToTrim > 0,
              trimPromptPrefixCache(cacheCopy, numTokens: tokensToTrim) == tokensToTrim else {
            return PromptPrefixMemoryMatch(cache: [], prefixTokenCount: 0)
        }

        return PromptPrefixMemoryMatch(
            cache: cacheCopy,
            prefixTokenCount: targetCachedPromptTokenCount
        )
    }

    private func promptPrefixCacheProbe(
        key: PromptPrefixCacheKey,
        promptTokenIDs: [Int]
    ) -> PromptPrefixCacheProbe {
        let sameKeyStates = promptPrefixCaches[key] ?? []
        let sameModelStates = promptPrefixCaches.reduce(into: [PromptPrefixCacheState]()) {
            result, entry in
            let (candidateKey, states) = entry
            if candidateKey.modelID == key.modelID,
               candidateKey.runtimeKind == key.runtimeKind {
                result.append(contentsOf: states)
            }
        }

        var bestCommonPrefixCount = 0
        var bestCachedTokenCount = 0
        for state in sameKeyStates {
            let commonPrefixCount = state.tokenIDs.reusablePrefixCount(
                with: promptTokenIDs
            )
            if commonPrefixCount > bestCommonPrefixCount {
                bestCommonPrefixCount = commonPrefixCount
                bestCachedTokenCount = state.tokenIDs.count
            }
        }

        var bestModelCommonPrefixCount = 0
        var bestModelCachedTokenCount = 0
        for state in sameModelStates {
            let commonPrefixCount = state.tokenIDs.reusablePrefixCount(
                with: promptTokenIDs
            )
            if commonPrefixCount > bestModelCommonPrefixCount {
                bestModelCommonPrefixCount = commonPrefixCount
                bestModelCachedTokenCount = state.tokenIDs.count
            }
        }

        return PromptPrefixCacheProbe(
            cachedSessionCount: sameKeyStates.count,
            modelSessionCount: sameModelStates.count,
            priorTranscriptCount: promptTokenIDs.count,
            bestCommonPrefixCount: bestCommonPrefixCount,
            bestCachedTranscriptCount: bestCachedTokenCount,
            bestModelCommonPrefixCount: bestModelCommonPrefixCount,
            bestModelCachedTranscriptCount: bestModelCachedTokenCount
        )
    }

    private func promptPrefixMemoryMatch(
        key: PromptPrefixCacheKey,
        promptTokenIDs: [Int]
    ) -> PromptPrefixMemoryMatch? {
        guard var states = promptPrefixCaches[key], !states.isEmpty else {
            return nil
        }

        var bestIndex: Int?
        var bestPrefixTokenCount = 0
        for index in states.indices {
            let prefixTokenCount = states[index].tokenIDs.reusablePrefixCount(
                with: promptTokenIDs
            )
            if prefixTokenCount > bestPrefixTokenCount {
                bestPrefixTokenCount = prefixTokenCount
                bestIndex = index
            }
        }

        guard let bestIndex, bestPrefixTokenCount > 0 else {
            return nil
        }

        promptPrefixCacheGeneration += 1
        states[bestIndex].lastAccessGeneration = promptPrefixCacheGeneration
        let state = states[bestIndex]
        promptPrefixCaches[key] = states

        if bestPrefixTokenCount == state.tokenIDs.count {
            return PromptPrefixMemoryMatch(
                cache: state.cache,
                prefixTokenCount: bestPrefixTokenCount
            )
        }

        let cacheCopy = state.cache.map { $0.copy() }
        let tokensToTrim = state.tokenIDs.count - bestPrefixTokenCount
        let trimmed = trimPromptPrefixCache(cacheCopy, numTokens: tokensToTrim)
        guard trimmed == tokensToTrim else {
            return nil
        }
        return PromptPrefixMemoryMatch(
            cache: cacheCopy,
            prefixTokenCount: bestPrefixTokenCount
        )
    }

    private func finishPromptPrefixGeneration(
        key: PromptPrefixCacheKey,
        cache: [KVCache],
        promptTokenIDs: [Int],
        generatedTokenIDs: [Int],
        parameters: GenerateParameters
    ) async {
        guard cache.hasPromptState else {
            return
        }
        let cachedTokenIDs = promptTokenIDs + generatedTokenIDs
        guard !cachedTokenIDs.isEmpty else {
            return
        }
        guard normalizePromptCacheLength(
            cache,
            expectedTokenCount: cachedTokenIDs.count
        ) else {
            return
        }

        promptPrefixCacheGeneration += 1
        var states = promptPrefixCaches[key] ?? []
        states.removeAll { state in
            state.tokenIDs == cachedTokenIDs || state.cache.hasSameStorage(as: cache)
        }
        states.append(
            PromptPrefixCacheState(
                cache: cache,
                tokenIDs: cachedTokenIDs,
                lastAccessGeneration: promptPrefixCacheGeneration
            )
        )
        states.sort { $0.lastAccessGeneration > $1.lastAccessGeneration }
        promptPrefixCaches[key] = Array(states.prefix(8))

        await persistDiskPromptCacheIfNeeded(
            cache: cache,
            key: key,
            tokenIDs: cachedTokenIDs,
            parameters: parameters
        )
    }

    private func persistDiskPromptCacheIfNeeded(
        cache: [KVCache],
        key: PromptPrefixCacheKey,
        tokenIDs: [Int],
        parameters: GenerateParameters
    ) async {
        guard let diskKVCacheStore, cache.hasPromptState else {
            return
        }
        let identity = MLXServerDiskKVCacheIdentity(
            promptPrefixKey: key,
            tokenIDs: tokenIDs,
            parameters: parameters
        )
        guard let target = try? diskKVCacheStore.preparePersistenceTarget(for: identity) else {
            return
        }

        do {
            try savePromptCache(url: target.temporaryURL, cache: cache)
            try diskKVCacheStore.commitPersistedCache(
                identity: identity,
                target: target
            )
        } catch {
            diskKVCacheStore.discardPersistenceTarget(target)
        }
    }

}

private struct LoadedModelKey: Hashable, Sendable {
    var modelID: String
    var runtimeKind: MLXServerModelRuntimeKind

    var displayName: String {
        "\(modelID) [\(runtimeKind.rawValue)]"
    }
}

private struct PromptPrefixCacheKey: Hashable, Sendable {
    var modelID: String
    var runtimeKind: MLXServerModelRuntimeKind
    var cacheLayoutSignature: String

    var signature: String {
        [
            modelID,
            runtimeKind.rawValue,
            cacheLayoutSignature
        ].joined(separator: "\u{1C}")
    }
}

private struct PromptPrefixRenderingMessage: Sendable {
    var role: String
    var content: String
    var toolCalls: [MLXServerChatToolCall]
    var toolCallID: String?
}

private struct PromptPrefixRenderingPayload: Sendable {
    var messages: [PromptPrefixRenderingMessage]
    var tools: [ToolSpec]?
    var additionalContext: [String: any Sendable]?
}

private struct PromptPrefixRendering: Sendable {
    var tokenIDs: [Int]
    var tokenizer: any MLXLMCommon.Tokenizer
    var toolCallFormat: ToolCallFormat
}

private struct PromptPrefixTokenGenerationPayload: @unchecked Sendable {
    var cache: [KVCache]
    var suffixTokenIDs: [Int]
    var parameters: GenerateParameters
}

private struct PromptPrefixTokenGeneration: Sendable {
    var stream: AsyncStream<TokenGeneration>
    var task: Task<Void, Never>
}

private struct PromptPrefixCacheState {
    var cache: [KVCache]
    var tokenIDs: [Int]
    var lastAccessGeneration: UInt64
}

private struct PromptPrefixMemoryMatch {
    var cache: [KVCache]
    var prefixTokenCount: Int
}

private extension MLXServerChatToolCall {
    var chatTemplatePayload: [String: any Sendable] {
        var payload: [String: any Sendable] = [
            "type": "function",
            "function": [
                "name": function.name,
                "arguments": function.arguments.mapValues(\.chatTemplateValue)
            ] as [String: any Sendable]
        ]
        if let id, !id.isEmpty {
            payload["id"] = id
        }
        return payload
    }
}

private extension JSONValue {
    var chatTemplateValue: any Sendable {
        switch self {
        case .null:
            NSNull()
        case .bool(let value):
            value
        case .int(let value):
            value
        case .double(let value):
            value
        case .string(let value):
            value
        case .array(let values):
            values.map(\.chatTemplateValue)
        case .object(let values):
            values.mapValues(\.chatTemplateValue)
        }
    }
}

private struct MLXServerKVCacheTransfer: @unchecked Sendable {
    var cache: [KVCache]
}

private struct MLXServerPromptTokenIdentity: Hashable, Sendable {
    var tokenDigest: String
    var tokenCount: Int
    var tokenIDs: [Int]

    init(tokenIDs: [Int]) {
        self.tokenIDs = tokenIDs
        tokenDigest = Self.digest(tokenIDs)
        tokenCount = tokenIDs.count
    }

    private static func digest(_ tokenIDs: [Int]) -> String {
        var hasher = SHA256()
        append("mlx-server-prompt-token-identity-v1", to: &hasher)
        for tokenID in tokenIDs {
            var value = Int64(tokenID).littleEndian
            withUnsafeBytes(of: &value) { buffer in
                hasher.update(data: Data(buffer))
            }
        }
        return hexString(from: hasher.finalize())
    }

    private static func append(_ value: String, to hasher: inout SHA256) {
        let data = Data(value.utf8)
        var count = UInt64(data.count).littleEndian
        withUnsafeBytes(of: &count) { buffer in
            hasher.update(data: Data(buffer))
        }
        hasher.update(data: data)
    }

    private static func hexString<D: Sequence>(
        from digest: D
    ) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct PromptPrefixCacheProbe {
    var cachedSessionCount: Int
    var modelSessionCount: Int
    var priorTranscriptCount: Int
    var bestCommonPrefixCount: Int
    var bestCachedTranscriptCount: Int
    var bestModelCommonPrefixCount: Int
    var bestModelCachedTranscriptCount: Int

    func event(
        status: MLXServerChatCacheEvent.Status,
        restoredPromptPrefixTokenCount: Int? = nil,
        cachedPromptTokenCount: Int? = nil
    ) -> MLXServerChatCacheEvent {
        MLXServerChatCacheEvent(
            status: status,
            cachedSessionCount: cachedSessionCount,
            modelSessionCount: modelSessionCount,
            priorTranscriptCount: priorTranscriptCount,
            bestCommonPrefixCount: bestCommonPrefixCount,
            bestCachedTranscriptCount: bestCachedTranscriptCount,
            bestModelCommonPrefixCount: bestModelCommonPrefixCount,
            bestModelCachedTranscriptCount: bestModelCachedTranscriptCount,
            restoredPromptPrefixTokenCount: restoredPromptPrefixTokenCount,
            cachedPromptTokenCount: cachedPromptTokenCount
        )
    }
}

extension MLXServerDiskKVCacheIdentity {
    fileprivate init(
        promptPrefixKey key: PromptPrefixCacheKey,
        tokenIDs: [Int],
        parameters: GenerateParameters
    ) {
        let tokenIdentity = MLXServerPromptTokenIdentity(tokenIDs: tokenIDs)
        self.init(
            modelID: key.modelID,
            runtimeKind: key.runtimeKind,
            chatKeySignature: key.signature,
            transcriptSignature: tokenIdentity.tokenDigest,
            cacheLayoutSignature: PromptPrefixSignature.cacheLayout(parameters),
            promptTokenDigest: tokenIdentity.tokenDigest,
            promptTokenCount: tokenIdentity.tokenCount,
            promptTokenIDs: tokenIdentity.tokenIDs
        )
    }

}

private extension Array where Element == Int {
    func reusablePrefixCount(with promptTokenIDs: [Int]) -> Int {
        let limit = Swift.min(count, promptTokenIDs.count - 1)
        guard limit > 0 else {
            return 0
        }

        var index = 0
        while index < limit, self[index] == promptTokenIDs[index] {
            index += 1
        }
        return index
    }
}

private extension Array where Element == KVCache {
    var hasPromptState: Bool {
        let state = flatMap(\.state)
        return !state.isEmpty && state.allSatisfy { $0.size > 0 }
    }

    func hasSameStorage(as other: [KVCache]) -> Bool {
        guard count == other.count else {
            return false
        }
        return zip(self, other).allSatisfy { left, right in
            guard let leftObject = left as AnyObject?,
                  let rightObject = right as AnyObject? else {
                return false
            }
            return ObjectIdentifier(leftObject) == ObjectIdentifier(rightObject)
        }
    }
}

@discardableResult
private func trimPromptPrefixCache(_ cache: [KVCache], numTokens: Int) -> Int {
    guard numTokens > 0 else {
        return 0
    }

    var didTrim = false
    for entry in cache where !entry.state.isEmpty {
        entry.trim(numTokens)
        didTrim = true
    }

    guard didTrim else {
        return 0
    }
    return numTokens
}

private enum PromptPrefixSignature {
    static func cacheLayout(_ parameters: GenerateParameters) -> String {
        [
            "kvBits=\(parameters.kvBits.map(String.init) ?? "nil")",
            "kvGroupSize=\(parameters.kvGroupSize)",
            "quantizedKVStart=\(parameters.quantizedKVStart)"
        ].joined(separator: "&")
    }
}

public enum MLXServerChatSessionTranscriptText {
    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    public static func visibleAssistantContent(from generatedText: String, startsInThinking: Bool) -> String {
        var text = generatedText

        if startsInThinking {
            guard let closeRange = text.range(of: closeTag) else {
                return ""
            }
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

    public static func reasoningContent(from generatedText: String, startsInThinking: Bool) -> String {
        var text = generatedText
        var reasoning = ""

        if startsInThinking {
            if let closeRange = text.range(of: closeTag) {
                reasoning += text[..<closeRange.lowerBound]
                text.removeSubrange(text.startIndex..<closeRange.upperBound)
            } else {
                return text
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

private extension MLXServerChatMessage {
    var mlxChatMessage: Chat.Message {
        Chat.Message(
            role: mlxRole,
            content: content,
            images: imageURLs.map(UserInput.Image.url),
            videos: videoURLs.map(UserInput.Video.url)
        )
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
