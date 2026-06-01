//
//  AgentTelegramControlRuntime.swift
//  MLXCoder
//
//  Telegram remote control for standalone mlx-coder.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AgentTelegramPromptParser {
    public static func promptCommand(from text: String) -> (agentToken: String?, prompt: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.hasPrefix("@") {
            return prefixedPrompt(trimmed, prefixLength: 1)
        }

        guard trimmed.hasPrefix("/") else {
            return (nil, trimmed)
        }

        let withoutSlash = trimmed.dropFirst()
        let rawToken = withoutSlash.prefix { !$0.isWhitespace && !$0.isNewline }
        guard !rawToken.isEmpty else {
            return nil
        }

        let token = rawToken
            .split(separator: "@", maxSplits: 1)
            .first
            .map(String.init) ?? String(rawToken)
        let suffix = withoutSlash.dropFirst(rawToken.count)
        let prompt = suffix.trimmingCharacters(in: .whitespacesAndNewlines)

        if isReservedCommand(token) {
            return (nil, trimmed)
        }

        return (token, prompt.isEmpty ? "status" : prompt)
    }

    private static func prefixedPrompt(
        _ trimmed: String,
        prefixLength: Int
    ) -> (agentToken: String?, prompt: String)? {
        let withoutPrefix = trimmed.dropFirst(prefixLength)
        let token = withoutPrefix.prefix { !$0.isWhitespace && !$0.isNewline }
        guard !token.isEmpty else {
            return nil
        }

        let suffix = withoutPrefix.dropFirst(token.count)
        let prompt = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            return nil
        }

        return (String(token), prompt)
    }

    private static func isReservedCommand(_ token: String) -> Bool {
        switch token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "start", "help", "status", "changes", "retry", "undo", "stop", "close", "save", "continue":
            return true
        default:
            return false
        }
    }
}

public actor AgentTelegramControlRuntime {
    private let configuration: AgentConfiguration
    private let client: AgentTelegramClient
    private let sessionRunner: AgentCoreSessionRunner
    private let agents: [AgentProfile]
    private let defaultAgent: AgentProfile
    private var lastUpdateID: Int?
    private var agentSessions: [String: AgentTelegramSessionState] = [:]
    private var activePromptTasks: [String: Task<Void, Never>] = [:]

    public init(
        configuration: AgentConfiguration,
        sessionRunner: AgentCoreSessionRunner = AgentCoreSessionRunner()
    ) throws {
        let manifest = try AgentSettingsManifestStore.loadRequired()
        guard let token = manifest.telegramBotToken else {
            throw AgentTelegramControlError.missingToken
        }

        let agents = try AgentProfileStore.loadRequired()
        let defaultAgent: AgentProfile
        if let selectedAgent = configuration.selectedAgent {
            defaultAgent = selectedAgent
        } else {
            defaultAgent = try AgentProfileStore.defaultProfile(in: agents)
        }
        self.configuration = configuration
        self.client = AgentTelegramClient(token: token)
        self.sessionRunner = sessionRunner
        self.agents = agents
        self.defaultAgent = defaultAgent
    }

    public func run() async throws {
        _ = try? await client.deleteWebhook(dropPendingUpdates: true)
        let bot = try await client.getMe()
        let botName = bot.username.map { "@\($0)" } ?? bot.firstName ?? "Telegram bot"
        AgentOutput.standardError.writeString(
            """
            Telegram control active as \(botName).
            Send messages to the bot. Plain text uses \(defaultAgent.displayName); use @AgentName or /AgentName to target another agent.
            Press Ctrl+C to stop.

            """
        )

        while !Task.isCancelled {
            do {
                let updates = try await client.getUpdates(
                    offset: lastUpdateID.map { $0 + 1 },
                    timeout: 30
                )
                for update in updates {
                    lastUpdateID = update.updateID
                    await handle(update)
                }
            } catch is CancellationError {
                return
            } catch {
                AgentOutput.standardError.writeString(
                    "mlx-coder telegram: \(error.localizedDescription)\n"
                )
                try await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func handle(_ update: AgentTelegramUpdate) async {
        guard let message = update.message,
              let text = message.text,
              let user = message.from,
              user.isBot != true,
              let parsed = AgentTelegramPromptParser.promptCommand(from: text) else {
            return
        }

        guard let agent = agent(matching: parsed.agentToken) else {
            await sendMessage(
                "Unknown mlx-coder agent. Use one of: \(agentCommandList).",
                to: message.chat.id
            )
            return
        }

        if let command = AgentTelegramRemoteCommand(text: parsed.prompt) {
            await handle(command, agent: agent, chatID: message.chat.id)
            return
        }

        if activePromptTasks[agent.id] != nil {
            await sendMessage(
                remoteStatusMessage(
                    for: state(for: agent),
                    agent: agent,
                    prefix: "\(agent.displayName) is still working. New prompts are not queued yet."
                ),
                to: message.chat.id
            )
            return
        }

        startPrompt(parsed.prompt, agent: agent, chatID: message.chat.id)
    }

    private func handle(
        _ command: AgentTelegramRemoteCommand,
        agent: AgentProfile,
        chatID: Int64
    ) async {
        let state = state(for: agent)
        switch command {
        case .status:
            await sendMessage(remoteStatusMessage(for: state, agent: agent), to: chatID)
        case .changes:
            await sendMessage(remoteChangesMessage(for: state), to: chatID)
        case .retry:
            guard activePromptTasks[agent.id] == nil,
                  let prompt = state.lastFailedPrompt else {
                await sendMessage("Retry is not available for \(agent.displayName).", to: chatID)
                return
            }
            startPrompt(prompt, agent: agent, chatID: chatID, clearsFailedPrompt: false)
            await sendMessage("\(agent.displayName) retry started.", to: chatID)
        case .undoChanges:
            guard activePromptTasks[agent.id] == nil else {
                await sendMessage(
                    "Cannot undo while \(agent.displayName) is still working.",
                    to: chatID
                )
                return
            }
            await undoFileChanges(for: agent, chatID: chatID)
        }
    }

    private func startPrompt(
        _ prompt: String,
        agent: AgentProfile,
        chatID: Int64,
        clearsFailedPrompt: Bool = true
    ) {
        var state = state(for: agent)
        state.chatID = chatID
        state.isBusy = true
        state.status = "Running"
        if clearsFailedPrompt {
            state.lastFailedPrompt = nil
        }
        agentSessions[agent.id] = state

        let task = Task { [weak self] in
            guard let self else {
                return
            }
            await self.runPrompt(prompt, agent: agent, chatID: chatID)
        }
        activePromptTasks[agent.id] = task
    }

    private func runPrompt(
        _ prompt: String,
        agent: AgentProfile,
        chatID: Int64
    ) async {
        let fileChanges = TurnFileChangeCoordinator(baseDirectoryURL: configuration.workingDirectory)
        do {
            let sessionConfiguration = try makeSessionConfiguration(for: agent)
            let response = try await sessionRunner.sendPrompt(
                configuration: sessionConfiguration,
                prompt: prompt,
                attachments: [],
                onToolWillExecute: { toolCall in
                    await fileChanges.captureBaselineIfNeeded(forAgentToolCall: toolCall)
                },
                onEvent: { event in
                    await self.handleAgentEvent(event, agentID: agent.id)
                }
            )
            await finishPrompt(
                result: .success(response),
                agent: agent,
                chatID: chatID,
                fileChanges: fileChanges
            )
        } catch {
            await finishPrompt(
                result: .failure(error),
                agent: agent,
                chatID: chatID,
                fileChanges: fileChanges,
                failedPrompt: prompt
            )
        }
    }

    private func makeSessionConfiguration(for agent: AgentProfile) throws -> AgentCoreSessionConfiguration {
        let state = state(for: agent)
        let allowedToolNames = AgentCoreAppSessionFactory.resolvedAllowedToolNames(
            selectedToolKeys: nil,
            explicitAllowedToolNames: nil,
            selectedAgent: agent
        )
        let systemPrompt = AgentCoreAppSessionFactory.resolvedSystemPrompt(
            providedSystemPrompt: nil,
            cwd: configuration.workingDirectory.path,
            selectedAgent: agent,
            allowedToolNames: allowedToolNames
        )
        let model = modelManifest(matching: configuration.effectiveModelID)

        return AgentCoreSessionConfiguration(
            sessionID: state.sessionID,
            modelID: configuration.effectiveModelID,
            bearerToken: configuration.bearerToken,
            workingDirectory: configuration.workingDirectory,
            systemPrompt: systemPrompt,
            cacheKey: state.cacheKey,
            history: state.history,
            allowedToolNames: allowedToolNames,
            configuredContextWindowLimit: model?.configuredContextWindowLimit,
            generationParameterOverrides: model?.generationParameterOverrides
                ?? AgentGenerationParameterOverrides(),
            maxToolRounds: configuration.maxToolRounds,
            maxOutputTokens: configuration.maxOutputTokens,
            verboseLogging: configuration.verboseLogging,
            appMode: true,
            thinkingSelection: model?.thinkingSelection(for: nil),
            preserveThinking: false
        )
    }

    private func modelManifest(matching modelID: String?) -> AgentSettingsModelManifest? {
        guard let modelID = modelID?.nilIfBlank else {
            return nil
        }
        if let hostedModel = configuration.hostedModels?.first(where: { $0.matches(modelID) }) {
            return hostedModel
        }
        return AgentSettingsStore.availableModels().first { $0.matches(modelID) }
    }

    private func handleAgentEvent(_ event: DirectAgentEvent, agentID: String) {
        var state = agentSessions[agentID]
        switch event {
        case let .status(message):
            state?.status = message
        case let .metrics(metrics):
            state?.metrics = metrics
        case let .contextWindow(context):
            state?.contextWindow = context
        case let .sessionSnapshot(snapshot):
            state?.history = snapshot.history
            state?.cacheKey = snapshot.cacheKey
        case let .turnEnded(outcome):
            state?.lastOutcome = outcome
        case .diagnostic,
             .thought,
             .modelLoaded,
             .modelLoadedDetails,
             .content,
             .toolCallStarted,
             .toolCallCompleted:
            break
        }
        if let state {
            agentSessions[agentID] = state
        }
    }

    private func finishPrompt(
        result: Result<DirectAgentResponse, Error>,
        agent: AgentProfile,
        chatID: Int64,
        fileChanges: TurnFileChangeCoordinator,
        failedPrompt: String? = nil
    ) async {
        let summary = await fileChanges.publishSummaryIfNeeded()
        var state = state(for: agent)
        state.isBusy = false
        state.status = nil
        state.lastFileChangeSummary = summary ?? state.lastFileChangeSummary
        activePromptTasks.removeValue(forKey: agent.id)

        switch result {
        case let .success(response):
            state.lastFailedPrompt = nil
            agentSessions[agent.id] = state
            await sendMessage(
                remoteCompletionMessage(response.text, state: state, agent: agent),
                to: chatID
            )
        case let .failure(error):
            state.lastFailedPrompt = failedPrompt
            state.lastOutcome = .failed(message: error.localizedDescription)
            agentSessions[agent.id] = state
            await sendMessage(
                remoteFailureMessage(error, state: state, agent: agent),
                to: chatID
            )
        }
    }

    private func undoFileChanges(for agent: AgentProfile, chatID: Int64) async {
        var state = state(for: agent)
        do {
            let summary = try await TurnFileChangeUndoService.undoLatest(
                summary: state.lastFileChangeSummary,
                baseDirectoryURL: configuration.workingDirectory
            )
            state.lastFileChangeSummary = nil
            agentSessions[agent.id] = state
            await sendMessage(
                "File changes reverted.\n\n\(remoteFileChangeSummary(summary, includeUndoHint: false))",
                to: chatID
            )
        } catch let error as TurnFileChangeUndoError {
            await sendMessage(error.localizedDescription, to: chatID)
        } catch {
            await sendMessage(
                "Unable to undo file changes: \(error.localizedDescription)",
                to: chatID
            )
        }
    }

    private func sendMessage(_ text: String, to chatID: Int64) async {
        do {
            try await client.sendMessage(text, to: chatID)
        } catch {
            AgentOutput.standardError.writeString(
                "mlx-coder telegram: unable to send message: \(error.localizedDescription)\n"
            )
        }
    }

    private func state(for agent: AgentProfile) -> AgentTelegramSessionState {
        if let state = agentSessions[agent.id] {
            return state
        }
        let state = AgentTelegramSessionState(
            agentID: agent.id,
            sessionID: "telegram:\(normalizedAgentLookupKey(agent.id))",
            chatID: nil,
            history: [],
            cacheKey: nil,
            isBusy: false,
            status: nil,
            lastFailedPrompt: nil,
            lastFileChangeSummary: nil,
            metrics: nil,
            contextWindow: nil,
            lastOutcome: nil
        )
        agentSessions[agent.id] = state
        return state
    }

    private func agent(matching token: String?) -> AgentProfile? {
        guard let token = token?.nilIfBlank else {
            return defaultAgent
        }
        let normalizedToken = normalizedAgentLookupKey(token)
        return agents.first { agent in
            normalizedAgentLookupKey(agent.id) == normalizedToken
                || normalizedAgentLookupKey(agent.displayName) == normalizedToken
        }
    }

    private var agentCommandList: String {
        let names = agents.map { "@\($0.displayName)" }.sorted()
        return names.isEmpty ? "@Default" : names.joined(separator: ", ")
    }

    private func remoteCompletionMessage(
        _ reply: String,
        state: AgentTelegramSessionState,
        agent: AgentProfile
    ) -> String {
        var sections = [
            "\(agent.displayName) completed"
        ]

        let trimmedReply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedReply.isEmpty {
            sections.append(truncatedRemoteText(trimmedReply, limit: 2_800))
        }

        sections.append(remoteChangesMessage(for: state))
        if let metricsLine = remoteMetricsLine(for: state) {
            sections.append(metricsLine)
        }
        return sections.joined(separator: "\n\n")
    }

    private func remoteFailureMessage(
        _ error: Error,
        state: AgentTelegramSessionState,
        agent: AgentProfile
    ) -> String {
        var sections = [
            "\(agent.displayName) failed",
            truncatedRemoteText(error.localizedDescription, limit: 1_400),
            remoteChangesMessage(for: state),
            "Retry: send \"retry\"."
        ]
        if let metricsLine = remoteMetricsLine(for: state) {
            sections.append(metricsLine)
        }
        return sections.joined(separator: "\n\n")
    }

    private func remoteStatusMessage(
        for state: AgentTelegramSessionState,
        agent: AgentProfile,
        prefix: String? = nil
    ) -> String {
        let stateText: String
        if state.isBusy {
            stateText = "Running"
        } else if state.lastFailedPrompt != nil {
            stateText = "Needs retry"
        } else {
            stateText = "Idle"
        }

        var lines = [
            prefix,
            "Agent: \(agent.displayName)",
            "Status: \(stateText)"
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank }

        if let detail = state.status?.nilIfBlank {
            lines.append("Detail: \(detail)")
        }

        if let context = state.contextWindow,
           let usedTokens = context.usedTokens,
           let maxTokens = context.maxTokens {
            lines.append(
                "Context: \(formatRemoteTokenCount(usedTokens)) / \(formatRemoteTokenCount(maxTokens))"
            )
        }

        if state.lastFailedPrompt != nil {
            lines.append("Retry: send \"retry\".")
        }

        lines.append(remoteChangesMessage(for: state))
        return lines.joined(separator: "\n")
    }

    private func remoteChangesMessage(for state: AgentTelegramSessionState) -> String {
        guard let summary = state.lastFileChangeSummary else {
            return "Files: none"
        }
        return remoteFileChangeSummary(summary, includeUndoHint: true)
    }

    private func remoteFileChangeSummary(
        _ summary: TurnFileChangeSummary,
        includeUndoHint: Bool
    ) -> String {
        var lines = [
            "Files: \(summary.fileCount) changed (+\(summary.totalAdditions) -\(summary.totalDeletions))"
        ]
        let visibleEntries = summary.entries.prefix(8)
        lines.append(contentsOf: visibleEntries.map { entry in
            let binaryText = entry.isBinary ? " binary" : ""
            return "- \(entry.status.rawValue) \(entry.path) (+\(entry.additions) -\(entry.deletions))\(binaryText)"
        })
        if summary.entries.count > visibleEntries.count {
            lines.append("- ... \(summary.entries.count - visibleEntries.count) more")
        }
        if includeUndoHint {
            lines.append(
                summary.canUndo
                    ? "Undo: send \"undo changes\"."
                    : "Undo: not available."
            )
        }
        return lines.joined(separator: "\n")
    }

    private func remoteMetricsLine(for state: AgentTelegramSessionState) -> String? {
        guard let metrics = state.metrics else {
            return nil
        }

        var parts: [String] = []
        if let prompt = metrics.promptTokenCount {
            parts.append("prompt \(formatRemoteTokenCount(prompt))")
        }
        if let completion = metrics.completionTokenCount {
            parts.append("output \(formatRemoteTokenCount(completion))")
        }
        if let seconds = metrics.responseDurationSeconds {
            parts.append(String(format: "time %.1fs", seconds))
        }
        guard !parts.isEmpty else {
            return nil
        }
        return "Metrics: \(parts.joined(separator: " | "))"
    }

    private func truncatedRemoteText(_ text: String, limit: Int) -> String {
        guard text.count > limit else {
            return text
        }
        return String(text.prefix(limit))
            + "\n...truncated on mobile, open mlx-coder on the Mac for the full response."
    }

    private func formatRemoteTokenCount(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return "\(value)"
    }

    private func normalizedAgentLookupKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
            .map(String.init)
            .joined()
    }
}

private struct AgentTelegramSessionState {
    let agentID: String
    let sessionID: String
    var chatID: Int64?
    var history: [AgentRuntimeMessage]
    var cacheKey: String?
    var isBusy: Bool
    var status: String?
    var lastFailedPrompt: String?
    var lastFileChangeSummary: TurnFileChangeSummary?
    var metrics: DirectAgentGenerationMetrics?
    var contextWindow: DirectAgentContextWindowStatus?
    var lastOutcome: DirectAgentTurnOutcome?
}

private enum AgentTelegramRemoteCommand {
    case status
    case changes
    case retry
    case undoChanges

    init?(text: String) {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "status", "/status", "stato":
            self = .status
        case "changes", "/changes", "modifiche":
            self = .changes
        case "retry", "/retry", "riprova":
            self = .retry
        case "undo", "/undo", "undo changes", "annulla", "annulla modifiche":
            self = .undoChanges
        default:
            return nil
        }
    }
}

private struct AgentTelegramClient {
    private let token: String
    private let session: URLSession

    init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    func getMe() async throws -> AgentTelegramUser {
        try await telegramRequest(method: "getMe", body: AgentTelegramEmptyRequest())
    }

    func deleteWebhook(dropPendingUpdates: Bool) async throws -> Bool {
        try await telegramRequest(
            method: "deleteWebhook",
            body: AgentTelegramDeleteWebhookRequest(dropPendingUpdates: dropPendingUpdates)
        )
    }

    func getUpdates(offset: Int?, timeout: Int) async throws -> [AgentTelegramUpdate] {
        let request = AgentTelegramGetUpdatesRequest(
            offset: offset,
            timeout: timeout,
            allowedUpdates: ["message"]
        )
        return try await telegramRequest(method: "getUpdates", body: request)
    }

    func sendMessage(_ text: String, to chatID: Int64) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentTelegramControlError.emptyMessage
        }
        let request = AgentTelegramSendMessageRequest(
            chatID: chatID,
            text: String(trimmed.prefix(4_000))
        )
        let _: AgentTelegramMessage = try await telegramRequest(method: "sendMessage", body: request)
    }

    private func telegramRequest<Request: Encodable, Response: Decodable>(
        method: String,
        body: Request
    ) async throws -> Response {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else {
            throw AgentTelegramControlError.invalidToken
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgentTelegramControlError.unexpectedResponse
        }

        let decoded = try JSONDecoder().decode(AgentTelegramAPIResponse<Response>.self, from: data)
        guard (200..<300).contains(httpResponse.statusCode),
              decoded.ok,
              let result = decoded.result else {
            throw AgentTelegramControlError.httpError(
                httpResponse.statusCode,
                decoded.description ?? String(data: data, encoding: .utf8)
            )
        }
        return result
    }
}

public enum AgentTelegramControlError: LocalizedError {
    case missingToken
    case invalidToken
    case emptyMessage
    case unexpectedResponse
    case httpError(Int, String?)

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            return "Telegram bot token is not configured. Run mlx-coder --setup and enable Telegram remote control."
        case .invalidToken:
            return "Telegram bot token is invalid."
        case .emptyMessage:
            return "Cannot send an empty Telegram message."
        case .unexpectedResponse:
            return "Telegram returned an unexpected response."
        case let .httpError(statusCode, body):
            let detail = body?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let detail, !detail.isEmpty {
                return "Telegram returned HTTP \(statusCode): \(detail)"
            }
            return "Telegram returned HTTP \(statusCode)."
        }
    }
}

private struct AgentTelegramAPIResponse<Result: Decodable>: Decodable {
    let ok: Bool
    let result: Result?
    let description: String?
}

private struct AgentTelegramEmptyRequest: Encodable {}

private struct AgentTelegramDeleteWebhookRequest: Encodable {
    let dropPendingUpdates: Bool

    enum CodingKeys: String, CodingKey {
        case dropPendingUpdates = "drop_pending_updates"
    }
}

private struct AgentTelegramGetUpdatesRequest: Encodable {
    let offset: Int?
    let timeout: Int
    let allowedUpdates: [String]

    enum CodingKeys: String, CodingKey {
        case offset
        case timeout
        case allowedUpdates = "allowed_updates"
    }
}

private struct AgentTelegramSendMessageRequest: Encodable {
    let chatID: Int64
    let text: String

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case text
    }
}

private struct AgentTelegramUpdate: Decodable {
    let updateID: Int
    let message: AgentTelegramMessage?

    enum CodingKeys: String, CodingKey {
        case updateID = "update_id"
        case message
    }
}

private struct AgentTelegramMessage: Decodable {
    let messageID: Int
    let from: AgentTelegramUser?
    let chat: AgentTelegramChat
    let text: String?

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case from
        case chat
        case text
    }
}

private struct AgentTelegramUser: Decodable {
    let id: Int64
    let isBot: Bool?
    let username: String?
    let firstName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case isBot = "is_bot"
        case username
        case firstName = "first_name"
    }
}

private struct AgentTelegramChat: Decodable {
    let id: Int64
}
