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
    var lastFailedPrompt: TerminalRetryPrompt?
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
    public let telegramControlService = TerminalTelegramControlService()
    public var telegramControlState = TerminalTelegramControlState.inactive()
    public var telegramLinkedChatID: Int64?
    public var telegramLinkedChatTitle: String?
    public let voiceRecordingService = TerminalVoiceRecordingService()
    public var activeVoiceRecordingSession: TerminalVoiceRecordingSession?

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
            Task {
                _ = await telegramControlService.stop()
            }
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

            if activeVoiceRecordingSession != nil {
                await stopVoiceRecordingAndRunPromptBlocking()
                continue
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
        var queuedPrompts: [TerminalQueuedPrompt] = []
        var generationTask: Task<Void, Never>?
        var voiceTranscriptionTask: Task<Void, Never>?
        let telegramForwardingTask = startTelegramForwardingTask(eventQueue: eventQueue)
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
                    result = .success(
                        try await self.generateResponse(attempt: attempt),
                        attempt.origin
                    )
                } catch is CancellationError {
                    result = .failure(
                        TerminalChatGenerationFailure(
                            message: "",
                            isCancellation: true,
                            retryPrompt: nil,
                            origin: attempt.origin
                        )
                    )
                } catch {
                    result = .failure(
                        TerminalChatGenerationFailure(
                            message: error.localizedDescription,
                            isCancellation: false,
                            retryPrompt: attempt.retryPrompt,
                            origin: attempt.origin
                        )
                    )
                }
                await eventQueue.send(.generationCompleted(result))
            }
        }

        func startDirectPrompt(_ prompt: String, origin: TerminalPromptOrigin) {
            let attempt = promptAttempt(prompt: prompt, origin: origin)
            if origin == .local {
                writeSubmittedPrompt(prompt)
            } else {
                writeTelegramSubmittedPrompt(prompt)
            }
            startGeneration(attempt: attempt)
        }

        guard startPanelInput() else {
            statusBar.stop()
            throw TerminalChatError.interactivePromptUnavailable
        }
        defer {
            generationTask?.cancel()
            voiceTranscriptionTask?.cancel()
            voiceRecordingService.cancelRecording()
            telegramForwardingTask.cancel()
        }

        func handleSubmittedPanelLine(
            _ line: String,
            origin: TerminalPromptOrigin = .local
        ) async -> Bool {
            let shouldSuspendPanel = origin == .local && Self.shouldSuspendPanelInput(for: line)
            if shouldSuspendPanel {
                await stopPanelInput(clearPanel: false)
            }

            switch await submittedLineAction(line, origin: origin) {
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
                let attempt = promptAttempt(prompt: prompt, origin: origin)
                if origin == .local {
                    writeSubmittedPrompt(prompt)
                } else {
                    writeTelegramSubmittedPrompt(prompt)
                }
                startGeneration(attempt: attempt)
                return true
            case let .retryPrompt(retryPrompt):
                if shouldSuspendPanel {
                    _ = startPanelInput()
                }
                let attempt = promptAttempt(retryPrompt: retryPrompt, origin: origin)
                if origin == .local {
                    writeSubmittedPrompt(retryPrompt.prompt)
                } else {
                    writeTelegramSubmittedPrompt(retryPrompt.prompt)
                }
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
                if nextPrompt.mode == .directPrompt {
                    startDirectPrompt(nextPrompt.text, origin: nextPrompt.origin)
                    continue
                }
                guard await handleSubmittedPanelLine(
                    nextPrompt.text,
                    origin: nextPrompt.origin
                ) else {
                    break eventLoop
                }
                continue
            }

            let event = await eventQueue.next()
            switch event {
            case let .input(inputEvent):
                switch inputEvent {
                case let .submitted(line):
                    if activeVoiceRecordingSession != nil {
                        voiceTranscriptionTask = stopVoiceRecordingAndTranscribe(
                            eventQueue: eventQueue
                        )
                        continue
                    }

                    if isGenerating {
                        if Self.isSubAgentsCommand(line) {
                            _ = await handleSubmittedPanelLine(line)
                        } else if Self.isVoiceCommand(line) {
                            writeFailureMessage("mlx-coder: /voice is unavailable while a prompt is running.\n")
                        } else {
                            queuedPrompts.append(TerminalQueuedPrompt(text: line, origin: .local))
                            interactiveReader.setQueuedPromptCount(queuedPrompts.count)
                        }
                        continue
                    }

                    guard await handleSubmittedPanelLine(line) else {
                        break eventLoop
                    }
                case .cancelRequested:
                    if activeVoiceRecordingSession != nil {
                        cancelVoiceRecording()
                    } else if voiceTranscriptionTask != nil {
                        voiceTranscriptionTask?.cancel()
                        voiceTranscriptionTask = nil
                        clearVoicePanelMode()
                        writeSystemMessage("Voice transcription cancelled.\n")
                    } else {
                        generationTask?.cancel()
                    }
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
            case let .telegramMessage(message):
                await handleTelegramMessage(
                    message,
                    isGenerating: isGenerating,
                    queuedPrompts: &queuedPrompts,
                    eventQueue: eventQueue
                )
                interactiveReader.setQueuedPromptCount(queuedPrompts.count)
            case let .voicePromptCompleted(result):
                if result.origin == .local {
                    voiceTranscriptionTask = nil
                    clearVoicePanelMode()
                    interactiveReader.setPanelProcessing(isGenerating)
                }
                switch result.outcome {
                case let .success(prompt):
                    if isGenerating {
                        queuedPrompts.append(
                            TerminalQueuedPrompt(
                                text: prompt,
                                origin: result.origin,
                                mode: .directPrompt
                            )
                        )
                        interactiveReader.setQueuedPromptCount(queuedPrompts.count)
                        await sendTelegramSystemMessageIfLinked(
                            "Transcription ready. Queued for the current mlx-coder session.",
                            origin: result.origin
                        )
                    } else {
                        await sendTelegramSystemMessageIfLinked(
                            "Transcription ready. mlx-coder is working.",
                            origin: result.origin
                        )
                        startDirectPrompt(prompt, origin: result.origin)
                    }
                case let .failure(message):
                    writeFailureMessage("mlx-coder: \(message)\n")
                    await sendTelegramSystemMessageIfLinked(
                        "Voice transcription failed: \(message)",
                        origin: result.origin
                    )
                }
            }
        }

        await stopPanelInput()
    }

    private static func shouldSuspendPanelInput(for line: String) -> Bool {
        let prompt = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.hasPrefix("/")
    }

    private static func isSubAgentsCommand(_ line: String) -> Bool {
        let prompt = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt == "/subagents" || prompt.hasPrefix("/subagents ")
    }

    private static func isVoiceCommand(_ line: String) -> Bool {
        let prompt = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt == "/voice" || prompt.hasPrefix("/voice ")
    }

    private func renderHelpTextForCurrentAgent() -> String {
        var lines = [
            "Type a prompt and press return."
        ]
        lines.append(contentsOf: visibleCommandDescriptorsForCurrentAgent().map(\.help))
        lines.append(contentsOf: [
            "Ctrl+T toggles compact/full tool output.",
        ])
        return lines.joined(separator: "\n") + "\n\n"
    }

    func commandSuggestionsForCurrentAgent() -> [TerminalCommandSuggestion] {
        visibleCommandDescriptorsForCurrentAgent().map { descriptor in
            TerminalCommandSuggestion(
                command: descriptor.command,
                summary: descriptor.summary,
                requiresArgument: descriptor.requiresArgument
            )
        }
    }

    private func submittedLineAction(
        _ promptInput: String,
        origin: TerminalPromptOrigin = .local
    ) async -> TerminalSubmittedLineAction {
        let prompt = promptInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            if origin == .local && !pendingAttachments.isEmpty {
                return .runPrompt("")
            }
            return .continueChat
        }

        if origin != .local {
            return submittedTelegramLineAction(prompt)
        }

        switch prompt {
        case "/exit":
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
        case let command where command == "/sessions" || command.hasPrefix("/sessions ")
            || command == "/session" || command.hasPrefix("/session "):
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
        case let command where command == "/telegram" || command.hasPrefix("/telegram "):
            guard isTelegramCommandVisible() else {
                writeFailureMessage(Self.unknownCommandMessage(for: command))
                return .continueChat
            }
            await handleTelegramCommand(command)
            return .continueChat
        case let command where command == "/voice" || command.hasPrefix("/voice "):
            guard isVoiceCommandVisible() else {
                writeFailureMessage(Self.unknownCommandMessage(for: command))
                return .continueChat
            }
            await handleVoiceCommand(command)
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
            if prompt.hasPrefix("/") {
                writeFailureMessage(Self.unknownCommandMessage(for: prompt))
                return .continueChat
            }
            return .runPrompt(prompt)
        }
    }

    func promptAttempt(
        prompt: String,
        origin: TerminalPromptOrigin = .local
    ) -> TerminalPromptAttempt {
        TerminalPromptAttempt(
            prompt: prompt,
            attachments: origin == .local ? consumePendingAttachmentsForPrompt() : [],
            baseCacheKey: activeSessionCacheKey,
            baseHistory: activeSessionHistory,
            restoresBaseBeforeRun: false,
            origin: origin
        )
    }

    func promptAttempt(
        retryPrompt: TerminalRetryPrompt,
        origin: TerminalPromptOrigin = .local
    ) -> TerminalPromptAttempt {
        TerminalPromptAttempt(
            prompt: retryPrompt.prompt,
            attachments: retryPrompt.attachments,
            baseCacheKey: retryPrompt.baseCacheKey,
            baseHistory: retryPrompt.baseHistory,
            restoresBaseBeforeRun: true,
            origin: origin
        )
    }

    func runPromptBlocking(_ attempt: TerminalPromptAttempt) async {
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
            await finishPromptResult(.success(response, attempt.origin))
        } catch {
            let failure = TerminalChatGenerationFailure(
                message: error.localizedDescription,
                isCancellation: error is CancellationError,
                retryPrompt: error is CancellationError ? nil : attempt.retryPrompt,
                origin: attempt.origin
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
        let telegramProgressReporter = telegramControlState.isActive
            ? makeTelegramTurnProgressReporter(for: attempt.origin)
            : nil
        if let telegramProgressReporter = telegramProgressReporter {
            await telegramProgressReporter.enqueue(
                telegramTurnStartedMessage(prompt: attempt.prompt)
            )
        }
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
                        if let telegramProgressReporter = telegramProgressReporter,
                           let progressMessage = self.telegramStatusProgressMessage(message) {
                            await telegramProgressReporter.enqueueStatus(progressMessage)
                        }
                    case let .diagnostic(message):
                        if self.configuration.verboseLogging {
                            self.writeDiagnostic(message)
                        }
                        if let telegramProgressReporter = telegramProgressReporter,
                           let progressMessage = self.telegramDiagnosticProgressMessage(message) {
                            await telegramProgressReporter.enqueueStatus(progressMessage)
                        }
                    case let .thought(message):
                        await transcriptTurn.appendThought(message)
                        self.writeThought(message)
                        if let telegramProgressReporter = telegramProgressReporter,
                           message.nilIfBlank != nil {
                            await telegramProgressReporter.enqueueThinkingIfNeeded()
                        }
                    case let .modelLoaded(modelID):
                        self.printModelIfNeeded(modelID)
                        if let telegramProgressReporter = telegramProgressReporter {
                            await telegramProgressReporter.enqueue(
                                self.telegramModelLoadedMessage(modelID: modelID)
                            )
                        }
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
                        if let telegramProgressReporter = telegramProgressReporter,
                           delta.nilIfBlank != nil {
                            await telegramProgressReporter.enqueueWritingIfNeeded()
                        }
                    case let .toolCallStarted(toolCall):
                        await transcriptTurn.appendToolCallStarted(toolCall)
                        self.finishThoughtOutputIfNeeded()
                        self.finishAssistantContentFormatting()
                        self.writeToolCallStarted(toolCall)
                        if let telegramProgressReporter = telegramProgressReporter {
                            await telegramProgressReporter.enqueue(
                                self.telegramToolStartedMessage(toolCall)
                            )
                        }
                        await self.publishSubAgentOverviewIfVisible(
                            relatedToolName: toolCall.name
                        )
                    case let .toolCallCompleted(toolCall, result):
                        await transcriptTurn.appendToolCallCompleted(toolCall, result: result)
                        self.finishThoughtOutputIfNeeded()
                        self.finishAssistantContentFormatting()
                        self.writeToolCallCompleted(toolCall, result: result)
                        if let telegramProgressReporter = telegramProgressReporter {
                            await telegramProgressReporter.enqueue(
                                self.telegramToolCompletedMessage(toolCall, result: result)
                            )
                        }
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
            activeSessionTranscript.append(
                contentsOf: await transcriptTurn.messages(finalResponseText: response.text)
            )
            let fileChangeSummary = await publishFileChangeSummaryIfNeeded(from: fileChanges)
            if let telegramProgressReporter = telegramProgressReporter,
               let summary = fileChangeSummary {
                await telegramProgressReporter.enqueue(
                    telegramFileChangeSummaryMessage(summary)
                )
            }
            await publishSubAgentOverviewIfVisible()
            await telegramProgressReporter?.flush()
            return response
        } catch {
            activeSessionTranscript.append(contentsOf: await transcriptTurn.messages())
            let fileChangeSummary = await publishFileChangeSummaryIfNeeded(from: fileChanges)
            if let telegramProgressReporter = telegramProgressReporter,
               let summary = fileChangeSummary {
                await telegramProgressReporter.enqueue(
                    telegramFileChangeSummaryMessage(summary)
                )
            }
            await publishSubAgentOverviewIfVisible()
            await telegramProgressReporter?.flush()
            throw error
        }
    }

    private func finishPromptResult(_ result: TerminalChatGenerationResult) async {
        switch result {
        case let .success(response, origin):
            lastFailedPrompt = nil
            finishThoughtOutputIfNeeded()
            finishAssistantContentFormatting()
            printModelIfNeeded(response.modelID)
            let responseText = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if responseText.isEmpty {
                writeChatOutput("Done.")
            }
            writeChatOutput("\n")
            await sendTelegramCompletionIfLinked(
                responseText.isEmpty ? "Done." : responseText,
                origin: origin
            )
        case let .failure(failure):
            finishThoughtOutputIfNeeded()
            finishAssistantContentFormatting()
            if failure.isCancellation {
                writeChatError("\nStopped.\n")
                await sendTelegramSystemMessageIfLinked("Stopped.", origin: failure.origin)
            } else {
                lastFailedPrompt = failure.retryPrompt
                writeFailureMessage("mlx-coder: \(failure.message)\n")
                if failure.retryPrompt != nil {
                    writeSystemMessage("Use /retry to run the prompt again.\n")
                }
                await sendTelegramSystemMessageIfLinked(
                    "mlx-coder failed: \(failure.message)",
                    origin: failure.origin
                )
            }
        }
    }
}

enum TerminalSubmittedLineAction {
    case continueChat
    case exitChat
    case runPrompt(String)
    case retryPrompt(TerminalRetryPrompt)
    case prefillPrompt(String)
}

struct TerminalPromptAttempt: Sendable {
    let prompt: String
    let attachments: [AgentRuntimeAttachment]
    let baseCacheKey: String?
    let baseHistory: [AgentRuntimeMessage]
    let restoresBaseBeforeRun: Bool
    let origin: TerminalPromptOrigin

    var retryPrompt: TerminalRetryPrompt {
        TerminalRetryPrompt(
            prompt: prompt,
            attachments: attachments,
            baseCacheKey: baseCacheKey,
            baseHistory: baseHistory
        )
    }
}

struct TerminalRetryPrompt: Sendable {
    let prompt: String
    let attachments: [AgentRuntimeAttachment]
    let baseCacheKey: String?
    let baseHistory: [AgentRuntimeMessage]
}

struct TerminalChatGenerationFailure: Sendable {
    let message: String
    let isCancellation: Bool
    let retryPrompt: TerminalRetryPrompt?
    let origin: TerminalPromptOrigin
}

enum TerminalPromptOrigin: Sendable, Equatable {
    case local
    case telegram(chatID: Int64)
}

struct TerminalQueuedPrompt: Sendable, Equatable {
    let text: String
    let origin: TerminalPromptOrigin
    let mode: TerminalQueuedPromptMode

    init(
        text: String,
        origin: TerminalPromptOrigin,
        mode: TerminalQueuedPromptMode = .submittedLine
    ) {
        self.text = text
        self.origin = origin
        self.mode = mode
    }
}

enum TerminalQueuedPromptMode: Sendable, Equatable {
    case submittedLine
    case directPrompt
}

struct TerminalVoicePromptResult: Sendable {
    let origin: TerminalPromptOrigin
    let outcome: Outcome

    enum Outcome: Sendable {
        case success(String)
        case failure(String)
    }
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

    func messages(finalResponseText: String? = nil) -> [AgentRuntimeMessage] {
        if let finalResponseText,
           shouldPromoteReasoningToContent(finalResponseText) {
            assistantContent = finalResponseText
            reasoningContent = ""
        }
        flushAssistantMessage()
        return transcriptMessages
    }

    private func shouldPromoteReasoningToContent(_ finalResponseText: String) -> Bool {
        let finalText = finalResponseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalText.isEmpty,
              assistantContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
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

enum TerminalChatGenerationResult: Sendable {
    case success(DirectAgentResponse, TerminalPromptOrigin)
    case failure(TerminalChatGenerationFailure)
}

enum TerminalChatRuntimeEvent: Sendable {
    case input(TerminalPromptInputEvent)
    case generationCompleted(TerminalChatGenerationResult)
    case telegramMessage(TerminalTelegramIncomingMessage)
    case voicePromptCompleted(TerminalVoicePromptResult)
}

actor TerminalChatEventQueue {
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
