//
//  MLXServerRuntime.swift
//  mlx-server
//

import Foundation
@preconcurrency import MLXLMCommon

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

    public init(
        role: Role,
        content: String,
        imageURLs: [URL] = [],
        videoURLs: [URL] = []
    ) {
        self.role = role
        self.content = content
        self.imageURLs = imageURLs
        self.videoURLs = videoURLs
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

    public static func assistant(_ content: String) -> Self {
        Self(role: .assistant, content: content)
    }

    public static func tool(_ content: String) -> Self {
        Self(role: .tool, content: content)
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

public protocol MLXServerRuntimeGenerating: Sendable {
    func generateChatSession(
        request: MLXServerGenerationRequest
    ) async throws -> AsyncStream<Generation>

    func generateChatSessionText(
        request: MLXServerGenerationRequest
    ) async throws -> MLXServerGenerationOutput
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

public enum MLXServerToolTranscript {
    public static func toolCall(name: String, arguments: String) -> String {
        "function_call: \(name)\narguments: \(arguments)"
    }

    public static func toolCall(_ toolCall: ToolCall) -> String {
        self.toolCall(
            name: toolCall.function.name,
            arguments: (try? encodedJSONString(toolCall.function.arguments)) ?? "{}"
        )
    }

    public static func toolOutput(callID: String?, output: String) -> String {
        if let callID, !callID.isEmpty {
            return "call_id: \(callID)\n\(output)"
        }
        return output
    }

    private static func encodedJSONString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
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
    private var chatSessions: [ChatSessionKey: [ChatSessionState]] = [:]
    private var chatSessionGeneration: UInt64 = 0
    private let generationGate = MLXServerGenerationGate()
    private let retentionPolicy: MLXServerModelRetentionPolicy
    private let diskKVCacheStore: MLXServerDiskKVCacheStore?

    public init(
        retentionPolicy: MLXServerModelRetentionPolicy = .keepLoadedModels,
        diskKVCacheConfiguration: MLXServerDiskKVCacheConfiguration = .init()
    ) {
        self.retentionPolicy = retentionPolicy
        self.diskKVCacheStore = diskKVCacheConfiguration.isEnabled
            ? MLXServerDiskKVCacheStore(configuration: diskKVCacheConfiguration)
            : nil
    }

    public var loadedModelIDs: [String] {
        containers.keys.map(\.displayName).sorted()
    }

    public func unloadAll() {
        containers.removeAll(keepingCapacity: true)
        loadingTasks.removeAll(keepingCapacity: true)
        chatSessions.removeAll(keepingCapacity: true)
    }

    public func generate(
        request: MLXServerGenerationRequest,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> AsyncStream<Generation> {
        await generationGate.acquire()

        let container = try await container(
            for: request.model,
            runtimeKind: request.runtimeKind,
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
        guard let descriptor = ChatSessionDescriptor(request: request) else {
            return try await generate(request: request, progressHandler: progressHandler)
        }

        await generationGate.acquire()

        let container = try await container(
            for: request.model,
            runtimeKind: request.runtimeKind,
            progressHandler: progressHandler
        )

        let state: ChatSessionState
        let parameters = request.parameters
        if let cached = cachedChatSession(for: descriptor) {
            state = cached
            state.session.generateParameters = parameters
            state.session.processing = .init(resize: request.mediaResize)
            state.session.additionalContext = request.additionalContext
            state.session.tools = request.tools
        } else if let restoredCache = restoredDiskCache(for: descriptor, parameters: parameters) {
            let session = ChatSession(
                container,
                instructions: nil,
                cache: restoredCache,
                generateParameters: parameters,
                processing: .init(resize: request.mediaResize),
                additionalContext: request.additionalContext,
                tools: request.tools
            )
            state = registerChatSession(session, for: descriptor)
        } else {
            let session = ChatSession(
                container,
                instructions: nil,
                history: descriptor.history,
                generateParameters: parameters,
                processing: .init(resize: request.mediaResize),
                additionalContext: request.additionalContext,
                tools: request.tools
            )
            state = registerChatSession(session, for: descriptor)
        }

        let current = descriptor.current
        let currentFingerprint = descriptor.currentFingerprint
        let priorTranscript = descriptor.priorTranscript
        let key = descriptor.key
        let sessionID = state.id
        let emitsThinking = request.emitsThinking
        let retainsReasoningInHistory = request.retainsReasoningInHistory
        let stream = state.session.streamDetails(
            to: current.content,
            role: current.mlxRole,
            images: current.imageURLs.map(UserInput.Image.url),
            videos: current.videoURLs.map(UserInput.Video.url)
        )

        return AsyncStream { continuation in
            let task = Task.detached {
                var assistantText = ""
                var toolCalls: [ToolCall] = []
                var completed = false
                do {
                    for try await event in stream {
                        if Task.isCancelled {
                            break
                        }
                        switch event {
                        case .chunk(let chunk):
                            assistantText += chunk
                        case .toolCall(let toolCall):
                            toolCalls.append(toolCall)
                        case .info:
                            break
                        }
                        if case .info = event {
                            completed = true
                        }
                        continuation.yield(event)
                    }
                } catch {
                    completed = false
                }
                if completed, !Task.isCancelled {
                    await self.finishChatSessionTurn(
                        key: key,
                        sessionID: sessionID,
                        priorTranscript: priorTranscript,
                        current: currentFingerprint,
                        reasoningText: retainsReasoningInHistory
                            ? MLXServerChatSessionTranscriptText.reasoningContent(
                                from: assistantText,
                                startsInThinking: emitsThinking
                            )
                            : "",
                        assistantText: MLXServerChatSessionTranscriptText.visibleAssistantContent(
                            from: assistantText,
                            startsInThinking: emitsThinking
                        ),
                        toolCalls: toolCalls
                    )
                } else {
                    await self.invalidateChatSession(key: key, sessionID: sessionID)
                }
                await self.generationGate.release()
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
            return container
        } catch {
            loadingTasks[key] = nil
            throw error
        }
    }

    private func unloadOtherModelsBeforeLoading(_ key: LoadedModelKey) {
        containers = containers.filter { $0.key == key }
        chatSessions.removeAll(keepingCapacity: true)
        for (loadingKey, task) in loadingTasks where loadingKey != key {
            task.cancel()
        }
        loadingTasks = loadingTasks.filter { $0.key == key }
    }

    private func cachedChatSession(for descriptor: ChatSessionDescriptor) -> ChatSessionState? {
        guard var states = chatSessions[descriptor.key],
              let index = states.lastIndex(where: { $0.transcript == descriptor.priorTranscript }) else {
            return nil
        }
        chatSessionGeneration += 1
        states[index].lastAccessGeneration = chatSessionGeneration
        chatSessions[descriptor.key] = states
        return states[index]
    }

    private func restoredDiskCache(
        for descriptor: ChatSessionDescriptor,
        parameters: GenerateParameters
    ) -> [KVCache]? {
        guard !descriptor.priorTranscript.isEmpty else {
            return nil
        }
        return diskKVCacheStore?.loadCache(
            for: MLXServerDiskKVCacheIdentity(
                key: descriptor.key,
                transcript: descriptor.priorTranscript,
                parameters: parameters
            )
        )
    }

    private func registerChatSession(
        _ session: ChatSession,
        for descriptor: ChatSessionDescriptor
    ) -> ChatSessionState {
        chatSessionGeneration += 1
        let state = ChatSessionState(
            id: ChatSessionID(rawValue: chatSessionGeneration),
            session: session,
            transcript: descriptor.priorTranscript,
            lastAccessGeneration: chatSessionGeneration
        )
        chatSessions[descriptor.key, default: []].append(state)
        trimChatSessions(for: descriptor.key)
        return state
    }

    private func finishChatSessionTurn(
        key: ChatSessionKey,
        sessionID: ChatSessionID,
        priorTranscript: [ChatSessionMessageFingerprint],
        current: ChatSessionMessageFingerprint,
        reasoningText: String,
        assistantText: String,
        toolCalls: [ToolCall]
    ) async {
        guard var states = chatSessions[key],
              let index = states.firstIndex(where: { $0.id == sessionID }) else {
            return
        }
        chatSessionGeneration += 1
        var state = states[index]
        guard state.transcript == priorTranscript else {
            states.remove(at: index)
            chatSessions[key] = states.isEmpty ? nil : states
            return
        }
        var nextTranscript = priorTranscript + [current]
        if !reasoningText.isEmpty {
            nextTranscript.append(
                ChatSessionMessageFingerprint(
                    role: .assistant,
                    content: MLXServerReasoningTranscript.reasoningSummary(reasoningText)
                        .normalizedForChatSessionMatch,
                    imageURLs: [],
                    videoURLs: []
                )
            )
        }
        if !assistantText.isEmpty {
            nextTranscript.append(
                ChatSessionMessageFingerprint(
                    role: .assistant,
                    content: assistantText.normalizedForChatSessionMatch,
                    imageURLs: [],
                    videoURLs: []
                )
            )
        }
        nextTranscript.append(
            contentsOf: toolCalls.map { toolCall in
                ChatSessionMessageFingerprint(
                    role: .assistant,
                    content: MLXServerToolTranscript.toolCall(toolCall).normalizedForChatSessionMatch,
                    imageURLs: [],
                    videoURLs: []
                )
            }
        )
        if reasoningText.isEmpty, assistantText.isEmpty, toolCalls.isEmpty {
            nextTranscript.append(
                ChatSessionMessageFingerprint(
                    role: .assistant,
                    content: "",
                    imageURLs: [],
                    videoURLs: []
                )
            )
        }

        state.transcript = nextTranscript
        state.lastAccessGeneration = chatSessionGeneration
        states[index] = state
        chatSessions[key] = states
        trimChatSessions(for: key)

        if !state.transcript.isEmpty {
            let identity = MLXServerDiskKVCacheIdentity(
                key: key,
                transcript: state.transcript,
                parameters: state.session.generateParameters
            )
            await persistDiskCacheIfNeeded(
                session: state.session,
                identity: identity
            )
        }
    }

    private func persistDiskCacheIfNeeded(
        session: ChatSession,
        identity: MLXServerDiskKVCacheIdentity
    ) async {
        guard let diskKVCacheStore,
              let target = try? diskKVCacheStore.preparePersistenceTarget(for: identity) else {
            return
        }

        do {
            // The generation gate is still held here, so this session can not
            // be mutated by another request while ChatSession serializes the
            // underlying KV cache read for persistence.
            nonisolated(unsafe) let cacheSession = session
            try await cacheSession.saveCache(to: target.temporaryURL)
            try diskKVCacheStore.commitPersistedCache(
                identity: identity,
                target: target
            )
        } catch {
            diskKVCacheStore.discardPersistenceTarget(target)
        }
    }

    private func invalidateChatSession(key: ChatSessionKey, sessionID: ChatSessionID) {
        guard var states = chatSessions[key],
              let index = states.firstIndex(where: { $0.id == sessionID }) else {
            return
        }
        states.remove(at: index)
        chatSessions[key] = states.isEmpty ? nil : states
    }

    private func trimChatSessions(for key: ChatSessionKey) {
        guard var states = chatSessions[key], states.count > 8 else {
            return
        }
        states.sort { $0.lastAccessGeneration > $1.lastAccessGeneration }
        chatSessions[key] = Array(states.prefix(8))
    }

}

private struct LoadedModelKey: Hashable, Sendable {
    var modelID: String
    var runtimeKind: MLXServerModelRuntimeKind

    var displayName: String {
        "\(modelID) [\(runtimeKind.rawValue)]"
    }
}

private struct ChatSessionID: Hashable, Sendable {
    var rawValue: UInt64
}

private struct ChatSessionKey: Hashable, Sendable {
    var modelID: String
    var runtimeKind: MLXServerModelRuntimeKind
    var systemSignature: String
    var toolsSignature: String
    var additionalContextSignature: String
    var mediaResizeSignature: String
    var retainsReasoningInHistory: Bool

    var signature: String {
        [
            modelID,
            runtimeKind.rawValue,
            systemSignature,
            toolsSignature,
            additionalContextSignature,
            mediaResizeSignature,
            retainsReasoningInHistory ? "reasoning-history" : "visible-history"
        ].joined(separator: "\u{1C}")
    }
}

private struct ChatSessionState {
    var id: ChatSessionID
    var session: ChatSession
    var transcript: [ChatSessionMessageFingerprint]
    var lastAccessGeneration: UInt64
}

private struct ChatSessionDescriptor {
    var key: ChatSessionKey
    var history: [Chat.Message]
    var priorTranscript: [ChatSessionMessageFingerprint]
    var current: MLXServerChatMessage
    var currentFingerprint: ChatSessionMessageFingerprint

    init?(request: MLXServerGenerationRequest) {
        let systemMessages = request.messages.filter { $0.role == .system }
        let nonSystemMessages = request.messages.filter { $0.role != .system }
        guard let current = nonSystemMessages.last else {
            return nil
        }

        let priorMessages = nonSystemMessages.dropLast()
        let priorTranscript = priorMessages.map(ChatSessionMessageFingerprint.init(message:))
        let systemSignature = systemMessages.map(ChatSessionMessageFingerprint.init(message:))
            .map(\.signature)
            .joined(separator: "\u{1E}")

        key = ChatSessionKey(
            modelID: request.model.id,
            runtimeKind: request.runtimeKind,
            systemSignature: systemSignature,
            toolsSignature: ChatSessionSignature.tools(request.tools),
            additionalContextSignature: ChatSessionSignature.additionalContext(request.additionalContext),
            mediaResizeSignature: ChatSessionSignature.mediaResize(request.mediaResize),
            retainsReasoningInHistory: request.retainsReasoningInHistory
        )
        history = systemMessages.map(\.mlxChatMessage) + priorMessages.map(\.mlxChatMessage)
        self.priorTranscript = priorTranscript
        self.current = current
        currentFingerprint = ChatSessionMessageFingerprint(message: current)
    }
}

extension MLXServerDiskKVCacheIdentity {
    fileprivate init(
        key: ChatSessionKey,
        transcript: [ChatSessionMessageFingerprint],
        parameters: GenerateParameters
    ) {
        self.init(
            modelID: key.modelID,
            runtimeKind: key.runtimeKind,
            chatKeySignature: key.signature,
            transcriptSignature: ChatSessionSignature.transcript(transcript),
            cacheLayoutSignature: ChatSessionSignature.cacheLayout(parameters)
        )
    }
}

private struct ChatSessionMessageFingerprint: Hashable, Sendable {
    var role: MLXServerChatMessage.Role
    var content: String
    var imageURLs: [String]
    var videoURLs: [String]
    var toolCallCount: Int

    init(
        role: MLXServerChatMessage.Role,
        content: String,
        imageURLs: [String],
        videoURLs: [String],
        toolCallCount: Int = 0
    ) {
        self.role = role
        self.content = content
        self.imageURLs = imageURLs
        self.videoURLs = videoURLs
        self.toolCallCount = toolCallCount
    }

    init(message: MLXServerChatMessage) {
        self.init(
            role: message.role,
            content: message.content.normalizedForChatSessionMatch,
            imageURLs: message.imageURLs.map(\.absoluteString),
            videoURLs: message.videoURLs.map(\.absoluteString)
        )
    }

    var signature: String {
        [
            role.rawValue,
            content,
            imageURLs.joined(separator: "\u{1D}"),
            videoURLs.joined(separator: "\u{1D}"),
            String(toolCallCount)
        ].joined(separator: "\u{1F}")
    }
}

private extension String {
    var normalizedForChatSessionMatch: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum ChatSessionSignature {
    static func transcript(_ transcript: [ChatSessionMessageFingerprint]) -> String {
        transcript.map(\.signature).joined(separator: "\u{1E}")
    }

    static func cacheLayout(_ parameters: GenerateParameters) -> String {
        [
            "kvBits=\(parameters.kvBits.map(String.init) ?? "nil")",
            "kvGroupSize=\(parameters.kvGroupSize)",
            "quantizedKVStart=\(parameters.quantizedKVStart)"
        ].joined(separator: "&")
    }

    static func tools(_ tools: [ToolSpec]?) -> String {
        guard let tools else {
            return ""
        }
        return tools.map(canonical).joined(separator: "\u{1E}")
    }

    static func additionalContext(_ context: [String: any Sendable]?) -> String {
        guard let context else {
            return ""
        }
        return canonical(context)
    }

    static func mediaResize(_ size: CGSize?) -> String {
        guard let size else {
            return ""
        }
        return "\(size.width)x\(size.height)"
    }

    private static func canonical(_ value: Any) -> String {
        switch value {
        case let value as String:
            "s:\(value)"
        case let value as Bool:
            "b:\(value)"
        case let value as Int:
            "i:\(value)"
        case let value as Double:
            "d:\(value)"
        case let value as Float:
            "f:\(value)"
        case let value as [String: any Sendable]:
            value.keys.sorted()
                .map { key in "\(key)=\(canonical(value[key] as Any))" }
                .joined(separator: "&")
        case let value as [any Sendable]:
            value.map { canonical($0) }.joined(separator: ",")
        case is NSNull:
            "null"
        default:
            String(describing: value)
        }
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
