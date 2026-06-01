//
//  Generated split from MLXCoder.swift
//  mlx-coder
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

public final class TerminalChat: @unchecked Sendable {
    public let configuration: AgentConfiguration
    public let stdinIsTerminal: Bool
    public let sessionRunner: AgentCoreSessionRunner
    public let reader = StdioLineReader()
    public let interactiveReader = TerminalInteractiveLineReader()
    public let permissionAuthorizer: LocalExecPermissionAuthorizer
    public var sessionID = TerminalChat.newTerminalSessionID()
    public var diskCacheKey: String {
        AgentKVCachePersistencePolicy.terminalDiskCacheKey(
            workingDirectoryPath: configuration.workingDirectory.path
        )
    }
    public var activeSessionCacheKey: String?
    public var activeSessionHistory: [AgentRuntimeMessage] = []
    public var activeSessionTranscript: [AgentRuntimeMessage] = []
    public var activeSessionSystemPromptOverride: String?
    public var activeSavedSessionName: String?
    public var printedModelID: String?
    public var didPrintActiveTools = false
    public var didReceiveMetricsForCurrentPrompt = false
    public var selectedAgent: AgentProfile?
    public var manualModelIDOverride: String?
    public var manualThinkingSelectionOverride: AgentThinkingSelection?
    public var selectedToolKeys = Set<String>()
    public var selectedSkillIDs = Set<String>()
    public var pendingAttachments: [AgentRuntimeAttachment] = []
    private var lastFailedPrompt: TerminalRetryPrompt?
    public var lastFileChangeSummary: TurnFileChangeSummary?
    public var isSubAgentOverviewVisible = false
    public var lastRenderedSubAgentOverviewSignature: String?
    public var subAgentOverviewRefreshTask: Task<Void, Never>?
    public var availableSkillsCache: [MLXPromptSkill]?
    public var isDetailedToolOutputEnabled = false
    public var activeCompactToolCallID: String?
    public var activeCompactToolRenderedRowCount = 0
    public var isStreamingThoughtOutput = false
    var thoughtOutputEndsWithNewline = false
    var shouldTrimLeadingAssistantContentLineBreaks = false
    var assistantContentNeedsLineBreakBeforeTool = false
    var isAtStartOfChatLine = true
    public var assistantMarkdownFormatter = TerminalMarkdownStreamFormatter(
        isEnabled: AgentOutput.standardOutputIsTerminal
    )
    public var thoughtMarkdownFormatter = TerminalMarkdownStreamFormatter(
        isEnabled: AgentOutput.standardErrorIsTerminal
    )
    public let statusBar: TerminalStatusBar

    public init(
        configuration: AgentConfiguration,
        stdinIsTerminal: Bool,
        sessionRunner: AgentCoreSessionRunner? = nil
    ) {
        self.configuration = configuration
        self.stdinIsTerminal = stdinIsTerminal
        self.statusBar = TerminalStatusBar(
            isEnabled: stdinIsTerminal
                && Self.supportsInteractiveStatusBar()
        )
        let permissionAuthorizer = LocalExecPermissionAuthorizer()
        self.permissionAuthorizer = permissionAuthorizer
        self.sessionRunner = sessionRunner ?? AgentCoreSessionRunner(
            defaultToolAuthorizationHandler: { request in
                await permissionAuthorizer.authorize(request)
            }
        )
        self.selectedAgent = configuration.selectedAgent
        self.manualModelIDOverride = configuration.modelID
    }

    public static func supportsInteractiveStatusBar() -> Bool {
        AgentOutput.standardErrorIsTerminal
    }

    public static func newTerminalSessionID() -> String {
        "terminal-\(UUID().uuidString.lowercased())"
    }

    public func currentEffectiveModelID() -> String? {
        if let hostedModelManifest = hostedModelSelectionManifest() {
            return AgentSettingsStore.resolvedEffectiveModelID(
                explicitModelID: manualModelIDOverride,
                agentModelID: selectedAgent?.modelID,
                manifest: hostedModelManifest
            ) ?? configuration.effectiveModelID
        }

        return Self.effectiveModelID(
            selectedAgent: selectedAgent,
            manualModelIDOverride: manualModelIDOverride
        ) ?? configuration.effectiveModelID
    }

    public static func effectiveModelID(
        selectedAgent: AgentProfile?,
        manualModelIDOverride: String?,
        manifest: AgentSettingsManifest? = AgentSettingsManifestStore.load()
    ) -> String? {
        AgentSettingsStore.resolvedEffectiveModelID(
            explicitModelID: manualModelIDOverride,
            agentModelID: selectedAgent?.modelID,
            manifest: manifest
        )
    }

    private func hostedModelSelectionManifest() -> AgentSettingsManifest? {
        guard let hostedModels = configuration.hostedModels else {
            return nil
        }
        return AgentSettingsManifest(
            models: hostedModels,
            selectedModelID: configuration.effectiveModelID
        )
    }

    public func run() async throws {
        let initialInputLine: String?
        if stdinIsTerminal {
            initialInputLine = nil
        } else {
            guard let line = reader.readLine() else {
                throw TerminalChatError.noInputReceived
            }
            initialInputLine = line
        }

        await applyInitialAgentSelectionIfNeeded()
        try handleMissingInitialModelSelectionIfNeeded()
        try applyInitialSkillSelectionIfNeeded()
        await ensureWorkspaceAccessIfNeeded()

        try await createCurrentSession()
        refreshInitialStatusBarContextWindow()

        await printStartupSummary()
        _ = try await preloadCurrentModel(emitStatus: configuration.hostedModels != nil)
        let statusBarStarted = statusBar.start()
        defer {
            stopSubAgentOverviewRefreshLoop()
            statusBar.stop()
        }

        if stdinIsTerminal, statusBarStarted {
            try await runInteractivePanelLoop()
        } else {
            try await runBlockingInputLoop(initialInputLine: initialInputLine)
        }

        await sessionRunner.closeSession(id: sessionID)
    }

    private func runBlockingInputLoop(initialInputLine: String?) async throws {
        var pendingInputLine = initialInputLine
        while true {
            let promptInput: String
            if stdinIsTerminal {
                guard let line = interactiveReader.readLine(prompt: "> ") else {
                    break
                }
                promptInput = line
            } else {
                guard let line = pendingInputLine ?? reader.readLine() else {
                    break
                }
                pendingInputLine = nil
                let pastedLines = reader.drainBufferedLines(waitMilliseconds: 80)
                promptInput = ([line] + pastedLines).joined(separator: "\n")
            }

            switch await submittedLineAction(promptInput) {
            case .continueChat:
                continue
            case .exitChat:
                return
            case let .runPrompt(prompt):
                await runPromptBlocking(promptAttempt(prompt: prompt))
            case let .retryPrompt(retryPrompt):
                await runPromptBlocking(promptAttempt(retryPrompt: retryPrompt))
            case let .prefillPrompt(prompt):
                writeSystemMessage("Draft prompt:\n\(prompt)\n")
            }
        }
    }

    private func runInteractivePanelLoop() async throws {
        let eventQueue = TerminalChatEventQueue()
        var queuedPrompts: [String] = []
        var generationTask: Task<Void, Never>?
        var isGenerating = false

        @discardableResult
        func startPanelInput() -> Bool {
            let didStart = interactiveReader.startPanelInput(
                statusBar: statusBar,
                commandSuggestions: commandSuggestionsForCurrentAgent()
            ) { event in
                Task {
                    await eventQueue.send(.input(event))
                }
            }
            guard didStart else {
                return false
            }
            interactiveReader.setPanelProcessing(isGenerating)
            interactiveReader.setQueuedPromptCount(queuedPrompts.count)
            return true
        }

        func stopPanelInput(clearPanel: Bool = true) async {
            await interactiveReader.stopPanelInput(clearPanel: clearPanel)
        }

        func startGeneration(attempt: TerminalPromptAttempt) {
            isGenerating = true
            didReceiveMetricsForCurrentPrompt = false
            statusBar.setProcessing(true)
            interactiveReader.setPanelProcessing(true)
            generationTask = Task {
                let result: TerminalChatGenerationResult
                do {
                    result = .success(try await self.generateResponse(attempt: attempt))
                } catch is CancellationError {
                    result = .failure(
                        TerminalChatGenerationFailure(
                            message: "",
                            isCancellation: true,
                            retryPrompt: nil
                        )
                    )
                } catch {
                    result = .failure(
                        TerminalChatGenerationFailure(
                            message: error.localizedDescription,
                            isCancellation: false,
                            retryPrompt: attempt.retryPrompt
                        )
                    )
                }
                await eventQueue.send(.generationCompleted(result))
            }
        }

        guard startPanelInput() else {
            statusBar.stop()
            throw TerminalChatError.interactivePromptUnavailable
        }
        defer {
            generationTask?.cancel()
        }

        func handleSubmittedPanelLine(_ line: String) async -> Bool {
            let shouldSuspendPanel = Self.shouldSuspendPanelInput(for: line)
            if shouldSuspendPanel {
                await stopPanelInput(clearPanel: false)
            }

            switch await submittedLineAction(line) {
            case .continueChat:
                if shouldSuspendPanel {
                    _ = startPanelInput()
                }
                return true
            case .exitChat:
                generationTask?.cancel()
                return false
            case let .runPrompt(prompt):
                if shouldSuspendPanel {
                    _ = startPanelInput()
                }
                let attempt = promptAttempt(prompt: prompt)
                writeSubmittedPrompt(prompt)
                startGeneration(attempt: attempt)
                return true
            case let .retryPrompt(retryPrompt):
                if shouldSuspendPanel {
                    _ = startPanelInput()
                }
                let attempt = promptAttempt(retryPrompt: retryPrompt)
                writeSubmittedPrompt(retryPrompt.prompt)
                startGeneration(attempt: attempt)
                return true
            case let .prefillPrompt(prompt):
                if shouldSuspendPanel {
                    _ = startPanelInput()
                }
                interactiveReader.setPanelText(prompt)
                return true
            }
        }

        eventLoop: while true {
            if !isGenerating, !queuedPrompts.isEmpty {
                let nextPrompt = queuedPrompts.removeFirst()
                interactiveReader.setQueuedPromptCount(queuedPrompts.count)
                guard await handleSubmittedPanelLine(nextPrompt) else {
                    break eventLoop
                }
                continue
            }

            let event = await eventQueue.next()
            switch event {
            case let .input(inputEvent):
                switch inputEvent {
                case let .submitted(line):
                    if isGenerating {
                        queuedPrompts.append(line)
                        interactiveReader.setQueuedPromptCount(queuedPrompts.count)
                        continue
                    }

                    guard await handleSubmittedPanelLine(line) else {
                        break eventLoop
                    }
                case .cancelRequested:
                    generationTask?.cancel()
                case .toggleToolDetailsRequested:
                    self.toggleToolDetailsOutput()
                    interactiveReader.refreshPanel()
                case .endOfInput:
                    generationTask?.cancel()
                    break eventLoop
                }
            case let .generationCompleted(result):
                generationTask = nil
                isGenerating = false
                statusBar.setProcessing(false)
                interactiveReader.setPanelProcessing(false)
                await finishPromptResult(result)
            }
        }

        await stopPanelInput()
    }

    private static func shouldSuspendPanelInput(for line: String) -> Bool {
        let prompt = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.hasPrefix("/")
    }

    private func renderHelpTextForCurrentAgent() -> String {
        var lines = [
            "Type a prompt and press return.",
            "/models shows configured models and lets you switch the default agent model.",
            "/agents selects an agent profile and resets the session.",
            "/tools selects which tool groups are available to the model."
        ]
        if AgentProfileStore.isBuilderAgent(selectedAgent) {
            lines.append("/feature creates and manages generated Swift feature packages.")
        }
        lines.append(contentsOf: [
            "/skills selects installed prompt skills or installs one from GitHub or a local folder.",
            "/sessions saves, restores, or deletes named session snapshots for this project.",
            "/attach <file> [file ...] attaches image or video files to the next prompt.",
            "/attachments shows pending attachments.",
            "/detach [all|number] removes pending attachments.",
            "/retry reruns the most recent failed prompt.",
            "/changes shows the most recent file change summary. Use /changes diff to include patches.",
            "/undo reverts the most recent tracked file changes.",
            "/subagents shows delegated sub-agent status. Use /subagents off to hide automatic updates.",
            "Ctrl+T toggles compact/full tool output.",
            "/clear resets the conversation.",
            "/exit closes the session."
        ])
        return lines.joined(separator: "\n") + "\n\n"
    }

    func commandSuggestionsForCurrentAgent() -> [TerminalCommandSuggestion] {
        if AgentProfileStore.isBuilderAgent(selectedAgent) {
            return Self.baseCommandSuggestionsWithFeature
        }
        return Self.baseCommandSuggestions
    }

    private static let featureCommandSuggestion = TerminalCommandSuggestion(
        command: "/feature",
        summary: "create/manage features"
    )

    private static let baseCommandSuggestionsWithFeature: [TerminalCommandSuggestion] = {
        var suggestions = baseCommandSuggestions
        suggestions.insert(featureCommandSuggestion, at: 4)
        return suggestions
    }()

    private static let baseCommandSuggestions: [TerminalCommandSuggestion] = [
        TerminalCommandSuggestion(
            command: "/help",
            summary: "show command help"
        ),
        TerminalCommandSuggestion(
            command: "/models",
            summary: "switch model"
        ),
        TerminalCommandSuggestion(
            command: "/agents",
            summary: "switch agent"
        ),
        TerminalCommandSuggestion(
            command: "/tools",
            summary: "select tool groups"
        ),
        TerminalCommandSuggestion(
            command: "/skills",
            summary: "select/install prompt skills"
        ),
        TerminalCommandSuggestion(
            command: "/sessions",
            summary: "save/load/delete sessions"
        ),
        TerminalCommandSuggestion(
            command: "/attach",
            summary: "attach files",
            requiresArgument: true
        ),
        TerminalCommandSuggestion(
            command: "/attachments",
            summary: "show pending attachments"
        ),
        TerminalCommandSuggestion(
            command: "/detach",
            summary: "remove attachments",
            requiresArgument: true
        ),
        TerminalCommandSuggestion(
            command: "/retry",
            summary: "rerun failed prompt"
        ),
        TerminalCommandSuggestion(
            command: "/changes",
            summary: "show last file changes"
        ),
        TerminalCommandSuggestion(
            command: "/undo",
            summary: "revert last file changes"
        ),
        TerminalCommandSuggestion(
            command: "/subagents",
            summary: "show sub-agent status"
        ),
        TerminalCommandSuggestion(
            command: "/clear",
            summary: "reset conversation"
        ),
        TerminalCommandSuggestion(
            command: "/exit",
            summary: "close session"
        ),
        TerminalCommandSuggestion(
            command: "/quit",
            summary: "close session"
        )
    ]

    private func submittedLineAction(_ promptInput: String) async -> TerminalSubmittedLineAction {
        let prompt = promptInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            if !pendingAttachments.isEmpty {
                return .runPrompt("")
            }
            return .continueChat
        }

        switch prompt {
        case "/exit", "/quit":
            return .exitChat
        case "/help":
            writeSystemMessage(renderHelpTextForCurrentAgent())
            return .continueChat
        case "/models":
            do {
                try await selectModelInteractively()
            } catch {
                writeFailureMessage("mlx-coder: \(error.localizedDescription)\n")
            }
            return .continueChat
        case let command where command == "/agents" || command.hasPrefix("/agents "):
            do {
                try await handleAgentsCommand(command)
            } catch {
                writeFailureMessage("mlx-coder: \(error.localizedDescription)\n")
            }
            return .continueChat
        case let command where command == "/tools" || command.hasPrefix("/tools "):
            await handleToolsCommand(command)
            return .continueChat
        case let command where command == "/feature" || command.hasPrefix("/feature "):
            guard AgentProfileStore.isBuilderAgent(selectedAgent) else {
                writeFailureMessage(Self.renderFeatureCommandUnavailableForAgent())
                return .continueChat
            }
            switch await handleFeatureCommand(command) {
            case .none:
                return .continueChat
            case let .runPrompt(prompt):
                return .runPrompt(prompt)
            case let .prefillPrompt(prompt):
                return .prefillPrompt(prompt)
            }
        case let command where command == "/skills" || command.hasPrefix("/skills "):
            await handleSkillsCommand(command)
            return .continueChat
        case let command where command == "/sessions" || command.hasPrefix("/sessions "):
            await handleSessionsCommand(command)
            return .continueChat
        case let command where command == "/attach" || command.hasPrefix("/attach "):
            do {
                try handleAttachCommand(command)
            } catch {
                writeFailureMessage("mlx-coder: \(error.localizedDescription)\n")
            }
            return .continueChat
        case "/attachments":
            writePendingAttachments()
            return .continueChat
        case let command where command == "/detach" || command.hasPrefix("/detach "):
            do {
                try handleDetachCommand(command)
            } catch {
                writeFailureMessage("mlx-coder: \(error.localizedDescription)\n")
            }
            return .continueChat
        case "/retry":
            guard let lastFailedPrompt else {
                writeFailureMessage("mlx-coder: no failed prompt to retry.\n")
                return .continueChat
            }
            return .retryPrompt(lastFailedPrompt)
        case let command where command == "/changes" || command.hasPrefix("/changes "):
            handleChangesCommand(command)
            return .continueChat
        case "/undo":
            await handleUndoFileChangesCommand()
            return .continueChat
        case let command where command == "/subagents" || command.hasPrefix("/subagents "):
            await handleSubAgentsCommand(command)
            return .continueChat
        case "/clear":
            do {
                await sessionRunner.resetSession(id: sessionID)
                sessionID = Self.newTerminalSessionID()
                activeSessionCacheKey = nil
                activeSessionHistory = []
                activeSessionTranscript = []
                activeSessionSystemPromptOverride = nil
                activeSavedSessionName = nil
                try await createCurrentSession()
                statusBar.reset()
                refreshInitialStatusBarContextWindow()
                pendingAttachments.removeAll()
                lastFailedPrompt = nil
                isSubAgentOverviewVisible = false
                lastRenderedSubAgentOverviewSignature = nil
                stopSubAgentOverviewRefreshLoop()
                writeSystemMessage("Session cleared.\n")
            } catch {
                writeFailureMessage("mlx-coder: \(error.localizedDescription)\n")
            }
            return .continueChat
        default:
            return .runPrompt(prompt)
        }
    }

    private func promptAttempt(prompt: String) -> TerminalPromptAttempt {
        TerminalPromptAttempt(
            prompt: prompt,
            attachments: consumePendingAttachmentsForPrompt(),
            baseCacheKey: activeSessionCacheKey,
            baseHistory: activeSessionHistory,
            restoresBaseBeforeRun: false
        )
    }

    private func promptAttempt(
        retryPrompt: TerminalRetryPrompt
    ) -> TerminalPromptAttempt {
        TerminalPromptAttempt(
            prompt: retryPrompt.prompt,
            attachments: retryPrompt.attachments,
            baseCacheKey: retryPrompt.baseCacheKey,
            baseHistory: retryPrompt.baseHistory,
            restoresBaseBeforeRun: true
        )
    }

    private func runPromptBlocking(_ attempt: TerminalPromptAttempt) async {
        do {
            didReceiveMetricsForCurrentPrompt = false
            statusBar.setProcessing(true)
            defer {
                statusBar.setProcessing(false)
            }
            let promptTask = Task {
                try await generateResponse(attempt: attempt)
            }
            let stopMonitor = TerminalEscapeStopMonitor.startIfNeeded(
                isEnabled: stdinIsTerminal
            ) {
                promptTask.cancel()
            }
            let response: DirectAgentResponse
            do {
                response = try await promptTask.value
            } catch {
                if let stopMonitor {
                    stopMonitor.cancel()
                    await stopMonitor.value
                }
                throw error
            }
            if let stopMonitor {
                stopMonitor.cancel()
                await stopMonitor.value
            }
            await finishPromptResult(.success(response))
        } catch {
            let failure = TerminalChatGenerationFailure(
                message: error.localizedDescription,
                isCancellation: error is CancellationError,
                retryPrompt: error is CancellationError ? nil : attempt.retryPrompt
            )
            await finishPromptResult(.failure(failure))
        }
    }

    private func generateResponse(
        attempt: TerminalPromptAttempt
    ) async throws -> DirectAgentResponse {
        if attempt.restoresBaseBeforeRun {
            await sessionRunner.resetSession(id: sessionID)
            activeSessionCacheKey = attempt.baseCacheKey
            activeSessionHistory = attempt.baseHistory
        }
        let transcriptTurn = TerminalSessionTranscriptTurn(
            prompt: attempt.prompt,
            attachments: attempt.attachments
        )
        let fileChanges = TurnFileChangeCoordinator(
            baseDirectoryURL: configuration.workingDirectory
        )
        do {
            let response = try await sessionRunner.sendPrompt(
                configuration: await currentSessionConfiguration(),
                prompt: attempt.prompt,
                attachments: attempt.attachments,
                onToolWillExecute: { toolCall in
                    await fileChanges.captureBaselineIfNeeded(
                        forAgentToolCall: toolCall
                    )
                },
                onEvent: { event in
                    switch event {
                    case let .status(message):
                        if self.configuration.verboseLogging {
                            self.writeChatError("[mlx-coder] \(message)\n")
                        }
                    case let .diagnostic(message):
                        if self.configuration.verboseLogging {
                            self.writeDiagnostic(message)
                        }
                    case let .thought(message):
                        await transcriptTurn.appendThought(message)
                        self.writeThought(message)
                    case let .modelLoaded(modelID):
                        self.printModelIfNeeded(modelID)
                    case let .modelLoadedDetails(details):
                        self.printLoadedModelDetails(details)
                    case let .metrics(metrics):
                        self.didReceiveMetricsForCurrentPrompt = true
                        self.writeMetricsStatus(metrics)
                    case let .contextWindow(status):
                        self.writeContextWindowStatus(status)
                    case let .content(delta):
                        await transcriptTurn.appendAssistantContent(delta)
                        self.finishThoughtOutputIfNeeded()
                        self.writeAssistantContent(delta)
                    case let .toolCallStarted(toolCall):
                        await transcriptTurn.appendToolCallStarted(toolCall)
                        self.finishThoughtOutputIfNeeded()
                        self.finishAssistantContentFormatting()
                        self.writeToolCallStarted(toolCall)
                    case let .toolCallCompleted(toolCall, result):
                        await transcriptTurn.appendToolCallCompleted(toolCall, result: result)
                        self.finishThoughtOutputIfNeeded()
                        self.finishAssistantContentFormatting()
                        self.writeToolCallCompleted(toolCall, result: result)
                        await self.publishSubAgentOverviewIfVisible(
                            relatedToolName: toolCall.name
                        )
                    case let .sessionSnapshot(snapshot):
                        self.activeSessionCacheKey = snapshot.cacheKey
                        self.activeSessionHistory = snapshot.history
                    case .turnEnded:
                        break
                    }
                }
            )
            activeSessionTranscript.append(contentsOf: await transcriptTurn.messages())
            await publishFileChangeSummaryIfNeeded(from: fileChanges)
            await publishSubAgentOverviewIfVisible()
            return response
        } catch {
            activeSessionTranscript.append(contentsOf: await transcriptTurn.messages())
            await publishFileChangeSummaryIfNeeded(from: fileChanges)
            await publishSubAgentOverviewIfVisible()
            throw error
        }
    }

    private func finishPromptResult(_ result: TerminalChatGenerationResult) async {
        switch result {
        case let .success(response):
            lastFailedPrompt = nil
            finishThoughtOutputIfNeeded()
            finishAssistantContentFormatting()
            printModelIfNeeded(response.modelID)
            if response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                writeChatOutput("Done.")
            }
            writeChatOutput("\n")
        case let .failure(failure):
            finishThoughtOutputIfNeeded()
            finishAssistantContentFormatting()
            if failure.isCancellation {
                writeChatError("\nStopped.\n")
            } else {
                lastFailedPrompt = failure.retryPrompt
                writeFailureMessage("mlx-coder: \(failure.message)\n")
                if failure.retryPrompt != nil {
                    writeSystemMessage("Use /retry to run the prompt again.\n")
                }
            }
        }
    }
}

private enum TerminalSubmittedLineAction {
    case continueChat
    case exitChat
    case runPrompt(String)
    case retryPrompt(TerminalRetryPrompt)
    case prefillPrompt(String)
}

private struct TerminalPromptAttempt: Sendable {
    let prompt: String
    let attachments: [AgentRuntimeAttachment]
    let baseCacheKey: String?
    let baseHistory: [AgentRuntimeMessage]
    let restoresBaseBeforeRun: Bool

    var retryPrompt: TerminalRetryPrompt {
        TerminalRetryPrompt(
            prompt: prompt,
            attachments: attachments,
            baseCacheKey: baseCacheKey,
            baseHistory: baseHistory
        )
    }
}

private struct TerminalRetryPrompt: Sendable {
    let prompt: String
    let attachments: [AgentRuntimeAttachment]
    let baseCacheKey: String?
    let baseHistory: [AgentRuntimeMessage]
}

private struct TerminalChatGenerationFailure: Sendable {
    let message: String
    let isCancellation: Bool
    let retryPrompt: TerminalRetryPrompt?
}

private actor TerminalSessionTranscriptTurn {
    private var transcriptMessages: [AgentRuntimeMessage]
    private var assistantContent = ""
    private var reasoningContent = ""
    private var startedToolCallIDs = Set<String>()
    private var completedToolCallIDs = Set<String>()

    init(prompt: String, attachments: [AgentRuntimeAttachment]) {
        let userMessage = AgentRuntimeMessage(
            role: .user,
            content: prompt,
            attachments: attachments
        )
        self.transcriptMessages = [userMessage]
    }

    func appendThought(_ delta: String) {
        reasoningContent.append(delta)
    }

    func appendAssistantContent(_ delta: String) {
        assistantContent.append(delta)
    }

    func appendToolCallStarted(_ toolCall: DirectAgentToolCall) {
        guard startedToolCallIDs.insert(toolCall.id).inserted else {
            return
        }
        flushAssistantMessage()
        transcriptMessages.append(
            AgentRuntimeMessage(
                role: .assistant,
                content: "",
                toolCalls: [Self.runtimeToolCall(from: toolCall)]
            )
        )
    }

    func appendToolCallCompleted(
        _ toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) {
        appendToolCallStarted(toolCall)
        guard completedToolCallIDs.insert(toolCall.id).inserted else {
            return
        }
        transcriptMessages.append(
            AgentRuntimeMessage(
                role: .tool,
                content: result.output,
                toolCallID: toolCall.id,
                toolName: toolCall.name
            )
        )
    }

    func messages() -> [AgentRuntimeMessage] {
        flushAssistantMessage()
        return transcriptMessages
    }

    private func flushAssistantMessage() {
        guard assistantContent.nilIfBlank != nil
            || reasoningContent.nilIfBlank != nil else {
            return
        }
        transcriptMessages.append(
            AgentRuntimeMessage(
                role: .assistant,
                content: assistantContent,
                reasoningContent: reasoningContent
            )
        )
        assistantContent = ""
        reasoningContent = ""
    }

    private static func runtimeToolCall(
        from toolCall: DirectAgentToolCall
    ) -> AgentRuntimeToolCall {
        AgentRuntimeToolCall(
            id: toolCall.id,
            name: toolCall.name,
            argumentsJSON: toolCall.argumentsJSON
        )
    }
}

private enum TerminalChatGenerationResult: Sendable {
    case success(DirectAgentResponse)
    case failure(TerminalChatGenerationFailure)
}

private enum TerminalChatRuntimeEvent: Sendable {
    case input(TerminalPromptInputEvent)
    case generationCompleted(TerminalChatGenerationResult)
}

private actor TerminalChatEventQueue {
    private var events: [TerminalChatRuntimeEvent] = []
    private var waiters: [CheckedContinuation<TerminalChatRuntimeEvent, Never>] = []

    func send(_ event: TerminalChatRuntimeEvent) {
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.resume(returning: event)
            return
        }
        events.append(event)
    }

    func next() async -> TerminalChatRuntimeEvent {
        if !events.isEmpty {
            return events.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private enum TerminalEscapeStopMonitor {
    static func startIfNeeded(
        isEnabled: Bool,
        onStop: @escaping @Sendable () -> Void
    ) -> Task<Void, Never>? {
        guard isEnabled else {
            return nil
        }

        return Task.detached {
            let rawInput = TerminalRawInput()
            guard rawInput.beginRawMode() else {
                return
            }

            defer {
                rawInput.restoreRawMode()
            }

            while !Task.isCancelled {
                guard let byte = rawInput.readByte(timeoutMilliseconds: 100) else {
                    continue
                }
                guard byte == 0x1B else {
                    continue
                }
                if rawInput.readByte(timeoutMilliseconds: 25) == nil {
                    onStop()
                    return
                }
                drainPendingEscapeSequence(rawInput: rawInput)
            }
        }
    }

    private static func drainPendingEscapeSequence(rawInput: TerminalRawInput) {
        while rawInput.readByte(timeoutMilliseconds: 5) != nil {}
    }
}
