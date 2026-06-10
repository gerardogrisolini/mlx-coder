//
//  TerminalChat+Telegram.swift
//  mlx-coder
//

import Foundation

extension TerminalChat {
    func handleTelegramCommand(_ command: String) async {
        let argument = String(command.dropFirst("/telegram".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch TerminalTelegramCommandAction(argument: argument) {
        case .status:
            await printTelegramStatus()
        case .turnOn:
            await startTelegramControl()
        case .turnOff:
            await stopTelegramControl()
        case .usage:
            writeSystemMessage("Usage: /telegram [on|off]\n")
        }
    }

    func submittedTelegramLineAction(_ prompt: String) -> TerminalSubmittedLineAction {
        switch TerminalTelegramRemoteCommand(text: prompt) {
        case .start:
            Task {
                await sendTelegramSystemMessageIfLinked(
                    "Telegram is already linked to this mlx-coder session. Send a prompt or /help."
                )
            }
            return .continueChat
        case .help:
            Task {
                await sendTelegramSystemMessageIfLinked(telegramRemoteHelpText())
            }
            return .continueChat
        case .status:
            Task {
                await sendTelegramSystemMessageIfLinked(telegramRemoteStatusText())
            }
            return .continueChat
        case .changes:
            Task {
                await sendTelegramSystemMessageIfLinked(telegramRemoteChangesText())
            }
            return .continueChat
        case .retry:
            guard let lastFailedPrompt else {
                Task {
                    await sendTelegramSystemMessageIfLinked("Retry is not available.")
                }
                return .continueChat
            }
            return .retryPrompt(lastFailedPrompt)
        case .undo:
            Task {
                await sendTelegramSystemMessageIfLinked(
                    "Use /undo in the TUI to revert file changes."
                )
            }
            return .continueChat
        case .none:
            return .runPrompt(prompt)
        }
    }

    func startTelegramForwardingTask(
        eventQueue: TerminalChatEventQueue
    ) -> Task<Void, Never> {
        let service = telegramControlService
        return Task { [weak self] in
            for await message in service.incomingMessages {
                guard self != nil else {
                    return
                }
                await eventQueue.send(.telegramMessage(message))
            }
        }
    }

    func handleTelegramMessage(
        _ message: TerminalTelegramIncomingMessage,
        isGenerating: Bool,
        queuedPrompts: inout [TerminalQueuedPrompt],
        eventQueue: TerminalChatEventQueue
    ) async {
        guard telegramControlState.isActive else {
            return
        }

        guard telegramLinkedChatID != nil else {
            await sendTelegramSystemMessage(
                "Telegram is not paired. Run mlx-coder --setup to pair this bot.",
                to: message.chatID
            )
            return
        }

        guard telegramLinkedChatID == message.chatID else {
            await sendTelegramSystemMessage(
                "This bot is already linked to another mlx-coder session.",
                to: message.chatID
            )
            return
        }

        if let voice = message.voice {
            await handleTelegramVoiceMessage(
                voice,
                chatID: message.chatID,
                eventQueue: eventQueue
            )
            return
        }

        let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return }

        if await handleTelegramPermissionResponseIfNeeded(text, chatID: message.chatID) {
            return
        }

        if TerminalTelegramRemoteCommand(text: text) == .start {
            await sendTelegramSystemMessage(
                "Telegram is already linked to this mlx-coder session. Send a prompt or /help.",
                to: message.chatID
            )
            return
        }

        queuedPrompts.append(
            TerminalQueuedPrompt(text: text, origin: .telegram(chatID: message.chatID))
        )
        await sendTelegramSystemMessage(
            isGenerating
                ? "Queued for the current mlx-coder session."
                : "Received. mlx-coder is working.",
            to: message.chatID
        )
    }

    func handleTelegramVoiceMessage(
        _ voice: TerminalTelegramVoiceAttachment,
        chatID: Int64,
        eventQueue: TerminalChatEventQueue
    ) async {
        guard isVoiceConfigured() else {
            await sendTelegramSystemMessage(
                "Voice input is not configured. Run mlx-coder --setup and enable voice input.",
                to: chatID
            )
            return
        }

        await sendTelegramSystemMessage("Voice received. Transcribing...", to: chatID)
        Task { [weak self] in
            guard let self else { return }
            do {
                let audio = try await self.telegramControlService.downloadVoiceAudio(voice)
                let transcript = try await AgentVoiceTranscriptionService()
                    .transcribe(audio) { message in
                        await eventQueue.send(
                            .voicePromptProgress(
                                TerminalVoicePromptProgress(
                                    origin: .telegramVoice(chatID: chatID),
                                    message: message
                                )
                            )
                        )
                    }
                await eventQueue.send(
                    .voicePromptCompleted(
                        TerminalVoicePromptResult(
                            origin: .telegramVoice(chatID: chatID),
                            outcome: .success(transcript)
                        )
                    )
                )
            } catch {
                await eventQueue.send(
                    .voicePromptCompleted(
                        TerminalVoicePromptResult(
                            origin: .telegramVoice(chatID: chatID),
                            outcome: .failure(error.localizedDescription)
                        )
                    )
                )
            }
        }
    }

    func writeTelegramSubmittedPrompt(_ prompt: String) {
        let title = telegramLinkedChatTitle?.nilIfBlank ?? "Telegram"
        writeSystemMessage("\n\(title) sent a prompt:\n")
        writeSubmittedPrompt(prompt)
    }

    func startTelegramControl() async {
        guard stdinIsTerminal else {
            writeFailureMessage("mlx-coder: /telegram requires the interactive TUI.\n")
            return
        }
        guard isTelegramConfigured() else {
            writeFailureMessage(Self.unknownCommandMessage(for: "/telegram"))
            return
        }
        guard let settings = AgentSettingsManifestStore.load()?.telegram,
              let linkedChatID = settings.linkedChatID else {
            writeFailureMessage("mlx-coder: Telegram is not paired. Run mlx-coder --setup.\n")
            return
        }

        do {
            telegramLinkedChatID = linkedChatID
            telegramLinkedChatTitle = settings.linkedChatTitle
            telegramControlState = try await telegramControlService.start()
            let chatTitle = telegramLinkedChatTitle?.nilIfBlank ?? "chat \(linkedChatID)"
            writeSystemMessage(
                """
                Telegram remote control is active.
                Linked chat: \(chatTitle)

                """
            )
        } catch {
            telegramControlState.lastError = error.localizedDescription
            writeFailureMessage("mlx-coder: \(error.localizedDescription)\n")
        }
    }

    func stopTelegramControl() async {
        telegramControlState = await telegramControlService.stop()
        telegramLinkedChatID = nil
        telegramLinkedChatTitle = nil
        writeSystemMessage("Telegram remote control stopped.\n")
    }

    func printTelegramStatus() async {
        telegramControlState = await telegramControlService.currentState()
        writeSystemMessage(telegramStatusText() + "\n")
    }

    func telegramToolAuthorizationHandler(
        for origin: TerminalPromptOrigin
    ) -> AgentToolAuthorizationHandler? {
        guard origin.telegramChatID != nil else {
            return nil
        }
        return { [weak self] request in
            guard let self else {
                return false
            }
            return await self.authorizeTelegramToolRequest(request, origin: origin)
        }
    }

    func authorizeTelegramToolRequest(
        _ request: AgentToolAuthorizationRequest,
        origin: TerminalPromptOrigin
    ) async -> Bool {
        guard request.toolName == "local.exec" else {
            return true
        }
        guard let chatID = origin.telegramChatID,
              telegramLinkedChatID == chatID,
              telegramControlState.isActive else {
            return false
        }

        return await telegramPermissionBroker.authorize(request, chatID: chatID) { [weak self] message in
            await self?.sendTelegramSystemMessage(message, to: chatID)
        }
    }

    func handleTelegramPermissionResponseIfNeeded(
        _ text: String,
        chatID: Int64
    ) async -> Bool {
        let result = await telegramPermissionBroker.handleMessage(text, chatID: chatID)
        switch result {
        case .notHandled:
            return false
        case let .handled(reply):
            if let reply = reply?.nilIfBlank {
                await sendTelegramSystemMessage(reply, to: chatID)
            }
            return true
        }
    }

    func sendTelegramCompletionIfLinked(
        _ text: String,
        origin: TerminalPromptOrigin
    ) async {
        await sendTelegramSystemMessageIfLinked(
            "mlx-coder completed\n\n\(Self.truncatedInline(text, limit: 3_600))",
            origin: origin
        )
    }

    func sendTelegramVoiceCompletionIfLinked(
        _ text: String,
        origin: TerminalPromptOrigin
    ) async {
        guard origin.isTelegramVoice,
              let chatID = origin.telegramChatID,
              telegramLinkedChatID == chatID,
              telegramControlState.isActive else {
            return
        }
        guard AgentVoiceSynthesisService.isSupported else {
            await sendTelegramCompletionIfLinked(text, origin: origin)
            return
        }

        do {
            let spokenText = AgentVoiceSpokenTextFormatter.prepare(text)
            if spokenText.isShortened {
                await sendTelegramSystemMessage(
                    "Voice: speaking a shortened reply for faster playback.",
                    to: chatID
                )
            }
            let audio = try await AgentVoiceSynthesisService()
                .synthesize(spokenText.text) { message in
                    await self.sendTelegramSystemMessage("Voice: \(message)", to: chatID)
                }
            defer {
                audio.cleanup()
            }
            telegramControlState = try await telegramControlService.sendAudio(audio, to: chatID)
        } catch {
            telegramControlState.lastError = error.localizedDescription
            writeFailureMessage("mlx-coder: \(error.localizedDescription)\n")
            await sendTelegramSystemMessage(
                "Voice reply failed: \(error.localizedDescription)",
                to: chatID
            )
        }
    }

    func sendTelegramSystemMessageIfLinked(_ message: String) async {
        guard let chatID = telegramLinkedChatID,
              telegramControlState.isActive else {
            return
        }
        await sendTelegramSystemMessage(message, to: chatID)
    }

    func sendTelegramSystemMessageIfLinked(
        _ message: String,
        origin: TerminalPromptOrigin
    ) async {
        guard let chatID = origin.telegramChatID,
              telegramLinkedChatID == chatID,
              telegramControlState.isActive else {
            return
        }
        await sendTelegramSystemMessage(message, to: chatID)
    }

    func sendTelegramSystemMessage(_ message: String, to chatID: Int64) async {
        do {
            telegramControlState = try await telegramControlService.sendMessage(message, to: chatID)
        } catch {
            telegramControlState.lastError = error.localizedDescription
            writeFailureMessage("mlx-coder: \(error.localizedDescription)\n")
        }
    }

    private func telegramStatusText() -> String {
        var lines = [
            "Telegram: \(telegramControlState.statusText)"
        ]
        if let botUsername = telegramControlState.botUsername?.nilIfBlank {
            lines.append("Bot: @\(botUsername)")
        }
        if let title = telegramLinkedChatTitle?.nilIfBlank {
            lines.append("Linked chat: \(title)")
        }
        if let error = telegramControlState.lastError?.nilIfBlank {
            lines.append("Last error: \(error)")
        }
        return lines.joined(separator: "\n")
    }

    private func telegramRemoteStatusText() -> String {
        let agent = selectedAgent?.displayName ?? "Default"
        let model = currentEffectiveModelID() ?? "default model"
        return "Session active.\nAgent: \(agent)\nModel: \(model)\nWorking directory: \(configuration.workingDirectory.path)"
    }

    private func telegramRemoteChangesText() -> String {
        guard let summary = lastFileChangeSummary else {
            return "No tracked file changes."
        }
        let title = summary.fileCount == 1
            ? "1 modified file"
            : "\(summary.fileCount) modified files"
        let entries = summary.entries
            .map(Self.renderFileChangeEntry)
            .joined(separator: "\n")
        return "\(title)  +\(summary.totalAdditions) -\(summary.totalDeletions)\n\(entries)"
    }

    private func telegramRemoteHelpText() -> String {
        """
        Send a message to prompt the current mlx-coder TUI session.
        Remote commands: /status, /changes, /retry, /help.
        Permission replies: /allow ID, /always ID, /deny ID.
        Turn Telegram off from the TUI with /telegram off.
        """
    }

    func makeTelegramTurnProgressReporter(
        for origin: TerminalPromptOrigin
    ) -> TerminalTelegramTurnProgressReporter? {
        guard let chatID = origin.telegramChatID,
              telegramLinkedChatID == chatID,
              telegramControlState.isActive else {
            return nil
        }

        return TerminalTelegramTurnProgressReporter(chatID: chatID) { [weak self] message, chatID in
            await self?.sendTelegramSystemMessage(message, to: chatID)
        }
    }

    func telegramTurnStartedMessage(prompt: String) -> String {
        var lines = [
            "mlx-coder started",
            "Agent: \(selectedAgent?.displayName ?? "Default")"
        ]
        if let modelID = currentEffectiveModelID()?.nilIfBlank {
            lines.append("Model: \(modelID)")
        }
        if let promptPreview = prompt.nilIfBlank {
            lines.append("Prompt: \(Self.truncatedInline(promptPreview, limit: 700))")
        }
        return lines.joined(separator: "\n")
    }

    func telegramStatusProgressMessage(_ message: String) -> String? {
        guard let text = message.nilIfBlank else {
            return nil
        }
        return "Status\n\(Self.truncatedInline(compactGenerationSummary(text), limit: 900))"
    }

    func telegramDiagnosticProgressMessage(_ message: String) -> String? {
        guard let text = message.nilIfBlank else {
            return nil
        }
        return "Diagnostic\n\(Self.truncatedInline(text, limit: 900))"
    }

    func telegramModelLoadedMessage(modelID: String) -> String {
        "Model loaded\n\(Self.truncatedInline(modelID, limit: 900))"
    }

    func telegramToolStartedMessage(_ toolCall: DirectAgentToolCall) -> String {
        var lines = [
            "Tool started",
            MLXCoderACPBridge.toolTitle(for: toolCall)
        ]
        if let target = MLXCoderACPBridge.displayToolTarget(for: toolCall)?.nilIfBlank {
            lines.append("Target: \(target)")
        }
        return lines.joined(separator: "\n")
    }

    func telegramToolCompletedMessage(
        _ toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) -> String {
        let failed = result.output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("Tool error:")
        var lines = [
            failed ? "Tool failed" : "Tool completed",
            MLXCoderACPBridge.toolTitle(for: toolCall)
        ]
        if let summary = toolCompletionSummary(toolCall: toolCall, result: result).nilIfBlank {
            lines.append("Summary: \(Self.truncatedInline(summary, limit: 900))")
        }
        return lines.joined(separator: "\n")
    }

    func telegramFileChangeSummaryMessage(_ summary: TurnFileChangeSummary) -> String {
        let title = summary.fileCount == 1
            ? "1 modified file"
            : "\(summary.fileCount) modified files"
        var lines = [
            "File changes",
            "\(title)  +\(summary.totalAdditions) -\(summary.totalDeletions)"
        ]
        let visibleEntries = summary.entries.prefix(12).map(Self.renderFileChangeEntry)
        lines.append(contentsOf: visibleEntries)
        if summary.entries.count > visibleEntries.count {
            lines.append("... \(summary.entries.count - visibleEntries.count) more")
        }
        lines.append(summary.canUndo ? "Use /undo in the TUI to revert." : "Undo is not available.")
        return lines.joined(separator: "\n")
    }

}

actor TerminalTelegramTurnProgressReporter {
    private let chatID: Int64
    private let sendMessage: @Sendable (String, Int64) async -> Void
    private var queue: [String] = []
    private var isDraining = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var statusMessageCount = 0
    private var didSendThinking = false
    private var didSendWriting = false

    init(
        chatID: Int64,
        sendMessage: @escaping @Sendable (String, Int64) async -> Void
    ) {
        self.chatID = chatID
        self.sendMessage = sendMessage
    }

    func enqueue(_ message: String) {
        guard let text = message.nilIfBlank else {
            return
        }
        queue.append(String(text.prefix(3_900)))
        startDrainingIfNeeded()
    }

    func enqueueStatus(_ message: String) {
        guard statusMessageCount < 6 else {
            return
        }
        statusMessageCount += 1
        enqueue(message)
    }

    func enqueueThinkingIfNeeded() {
        guard !didSendThinking else {
            return
        }
        didSendThinking = true
        enqueue("Thinking...")
    }

    func enqueueWritingIfNeeded() {
        guard !didSendWriting else {
            return
        }
        didSendWriting = true
        enqueue("Writing response...")
    }

    func flush() async {
        guard isDraining || !queue.isEmpty else {
            return
        }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    private func startDrainingIfNeeded() {
        guard !isDraining else {
            return
        }
        isDraining = true
        Task {
            await drain()
        }
    }

    private func drain() async {
        while let message = nextMessage() {
            await sendMessage(message, chatID)
        }
    }

    private func nextMessage() -> String? {
        guard !queue.isEmpty else {
            isDraining = false
            let waiters = idleWaiters
            idleWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            return nil
        }
        return queue.removeFirst()
    }
}

enum TerminalTelegramCommandAction: Equatable {
    case status
    case turnOn
    case turnOff
    case usage

    init(argument: String) {
        switch argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "":
            self = .status
        case "on":
            self = .turnOn
        case "off":
            self = .turnOff
        default:
            self = .usage
        }
    }
}

enum TerminalTelegramRemoteCommand: Equatable {
    case start
    case help
    case status
    case changes
    case retry
    case undo

    init?(text: String) {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let command = normalized
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? normalized
        switch normalized {
        case "/help", "help":
            self = .help
        case "/status", "status", "stato":
            self = .status
        case "/changes", "changes", "modifiche":
            self = .changes
        case "/retry", "retry", "riprova":
            self = .retry
        case "/undo", "undo", "undo changes", "annulla", "annulla modifiche":
            self = .undo
        default:
            if command == "/start" || command.hasPrefix("/start@") {
                self = .start
                return
            }
            return nil
        }
    }
}
