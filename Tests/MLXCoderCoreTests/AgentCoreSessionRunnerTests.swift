import Foundation
@testable import MLXCoderCore
import Testing

@Suite
struct AgentCoreSessionRunnerTests {
    @Test
    func updateSessionOptionsPropagatesSystemPrompt() async throws {
        let backend = CapturingAgentRuntimeBackend()
        let runner = AgentCoreSessionRunner(
            backendFactory: { _, _ in backend }
        )
        let sessionID = "session-\(UUID().uuidString)"
        let workingDirectory = FileManager.default.temporaryDirectory
        let initialConfiguration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: workingDirectory,
            systemPrompt: "Memory tools: enabled.",
            cacheKey: nil,
            history: [],
            allowedToolNames: ["memory.read"]
        )
        let updatedConfiguration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: workingDirectory,
            systemPrompt: "Memory tools are unavailable.",
            cacheKey: nil,
            history: [],
            allowedToolNames: []
        )

        try await runner.createSession(configuration: initialConfiguration)
        _ = try await runner.sendPrompt(
            configuration: initialConfiguration,
            prompt: "hello",
            attachments: [],
            onEvent: { _ in }
        )
        try await runner.updateSessionOptions(configuration: updatedConfiguration)

        #expect(await backend.lastUpdatedSystemPrompt() == "Memory tools are unavailable.")
        #expect(await backend.lastUpdatedAllowedToolNames() == [])
    }

    @Test
    func failedPromptPublishesRecoveredSessionSnapshot() async throws {
        let backend = CapturingAgentRuntimeBackend(
            promptEvents: [.content("partial answer")],
            sendPromptError: SyntheticPromptError()
        )
        let runner = AgentCoreSessionRunner(
            backendFactory: { _, _ in backend }
        )
        let sessionID = "session-\(UUID().uuidString)"
        let configuration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            allowedToolNames: []
        )
        let snapshotCollector = SnapshotCollector()
        var didThrow = false

        do {
            _ = try await runner.sendPrompt(
                configuration: configuration,
                prompt: "hello",
                attachments: [],
                onEvent: { event in
                    await snapshotCollector.record(event)
                }
            )
        } catch is SyntheticPromptError {
            didThrow = true
        }

        let snapshots = await snapshotCollector.snapshots()
        let outcomes = await snapshotCollector.outcomes()
        #expect(didThrow)
        #expect(snapshots.count == 1)
        #expect(outcomes == [.failed(message: "Synthetic prompt failed.")])
        let history = try #require(snapshots.first?.history)
        #expect(history.count == 2)
        #expect(history[safe: 0]?.role == .user)
        #expect(history[safe: 0]?.content == "hello")
        #expect(history[safe: 1]?.role == .assistant)
        #expect(history[safe: 1]?.content == "partial answer")
        #expect(await runner.snapshotSession(id: sessionID)?.history == history)
        #expect(await backend.lastCreatedHistory() == history)
    }

    @Test
    func cancelPromptBySessionIDPublishesCancelledOutcome() async throws {
        let backend = BlockingAgentRuntimeBackend()
        let runner = AgentCoreSessionRunner(
            backendFactory: { _, _ in backend }
        )
        let sessionID = "session-\(UUID().uuidString)"
        let configuration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            allowedToolNames: []
        )
        let snapshotCollector = SnapshotCollector()

        let stream = await runner.streamPrompt(
            "please stop",
            configuration: configuration
        )
        let consumer = Task {
            do {
                for try await event in stream {
                    await snapshotCollector.record(event)
                }
            } catch is CancellationError {
            } catch {
            }
        }

        await backend.waitUntilPromptStarted()
        await runner.cancelPrompt(sessionID: sessionID)
        await consumer.value

        let snapshots = await snapshotCollector.snapshots()
        let outcomes = await snapshotCollector.outcomes()
        #expect(snapshots.count == 1)
        #expect(outcomes == [.cancelled])
        let history = try #require(snapshots.first?.history)
        #expect(history.count == 1)
        #expect(history[safe: 0]?.role == .user)
        #expect(history[safe: 0]?.content == "please stop")
        #expect(await runner.snapshotSession(id: sessionID)?.history == history)
    }
}

private actor CapturingAgentRuntimeBackend: AgentRuntimeBackend {
    private var updatedSystemPrompt: String?
    private var updatedAllowedToolNames: Set<String>?
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]
    private var createdHistories: [[AgentRuntimeMessage]] = []
    private let promptEvents: [DirectAgentEvent]
    private let sendPromptError: Error?

    init(
        promptEvents: [DirectAgentEvent] = [],
        sendPromptError: Error? = nil
    ) {
        self.promptEvents = promptEvents
        self.sendPromptError = sendPromptError
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
        sessions[id] = AgentRuntimeSessionSnapshot(
            sessionID: id,
            workingDirectoryPath: cwd,
            systemPrompt: systemPrompt,
            cacheKey: cacheKey,
            history: history,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
        createdHistories.append(history)
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
        id _: String,
        systemPrompt: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {
        updatedSystemPrompt = systemPrompt
        updatedAllowedToolNames = allowedToolNames
    }

    func updateBorrowedOrchestrationToolExecutor(
        _: AgentBorrowedToolExecutor?
    ) async {}

    func updateToolProviders(_: [AgentToolProvider]) async {}

    func closeSession(id _: String) {}

    func shutdown() async {
        sessions.removeAll()
    }

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        []
    }

    func sendPrompt(
        sessionID _: String,
        prompt _: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        for event in promptEvents {
            await onEvent(event)
        }
        if let sendPromptError {
            throw sendPromptError
        }
        return DirectAgentResponse(text: "", stopReason: "end_turn", modelID: "test-model")
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        sessions[id]
    }

    func lastUpdatedSystemPrompt() -> String? {
        updatedSystemPrompt
    }

    func lastUpdatedAllowedToolNames() -> Set<String>? {
        updatedAllowedToolNames
    }

    func lastCreatedHistory() -> [AgentRuntimeMessage]? {
        createdHistories.last
    }
}

private actor BlockingAgentRuntimeBackend: AgentRuntimeBackend {
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]
    private var didStartPrompt = false
    private var startContinuations: [CheckedContinuation<Void, Never>] = []

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
        sessions[id] = AgentRuntimeSessionSnapshot(
            sessionID: id,
            workingDirectoryPath: cwd,
            systemPrompt: systemPrompt,
            cacheKey: cacheKey,
            history: history,
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
        id _: String,
        systemPrompt _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func closeSession(id _: String) {}

    func shutdown() async {
        sessions.removeAll()
    }

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func sendPrompt(
        sessionID _: String,
        prompt _: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        didStartPrompt = true
        for continuation in startContinuations {
            continuation.resume()
        }
        startContinuations.removeAll()

        try await Task.sleep(for: .seconds(30))
        return DirectAgentResponse(text: "", stopReason: "end_turn", modelID: "test-model")
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        sessions[id]
    }

    func waitUntilPromptStarted() async {
        guard !didStartPrompt else {
            return
        }

        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }
}

private struct SyntheticPromptError: Error, LocalizedError {
    var errorDescription: String? {
        "Synthetic prompt failed."
    }
}

private actor SnapshotCollector {
    private var values: [AgentRuntimeSessionSnapshot] = []
    private var outcomeValues: [DirectAgentTurnOutcome] = []

    func record(_ event: DirectAgentEvent) {
        if case let .sessionSnapshot(snapshot) = event {
            values.append(snapshot)
        }
        if case let .turnEnded(outcome) = event {
            outcomeValues.append(outcome)
        }
    }

    func snapshots() -> [AgentRuntimeSessionSnapshot] {
        values
    }

    func outcomes() -> [DirectAgentTurnOutcome] {
        outcomeValues
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
