//
//  AgentCoreSessionRunner.swift
//  MLXCoder
//

import Foundation

public actor AgentCoreSessionRunner {
    public static var isAvailable: Bool {
        true
    }

    private var backend: AgentCoreBackend?
    private var activeRuntimeConfiguration: AgentCoreSessionConfiguration?
    private var sessions: [String: AgentCoreSessionConfiguration] = [:]
    private var activePromptTasks: [UUID: Task<Void, Never>] = [:]
    private var promptAuthorizationHandlers: [UUID: AgentToolAuthorizationHandler] = [:]
    private let defaultToolAuthorizationHandler: AgentToolAuthorizationHandler?
    private let mcpRuntime: DirectMCPToolRuntime
    private let backendFactory: AgentRuntimeBackendFactory?

    public init(
        defaultToolAuthorizationHandler: AgentToolAuthorizationHandler? = nil,
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime(),
        backendFactory: AgentRuntimeBackendFactory? = nil
    ) {
        self.defaultToolAuthorizationHandler = defaultToolAuthorizationHandler
        self.mcpRuntime = mcpRuntime
        self.backendFactory = backendFactory
    }

    public func mcpToolDescriptors(
        allowedToolNames: Set<String>? = nil
    ) async -> [DirectToolDescriptor] {
        await mcpRuntime.discoverDescriptors(allowedToolNames: allowedToolNames)
    }

    public func knownMCPToolDescriptors(
        allowedToolNames: Set<String>? = nil
    ) async -> [DirectToolDescriptor] {
        await mcpRuntime.knownDescriptors(allowedToolNames: allowedToolNames)
    }

    public func installBorrowedXcodeExecutor(
        _ executor: XcodeToolExecutor?,
        tools: [ToolDescriptor]
    ) async {
        guard let executor,
              !tools.isEmpty else {
            return
        }

        await mcpRuntime.installBorrowedXcodeExecutor(
            executor,
            tools: tools
        )
    }

    public func createSession(
        configuration: AgentCoreSessionConfiguration
    ) async throws {
        let backend = try await ensureBackend(configuration: configuration)
        await backend.createSession(
            id: configuration.sessionID,
            cwd: configuration.workingDirectoryPath,
            systemPrompt: configuration.systemPrompt,
            history: configuration.history,
            cacheKey: configuration.cacheKey,
            allowedToolNames: configuration.allowedToolNames,
            thinkingSelection: configuration.thinkingSelection,
            preserveThinking: configuration.preserveThinking
        )
        sessions[configuration.sessionID] = configuration
        SwiftMLXLogger.debug(
            .viewModelRuntime,
            "agent core session runner created session id=\(configuration.sessionID) history=\(configuration.history.count) tools=\(configuration.allowedToolNames?.count ?? 0)."
        )
    }

    public func updateSessionOptions(
        configuration: AgentCoreSessionConfiguration
    ) async throws {
        let backend = try await ensureBackend(configuration: configuration)
        await backend.updateSessionOptions(
            id: configuration.sessionID,
            systemPrompt: configuration.systemPrompt,
            allowedToolNames: configuration.allowedToolNames,
            thinkingSelection: configuration.thinkingSelection,
            preserveThinking: configuration.preserveThinking
        )
        sessions[configuration.sessionID] = configuration
    }

    public func preloadModel(
        configuration: AgentCoreSessionConfiguration,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        let backend = try await ensureBackend(configuration: configuration)
        return try await backend.preloadModel(onEvent: onEvent)
    }

    public func preloadModel(
        configuration: AgentCoreSessionConfiguration
    ) -> AsyncThrowingStream<DirectAgentEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<DirectAgentEvent, Error>.makeStream()
        let task = Task(priority: .userInitiated) {
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated],
                reason: "MLX agent model load"
            )
            defer {
                ProcessInfo.processInfo.endActivity(activity)
            }
            do {
                _ = try await preloadModel(configuration: configuration) { event in
                    continuation.yield(event)
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: CancellationError())
            } catch {
                SwiftMLXLogger.error(
                    .viewModelRuntime,
                    "agent core session runner preload failed: \(error.localizedDescription)"
                )
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            task.cancel()
        }
        return stream
    }

    public func sendPrompt(
        configuration: AgentCoreSessionConfiguration,
        prompt: String,
        attachments: [AgentRuntimeAttachment],
        authorizeTool: AgentToolAuthorizationHandler? = nil,
        onToolWillExecute: (@Sendable (DirectAgentToolCall) async -> Void)? = nil,
        borrowedOrchestrationToolExecutor: AgentBorrowedToolExecutor? = nil,
        toolProviders: [AgentToolProvider] = [],
        borrowedXcodeExecutor: XcodeToolExecutor? = nil,
        borrowedXcodeTools: [ToolDescriptor] = [],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        let promptID = UUID()
        if let authorizeTool {
            promptAuthorizationHandlers[promptID] = authorizeTool
        }
        defer {
            promptAuthorizationHandlers.removeValue(forKey: promptID)
        }

        await installBorrowedXcodeExecutor(
            borrowedXcodeExecutor,
            tools: borrowedXcodeTools
        )
        let backend = try await ensureBackend(configuration: configuration)
        await backend.updateBorrowedOrchestrationToolExecutor(
            borrowedOrchestrationToolExecutor
        )
        await backend.updateToolProviders(toolProviders)
        try await ensureSession(configuration: configuration)

        return try await backend.sendPrompt(
            sessionID: configuration.sessionID,
            prompt: prompt,
            attachments: attachments,
            onEvent: { event in
                if case let .toolCallStarted(toolCall) = event {
                    await onToolWillExecute?(toolCall)
                }
                await onEvent(event)
            }
        )
    }

    public func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        guard let backend else {
            return []
        }
        return await backend.subAgentSnapshots()
    }

    public func snapshotSession(id sessionID: String) async -> AgentRuntimeSessionSnapshot? {
        if let snapshot = await backend?.snapshotSession(id: sessionID) {
            return snapshot
        }
        guard let configuration = sessions[sessionID] else {
            return nil
        }
        return AgentRuntimeSessionSnapshot(
            sessionID: configuration.sessionID,
            workingDirectoryPath: configuration.workingDirectoryPath,
            systemPrompt: configuration.systemPrompt,
            cacheKey: configuration.cacheKey,
            history: configuration.history,
            allowedToolNames: configuration.allowedToolNames,
            thinkingSelection: configuration.thinkingSelection,
            preserveThinking: configuration.preserveThinking
        )
    }

    public func streamPrompt(
        _ prompt: String,
        configuration: AgentCoreSessionConfiguration,
        attachments: [AgentRuntimeAttachment] = [],
        authorizeTool: AgentToolAuthorizationHandler? = nil,
        onToolWillExecute: (@Sendable (DirectAgentToolCall) async -> Void)? = nil,
        borrowedOrchestrationToolExecutor: AgentBorrowedToolExecutor? = nil,
        toolProviders: [AgentToolProvider] = [],
        borrowedXcodeExecutor: XcodeToolExecutor? = nil,
        borrowedXcodeTools: [ToolDescriptor] = []
    ) -> AsyncThrowingStream<DirectAgentEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<DirectAgentEvent, Error>.makeStream()
        let promptID = UUID()
        let task = Task(priority: .userInitiated) {
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical],
                reason: "MLX agent generation"
            )
            defer {
                ProcessInfo.processInfo.endActivity(activity)
            }
            do {
                _ = try await sendPrompt(
                    configuration: configuration,
                    prompt: prompt,
                    attachments: attachments,
                    authorizeTool: authorizeTool,
                    onToolWillExecute: onToolWillExecute,
                    borrowedOrchestrationToolExecutor: borrowedOrchestrationToolExecutor,
                    toolProviders: toolProviders,
                    borrowedXcodeExecutor: borrowedXcodeExecutor,
                    borrowedXcodeTools: borrowedXcodeTools
                ) { event in
                    continuation.yield(event)
                }
                clearActivePromptTask(id: promptID)
                continuation.finish()
            } catch is CancellationError {
                clearActivePromptTask(id: promptID)
                continuation.finish(throwing: CancellationError())
            } catch {
                SwiftMLXLogger.error(
                    .viewModelRuntime,
                    "agent core session runner stream failed: \(error.localizedDescription)"
                )
                clearActivePromptTask(id: promptID)
                continuation.finish(throwing: error)
            }
        }
        activePromptTasks[promptID] = task
        continuation.onTermination = { _ in
            task.cancel()
            Task {
                await self.clearActivePromptTask(id: promptID)
            }
        }
        return stream
    }

    public func cancelActivePrompt() async {
        for task in activePromptTasks.values {
            task.cancel()
        }
        activePromptTasks.removeAll()
        promptAuthorizationHandlers.removeAll()
        sessions.removeAll()
        let backendToShutdown = backend
        backend = nil
        activeRuntimeConfiguration = nil
        await backendToShutdown?.shutdown()
    }

    public func resetSession(id sessionID: String? = nil) async {
        for task in activePromptTasks.values {
            task.cancel()
        }
        activePromptTasks.removeAll()
        promptAuthorizationHandlers.removeAll()

        if let sessionID {
            sessions.removeValue(forKey: sessionID)
            await backend?.clearSession(id: sessionID)
            return
        }

        let sessionIDs = Array(sessions.keys)
        sessions.removeAll()
        for sessionID in sessionIDs {
            await backend?.clearSession(id: sessionID)
        }
    }

    public func closeSession(id sessionID: String) async {
        sessions.removeValue(forKey: sessionID)
        await backend?.closeSession(id: sessionID)
    }

    public func shutdown() async {
        for task in activePromptTasks.values {
            task.cancel()
        }
        activePromptTasks.removeAll()
        promptAuthorizationHandlers.removeAll()
        sessions.removeAll()
        activeRuntimeConfiguration = nil
        let backendToShutdown = backend
        backend = nil
        await backendToShutdown?.shutdown()
        await mcpRuntime.shutdown()
    }

    private func clearActivePromptTask(id promptID: UUID) {
        activePromptTasks.removeValue(forKey: promptID)
        promptAuthorizationHandlers.removeValue(forKey: promptID)
    }

    private func ensureSession(
        configuration: AgentCoreSessionConfiguration
    ) async throws {
        if let existing = sessions[configuration.sessionID] {
            if existing.matchesSessionIdentity(configuration) {
                return
            }
            if existing.matchesSessionIdentityIgnoringThinking(configuration) {
                try await updateSessionOptions(configuration: configuration)
                return
            }
        }
        try await createSession(configuration: configuration)
    }

    private func ensureBackend(
        configuration: AgentCoreSessionConfiguration
    ) async throws -> AgentCoreBackend {
        if let activeRuntimeConfiguration,
           !activeRuntimeConfiguration.matchesRuntime(configuration) {
            await resetBackend()
        }

        if let backend {
            return backend
        }

        let runtimeConfiguration = configuration.runtimeConfiguration
            .withToolAuthorizationHandler { request in
                await self.authorizeTool(request)
            }
        let backend = AgentCoreBackend(
            configuration: runtimeConfiguration,
            mcpRuntime: mcpRuntime,
            backendFactory: backendFactory
        )
        self.backend = backend
        activeRuntimeConfiguration = configuration
        SwiftMLXLogger.debug(
            .viewModelRuntime,
            "agent core session runner initialized model=\(configuration.modelID ?? "default") cwd=\(configuration.workingDirectoryPath)."
        )
        return backend
    }

    private func resetBackend() async {
        sessions.removeAll()
        activeRuntimeConfiguration = nil
        await backend?.shutdown()
        backend = nil
    }

    private func authorizeTool(_ request: AgentToolAuthorizationRequest) async -> Bool {
        for handler in promptAuthorizationHandlers.values {
            return await handler(request)
        }
        guard let defaultToolAuthorizationHandler else {
            return true
        }
        return await defaultToolAuthorizationHandler(request)
    }
}
