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
    private var lastKnownSessionSnapshots: [String: AgentRuntimeSessionSnapshot] = [:]
    private var activePromptTasks: [UUID: Task<Void, Never>] = [:]
    private var activePromptTaskIDsBySessionID: [String: Set<UUID>] = [:]
    private var activePromptSessionIDsByTaskID: [UUID: String] = [:]
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
        allowedToolNames: Set<String>? = nil,
        preferredWorkspaceRootURL: URL? = nil
    ) async -> [DirectToolDescriptor] {
        await mcpRuntime.discoverDescriptors(
            allowedToolNames: allowedToolNames,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL
        )
    }

    public func knownMCPToolDescriptors(
        allowedToolNames: Set<String>? = nil,
        preferredWorkspaceRootURL: URL? = nil
    ) async -> [DirectToolDescriptor] {
        await mcpRuntime.knownDescriptors(
            allowedToolNames: allowedToolNames,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL
        )
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
        let initialSnapshot = await backend.snapshotSession(id: configuration.sessionID)
            ?? AgentRuntimeSessionSnapshot(configuration: configuration)
        let turnRecorder = AgentCorePromptTurnRecorder(
            initialSnapshot: initialSnapshot,
            prompt: prompt,
            attachments: attachments
        )

        do {
            let response = try await backend.sendPrompt(
                sessionID: configuration.sessionID,
                prompt: prompt,
                attachments: attachments,
                onEvent: { event in
                    await turnRecorder.record(event)
                    if case let .toolCallStarted(toolCall) = event {
                        await onToolWillExecute?(toolCall)
                    }
                    await onEvent(event)
                }
            )
            let recovery = await recoveredSessionSnapshot(
                backend: backend,
                configuration: configuration,
                recorder: turnRecorder
            )
            await restoreSessionIfNeeded(
                recovery,
                backend: backend,
                baseConfiguration: configuration
            )
            await onEvent(.sessionSnapshot(recovery.snapshot))
            await onEvent(.turnEnded(.completed))
            return response
        } catch is CancellationError {
            let recovery = await recoveredSessionSnapshot(
                backend: backend,
                configuration: configuration,
                recorder: turnRecorder
            )
            await restoreSessionIfNeeded(
                recovery,
                backend: backend,
                baseConfiguration: configuration
            )
            await onEvent(.sessionSnapshot(recovery.snapshot))
            await onEvent(.turnEnded(.cancelled))
            throw CancellationError()
        } catch {
            let recovery = await recoveredSessionSnapshot(
                backend: backend,
                configuration: configuration,
                recorder: turnRecorder
            )
            await restoreSessionIfNeeded(
                recovery,
                backend: backend,
                baseConfiguration: configuration
            )
            await onEvent(.sessionSnapshot(recovery.snapshot))
            await onEvent(.turnEnded(.failed(message: error.localizedDescription)))
            throw error
        }
    }

    public func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        guard let backend else {
            return []
        }
        return await backend.subAgentSnapshots()
    }

    public func snapshotSession(id sessionID: String) async -> AgentRuntimeSessionSnapshot? {
        if let snapshot = await backend?.snapshotSession(id: sessionID) {
            if let lastKnownSnapshot = lastKnownSessionSnapshots[sessionID],
               lastKnownSnapshot.isLikelyNewerThan(snapshot) {
                return lastKnownSnapshot
            }
            return snapshot
        }
        if let snapshot = lastKnownSessionSnapshots[sessionID] {
            return snapshot
        }
        guard let configuration = sessions[sessionID] else {
            return nil
        }
        return AgentRuntimeSessionSnapshot(
            sessionID: configuration.sessionID,
            modelID: configuration.modelID,
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
        let outcomeTracker = AgentCorePromptOutcomeTracker()
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
                    await outcomeTracker.record(event)
                    continuation.yield(event)
                }
                if await outcomeTracker.shouldEmitFallback() {
                    continuation.yield(.turnEnded(.completed))
                }
                clearActivePromptTask(id: promptID)
                continuation.finish()
            } catch is CancellationError {
                if await outcomeTracker.shouldEmitFallback() {
                    continuation.yield(.turnEnded(.cancelled))
                }
                clearActivePromptTask(id: promptID)
                continuation.finish(throwing: CancellationError())
            } catch {
                SwiftMLXLogger.error(
                    .viewModelRuntime,
                    "agent core session runner stream failed: \(error.localizedDescription)"
                )
                if await outcomeTracker.shouldEmitFallback() {
                    continuation.yield(.turnEnded(.failed(message: error.localizedDescription)))
                }
                clearActivePromptTask(id: promptID)
                continuation.finish(throwing: error)
            }
        }
        registerActivePromptTask(
            task,
            id: promptID,
            sessionID: configuration.sessionID
        )
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
        activePromptTaskIDsBySessionID.removeAll()
        activePromptSessionIDsByTaskID.removeAll()
        promptAuthorizationHandlers.removeAll()
        sessions.removeAll()
        lastKnownSessionSnapshots.removeAll()
        let backendToShutdown = backend
        backend = nil
        activeRuntimeConfiguration = nil
        await backendToShutdown?.shutdown()
    }

    public func cancelPrompt(sessionID: String) async {
        guard let promptIDs = activePromptTaskIDsBySessionID[sessionID] else {
            return
        }

        for promptID in promptIDs {
            activePromptTasks[promptID]?.cancel()
        }
    }

    public func resetSession(id sessionID: String? = nil) async {
        if let sessionID {
            cancelPromptTasks(for: sessionID)
            sessions.removeValue(forKey: sessionID)
            lastKnownSessionSnapshots.removeValue(forKey: sessionID)
            await backend?.clearSession(id: sessionID)
            return
        }

        for task in activePromptTasks.values {
            task.cancel()
        }
        activePromptTasks.removeAll()
        activePromptTaskIDsBySessionID.removeAll()
        activePromptSessionIDsByTaskID.removeAll()
        promptAuthorizationHandlers.removeAll()

        let sessionIDs = Array(sessions.keys)
        sessions.removeAll()
        lastKnownSessionSnapshots.removeAll()
        for sessionID in sessionIDs {
            await backend?.clearSession(id: sessionID)
        }
    }

    public func closeSession(id sessionID: String) async {
        cancelPromptTasks(for: sessionID)
        sessions.removeValue(forKey: sessionID)
        lastKnownSessionSnapshots.removeValue(forKey: sessionID)
        await backend?.closeSession(id: sessionID)
    }

    public func shutdown() async {
        for task in activePromptTasks.values {
            task.cancel()
        }
        activePromptTasks.removeAll()
        activePromptTaskIDsBySessionID.removeAll()
        activePromptSessionIDsByTaskID.removeAll()
        promptAuthorizationHandlers.removeAll()
        sessions.removeAll()
        lastKnownSessionSnapshots.removeAll()
        activeRuntimeConfiguration = nil
        let backendToShutdown = backend
        backend = nil
        await backendToShutdown?.shutdown()
        await mcpRuntime.shutdown()
    }

    private func registerActivePromptTask(
        _ task: Task<Void, Never>,
        id promptID: UUID,
        sessionID: String
    ) {
        activePromptTasks[promptID] = task
        activePromptSessionIDsByTaskID[promptID] = sessionID
        activePromptTaskIDsBySessionID[sessionID, default: []].insert(promptID)
    }

    private func cancelPromptTasks(for sessionID: String) {
        guard let promptIDs = activePromptTaskIDsBySessionID.removeValue(forKey: sessionID) else {
            return
        }

        for promptID in promptIDs {
            activePromptTasks.removeValue(forKey: promptID)?.cancel()
            activePromptSessionIDsByTaskID.removeValue(forKey: promptID)
            promptAuthorizationHandlers.removeValue(forKey: promptID)
        }
    }

    private func clearActivePromptTask(id promptID: UUID) {
        activePromptTasks.removeValue(forKey: promptID)
        if let sessionID = activePromptSessionIDsByTaskID.removeValue(forKey: promptID) {
            activePromptTaskIDsBySessionID[sessionID]?.remove(promptID)
            if activePromptTaskIDsBySessionID[sessionID]?.isEmpty == true {
                activePromptTaskIDsBySessionID.removeValue(forKey: sessionID)
            }
        }
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
        lastKnownSessionSnapshots.removeAll()
        activeRuntimeConfiguration = nil
        await backend?.shutdown()
        backend = nil
    }

    private func recoveredSessionSnapshot(
        backend: AgentCoreBackend,
        configuration: AgentCoreSessionConfiguration,
        recorder: AgentCorePromptTurnRecorder
    ) async -> AgentCoreSessionSnapshotRecovery {
        let recordedSnapshot = await recorder.snapshot()
        if let backendSnapshot = await backend.snapshotSession(id: configuration.sessionID),
           backendSnapshot.includesLikelyTurn(from: recordedSnapshot) {
            cacheSessionSnapshot(backendSnapshot, baseConfiguration: configuration)
            return AgentCoreSessionSnapshotRecovery(
                snapshot: backendSnapshot,
                shouldRestoreBackend: false
            )
        }

        cacheSessionSnapshot(recordedSnapshot, baseConfiguration: configuration)
        return AgentCoreSessionSnapshotRecovery(
            snapshot: recordedSnapshot,
            shouldRestoreBackend: true
        )
    }

    private func restoreSessionIfNeeded(
        _ recovery: AgentCoreSessionSnapshotRecovery,
        backend: AgentCoreBackend,
        baseConfiguration: AgentCoreSessionConfiguration
    ) async {
        guard recovery.shouldRestoreBackend else {
            return
        }
        let configuration = baseConfiguration.replacingRuntimeState(
            with: recovery.snapshot
        )
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
    }

    private func cacheSessionSnapshot(
        _ snapshot: AgentRuntimeSessionSnapshot,
        baseConfiguration: AgentCoreSessionConfiguration
    ) {
        lastKnownSessionSnapshots[snapshot.sessionID] = snapshot
        sessions[snapshot.sessionID] = baseConfiguration.replacingRuntimeState(
            with: snapshot
        )
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

private struct AgentCoreSessionSnapshotRecovery {
    let snapshot: AgentRuntimeSessionSnapshot
    let shouldRestoreBackend: Bool
}

private actor AgentCorePromptOutcomeTracker {
    private var didEmitOutcome = false

    func record(_ event: DirectAgentEvent) {
        if case .turnEnded = event {
            didEmitOutcome = true
        }
    }

    func shouldEmitFallback() -> Bool {
        guard !didEmitOutcome else {
            return false
        }
        didEmitOutcome = true
        return true
    }
}

private actor AgentCorePromptTurnRecorder {
    private let initialSnapshot: AgentRuntimeSessionSnapshot
    private var history: [AgentRuntimeMessage]
    private var assistantContent = ""
    private var assistantReasoning = ""
    private var assistantToolCalls: [AgentRuntimeToolCall] = []

    init(
        initialSnapshot: AgentRuntimeSessionSnapshot,
        prompt: String,
        attachments: [AgentRuntimeAttachment]
    ) {
        self.initialSnapshot = initialSnapshot
        self.history = initialSnapshot.history

        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedPrompt.isEmpty || !attachments.isEmpty {
            history.append(
                AgentRuntimeMessage(
                    role: .user,
                    content: normalizedPrompt,
                    attachments: attachments
                )
            )
        }
    }

    func record(_ event: DirectAgentEvent) {
        switch event {
        case let .thought(delta):
            assistantReasoning.append(delta)
        case let .content(delta):
            assistantContent.append(delta)
        case let .toolCallStarted(toolCall):
            recordToolCall(toolCall)
        case let .toolCallCompleted(toolCall, result):
            recordToolCall(toolCall)
            flushAssistantIfNeeded()
            history.append(
                AgentRuntimeMessage(
                    role: .tool,
                    content: result.output,
                    toolCallID: toolCall.id,
                    toolName: toolCall.name
                )
            )
        case .status,
             .diagnostic,
             .modelLoaded,
             .modelLoadedDetails,
             .modelRuntime,
             .metrics,
             .contextWindow,
             .sessionSnapshot,
             .turnEnded:
            break
        }
    }

    func snapshot() -> AgentRuntimeSessionSnapshot {
        var snapshotHistory = history
        if let assistantMessage = pendingAssistantMessage() {
            snapshotHistory.append(assistantMessage)
        }
        return AgentRuntimeSessionSnapshot(
            sessionID: initialSnapshot.sessionID,
            modelID: initialSnapshot.modelID,
            workingDirectoryPath: initialSnapshot.workingDirectoryPath,
            systemPrompt: initialSnapshot.systemPrompt,
            cacheKey: initialSnapshot.cacheKey,
            history: snapshotHistory,
            allowedToolNames: initialSnapshot.allowedToolNames,
            thinkingSelection: initialSnapshot.thinkingSelection,
            preserveThinking: initialSnapshot.preserveThinking
        )
    }

    private func recordToolCall(_ toolCall: DirectAgentToolCall) {
        let runtimeToolCall = AgentRuntimeToolCall(
            id: toolCall.id,
            name: toolCall.name,
            argumentsJSON: toolCall.argumentsJSON
        )
        guard !assistantToolCalls.contains(runtimeToolCall) else {
            return
        }
        assistantToolCalls.append(runtimeToolCall)
    }

    private func flushAssistantIfNeeded() {
        guard let assistantMessage = pendingAssistantMessage() else {
            return
        }
        history.append(assistantMessage)
        assistantContent = ""
        assistantReasoning = ""
        assistantToolCalls = []
    }

    private func pendingAssistantMessage() -> AgentRuntimeMessage? {
        let hasContent = !assistantContent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        let hasReasoning = !assistantReasoning
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        guard hasContent || hasReasoning || !assistantToolCalls.isEmpty else {
            return nil
        }
        return AgentRuntimeMessage(
            role: .assistant,
            content: assistantContent,
            reasoningContent: assistantReasoning,
            toolCalls: assistantToolCalls
        )
    }
}

private extension AgentRuntimeSessionSnapshot {
    init(configuration: AgentCoreSessionConfiguration) {
        self.init(
            sessionID: configuration.sessionID,
            modelID: configuration.modelID,
            workingDirectoryPath: configuration.workingDirectoryPath,
            systemPrompt: configuration.systemPrompt,
            cacheKey: configuration.cacheKey,
            history: configuration.history,
            allowedToolNames: configuration.allowedToolNames,
            thinkingSelection: configuration.thinkingSelection,
            preserveThinking: configuration.preserveThinking
        )
    }

    func isLikelyNewerThan(_ other: AgentRuntimeSessionSnapshot) -> Bool {
        sessionID == other.sessionID && history.count > other.history.count
    }

    func includesLikelyTurn(from recordedSnapshot: AgentRuntimeSessionSnapshot) -> Bool {
        guard sessionID == recordedSnapshot.sessionID else {
            return false
        }
        if history.count >= recordedSnapshot.history.count {
            return true
        }

        let tail = recordedSnapshot.history.suffix(
            min(3, recordedSnapshot.history.count)
        )
        return !tail.isEmpty && tail.allSatisfy { history.contains($0) }
    }
}

private extension AgentCoreSessionConfiguration {
    func replacingRuntimeState(
        with snapshot: AgentRuntimeSessionSnapshot
    ) -> AgentCoreSessionConfiguration {
        AgentCoreSessionConfiguration(
            sessionID: snapshot.sessionID,
            modelID: snapshot.modelID ?? modelID,
            bearerToken: bearerToken,
            workingDirectory: URL(fileURLWithPath: snapshot.workingDirectoryPath),
            systemPrompt: snapshot.systemPrompt,
            cacheKey: snapshot.cacheKey,
            sessionRevision: sessionRevision,
            history: snapshot.history,
            allowedToolNames: snapshot.allowedToolNames,
            configuredContextWindowLimit: configuredContextWindowLimit,
            generationParameterOverrides: generationParameterOverrides,
            maxToolRounds: maxToolRounds,
            maxOutputTokens: maxOutputTokens,
            verboseLogging: verboseLogging,
            appMode: appMode,
            thinkingSelection: snapshot.thinkingSelection,
            preserveThinking: snapshot.preserveThinking
        )
    }
}
