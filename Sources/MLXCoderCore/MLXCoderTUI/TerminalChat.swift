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
    public let sessionID = "terminal-\(UUID().uuidString.lowercased())"
    public var diskCacheKey: String {
        AgentKVCachePersistencePolicy.terminalDiskCacheKey(
            workingDirectoryPath: configuration.workingDirectory.path
        )
    }
    public var printedModelID: String?
    public var didPrintActiveTools = false
    public var didReceiveMetricsForCurrentPrompt = false
    public var selectedAgent: AgentProfile?
    public var manualModelIDOverride: String?
    public var manualThinkingSelectionOverride: AgentThinkingSelection?
    public var selectedToolGroups = Set<TerminalToolGroup>()
    public var selectedSkillIDs = Set<String>()
    public var pendingAttachments: [AgentRuntimeAttachment] = []
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

        applyInitialAgentSelectionIfNeeded()
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
                await runPromptBlocking(prompt)
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
                commandSuggestions: Self.commandSuggestions
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

        func startGeneration(prompt: String) {
            isGenerating = true
            didReceiveMetricsForCurrentPrompt = false
            statusBar.setProcessing(true)
            interactiveReader.setPanelProcessing(true)
            generationTask = Task {
                let result: TerminalChatGenerationResult
                do {
                    result = .success(try await self.generateResponse(prompt: prompt))
                } catch is CancellationError {
                    result = .failure(
                        TerminalChatGenerationFailure(
                            message: "",
                            isCancellation: true
                        )
                    )
                } catch {
                    result = .failure(
                        TerminalChatGenerationFailure(
                            message: error.localizedDescription,
                            isCancellation: false
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
                writeSubmittedPrompt(prompt)
                startGeneration(prompt: prompt)
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

    private static let commandSuggestions: [TerminalCommandSuggestion] = [
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
            writeSystemMessage(
                """
                Type a prompt and press return.
                /models shows configured models and lets you switch the default agent model.
                /agents selects an agent profile and resets the session.
                /tools selects which tool groups are available to the model.
                /skills selects installed prompt skills or installs one from GitHub or a local folder.
                /attach <file> [file ...] attaches image or video files to the next prompt.
                /attachments shows pending attachments.
                /detach [all|number] removes pending attachments.
                /changes shows the most recent file change summary. Use /changes diff to include patches.
                /undo reverts the most recent tracked file changes.
                /subagents shows delegated sub-agent status. Use /subagents off to hide automatic updates.
                Ctrl+T toggles compact/full tool output.
                /clear resets the conversation.
                /exit closes the session.

                """
            )
            return .continueChat
        case "/models":
            do {
                try await selectModelInteractively()
            } catch {
                writeChatError("mlx-coder: \(error.localizedDescription)\n")
            }
            return .continueChat
        case let command where command == "/agents" || command.hasPrefix("/agents "):
            do {
                try await handleAgentsCommand(command)
            } catch {
                writeChatError("mlx-coder: \(error.localizedDescription)\n")
            }
            return .continueChat
        case let command where command == "/tools" || command.hasPrefix("/tools "):
            await handleToolsCommand(command)
            return .continueChat
        case let command where command == "/skills" || command.hasPrefix("/skills "):
            await handleSkillsCommand(command)
            return .continueChat
        case let command where command == "/attach" || command.hasPrefix("/attach "):
            do {
                try handleAttachCommand(command)
            } catch {
                writeChatError("mlx-coder: \(error.localizedDescription)\n")
            }
            return .continueChat
        case "/attachments":
            writePendingAttachments()
            return .continueChat
        case let command where command == "/detach" || command.hasPrefix("/detach "):
            do {
                try handleDetachCommand(command)
            } catch {
                writeChatError("mlx-coder: \(error.localizedDescription)\n")
            }
            return .continueChat
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
                try await createCurrentSession()
                statusBar.reset()
                refreshInitialStatusBarContextWindow()
                pendingAttachments.removeAll()
                isSubAgentOverviewVisible = false
                lastRenderedSubAgentOverviewSignature = nil
                stopSubAgentOverviewRefreshLoop()
                writeSystemMessage("Session cleared.\n")
            } catch {
                writeChatError("mlx-coder: \(error.localizedDescription)\n")
            }
            return .continueChat
        default:
            return .runPrompt(prompt)
        }
    }

    private func runPromptBlocking(_ prompt: String) async {
        do {
            didReceiveMetricsForCurrentPrompt = false
            statusBar.setProcessing(true)
            defer {
                statusBar.setProcessing(false)
            }
            let promptTask = Task {
                try await generateResponse(prompt: prompt)
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
                isCancellation: error is CancellationError
            )
            await finishPromptResult(.failure(failure))
        }
    }

    private func generateResponse(prompt: String) async throws -> DirectAgentResponse {
        let attachments = consumePendingAttachmentsForPrompt()
        let fileChangeTracker = TurnFileChangeTracker(
            workspacePath: configuration.workingDirectory.path
        )
        do {
            let response = try await sessionRunner.sendPrompt(
                configuration: await currentSessionConfiguration(),
                prompt: prompt,
                attachments: attachments,
                onToolWillExecute: { toolCall in
                    await fileChangeTracker.captureBaselineIfNeeded(
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
                        self.finishThoughtOutputIfNeeded()
                        self.writeAssistantContent(delta)
                    case let .toolCallStarted(toolCall):
                        self.finishThoughtOutputIfNeeded()
                        self.finishAssistantContentFormatting()
                        self.writeToolCallStarted(toolCall)
                    case let .toolCallCompleted(toolCall, result):
                        self.finishThoughtOutputIfNeeded()
                        self.finishAssistantContentFormatting()
                        self.writeToolCallCompleted(toolCall, result: result)
                        await self.publishSubAgentOverviewIfVisible(
                            relatedToolName: toolCall.name
                        )
                    }
                }
            )
            await publishFileChangeSummaryIfNeeded(from: fileChangeTracker)
            await publishSubAgentOverviewIfVisible()
            return response
        } catch {
            await publishFileChangeSummaryIfNeeded(from: fileChangeTracker)
            await publishSubAgentOverviewIfVisible()
            throw error
        }
    }

    private func finishPromptResult(_ result: TerminalChatGenerationResult) async {
        switch result {
        case let .success(response):
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
                writeChatError("mlx-coder: \(failure.message)\n")
            }
        }
    }
}

private enum TerminalSubmittedLineAction {
    case continueChat
    case exitChat
    case runPrompt(String)
}

private struct TerminalChatGenerationFailure: Sendable {
    let message: String
    let isCancellation: Bool
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
