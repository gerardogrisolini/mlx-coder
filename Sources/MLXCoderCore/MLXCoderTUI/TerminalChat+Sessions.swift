//
//  TerminalChat+Sessions.swift
//  mlx-coder
//

import Foundation

extension TerminalChat {
    public func handleSessionsCommand(_ command: String) async {
        let rawArguments = String(command.dropFirst("/sessions".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rawArguments.isEmpty else {
            await handleSavedSessionList()
            return
        }

        if rawArguments.lowercased() == "delete" {
            await handleSavedSessionDelete()
            return
        }

        await saveCurrentSession(named: rawArguments)
    }

    public func handleSavedSessionList() async {
        do {
            let sessions = try MLXTerminalSessionStore.savedSessions(
                for: configuration.workingDirectory
            )
            guard !sessions.isEmpty else {
                writeSystemMessage("No saved sessions for this project.\n")
                writeSystemMessage(Self.renderSessionSelectionUsage())
                return
            }

            guard stdinIsTerminal else {
                renderSavedSessionList(sessions)
                writeSystemMessage(Self.renderSessionSelectionUsage())
                return
            }

            let items = savedSessionSelectionItems(sessions)
            guard let selectedName = TerminalCheckboxMenu.selectOne(
                title: "Saved sessions",
                items: items,
                selected: activeSavedSessionName,
                reservedBottomRows: statusBar.reservedRowsForOverlay()
            ),
                  let selectedSession = sessions.first(where: { $0.name == selectedName }) else {
                renderSavedSessionList(sessions)
                return
            }

            try await loadSavedSession(selectedSession)
        } catch {
            writeFailureMessage("mlx-coder: \(error.localizedDescription)\n")
        }
    }

    public func handleSavedSessionDelete() async {
        do {
            let sessions = try MLXTerminalSessionStore.savedSessions(
                for: configuration.workingDirectory
            )
            guard !sessions.isEmpty else {
                writeSystemMessage("No saved sessions for this project.\n")
                return
            }

            guard stdinIsTerminal else {
                renderSavedSessionList(sessions)
                writeSystemMessage(Self.renderSessionSelectionUsage())
                return
            }

            let items = savedSessionSelectionItems(sessions)
            guard let selectedName = TerminalCheckboxMenu.selectOne(
                title: "Delete saved session",
                items: items,
                selected: activeSavedSessionName,
                reservedBottomRows: statusBar.reservedRowsForOverlay()
            ),
                  let selectedSession = sessions.first(where: { $0.name == selectedName }) else {
                return
            }

            guard promptSavedSessionDeleteConfirmation(selectedSession.name) else {
                writeSystemMessage("Session delete cancelled.\n")
                return
            }

            let didDelete = try MLXTerminalSessionStore.delete(
                name: selectedSession.name,
                workingDirectory: configuration.workingDirectory
            )
            if activeSavedSessionName == selectedSession.name {
                activeSavedSessionName = nil
            }
            if didDelete {
                writeSystemMessage("Deleted session: \(selectedSession.name).\n")
            } else {
                writeFailureMessage("mlx-coder: saved session not found: \(selectedSession.name).\n")
            }
        } catch {
            writeFailureMessage("mlx-coder: \(error.localizedDescription)\n")
        }
    }

    public func saveCurrentSession(named rawName: String) async {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            writeSystemMessage(Self.renderSessionSelectionUsage())
            return
        }

        guard let snapshot = await sessionRunner.snapshotSession(id: sessionID) else {
            writeFailureMessage("mlx-coder: current session is not available to save.\n")
            return
        }

        let existingSession = try? MLXTerminalSessionStore.load(
            name: name,
            workingDirectory: configuration.workingDirectory
        )
        let now = Date()
        let savedSession = MLXTerminalSavedSession(
            name: name,
            sessionID: snapshot.sessionID,
            cacheKey: snapshot.cacheKey
                ?? activeSessionCacheKey
                ?? Self.savedSessionCacheKey(
                    name: name,
                    workingDirectory: configuration.workingDirectory
                ),
            workingDirectoryPath: configuration.workingDirectory.path,
            createdAt: existingSession?.createdAt ?? now,
            savedAt: now,
            modelID: currentEffectiveModelID(),
            agentID: selectedAgent?.id,
            agentName: selectedAgent?.name,
            selectedTools: Self.selectedToolSelectionNames(selectedToolKeys),
            selectedSkillIDs: selectedSkillIDs.sorted(),
            thinkingSelection: currentAgentThinkingSelection()?.rawValue,
            contextWindow: statusBar.currentContextWindowStatus().map {
                MLXTerminalSavedSessionContextWindow($0)
            },
            systemPrompt: snapshot.systemPrompt,
            history: snapshot.history,
            transcriptHistory: activeSessionTranscript
        )

        do {
            _ = try MLXTerminalSessionStore.save(savedSession)
            recordSavedSessionIndex(savedSession)
            activeSavedSessionName = savedSession.name
            writeSystemMessage(
                "Saved session: \(savedSession.name) (\(savedSession.messageCount) messages).\n"
            )
        } catch {
            writeFailureMessage("mlx-coder: \(error.localizedDescription)\n")
        }
    }

    public func recordSavedSessionIndex(_ savedSession: MLXTerminalSavedSession) {
        do {
            try MLXMemoryService().recordSavedSessionIndexEntry(
                projectPath: savedSession.workingDirectoryPath,
                sessionName: savedSession.name,
                sessionID: savedSession.sessionID,
                savedAt: savedSession.savedAt
            )
        } catch {
            SwiftMLXLogger.warning(
                .memory,
                "failed to update global saved-session memory index for \(savedSession.name): \(error.localizedDescription)"
            )
        }
    }

    public func loadSavedSession(_ savedSession: MLXTerminalSavedSession) async throws {
        await sessionRunner.resetSession(id: sessionID)
        sessionID = savedSession.sessionID
        activeSessionCacheKey = savedSession.cacheKey
        activeSessionHistory = savedSession.history
        activeSessionTranscript = Self.savedSessionDisplayHistory(savedSession)
        activeSessionSystemPromptOverride = savedSession.systemPrompt
        activeSavedSessionName = savedSession.name
        manualModelIDOverride = savedSession.modelID ?? configuration.modelID
        manualThinkingSelectionOverride = savedSession.thinkingSelection.flatMap {
            AgentThinkingSelection(rawValue: $0)
        }

        if let agent = try restoredAgent(for: savedSession) {
            selectedAgent = agent
        } else {
            selectedAgent = nil
        }
        let items = await toolSelectionItems()
        selectedToolKeys = Self.toolSelectionKeys(
            from: savedSession.selectedTools,
            items: items
        )
        selectedSkillIDs = Set(savedSession.selectedSkillIDs)

        await ensureWorkspaceAccessIfNeeded()
        pendingAttachments.removeAll()
        lastFileChangeSummary = nil
        isSubAgentOverviewVisible = false
        lastRenderedSubAgentOverviewSignature = nil
        stopSubAgentOverviewRefreshLoop()
        didPrintActiveTools = false
        printedModelID = nil
        statusBar.reset()

        try await createCurrentSession()
        refreshInitialStatusBarContextWindow()
        _ = try await preloadCurrentModel(emitStatus: configuration.hostedModels != nil)
        if let contextWindow = savedSession.contextWindow?.runtimeStatus {
            _ = statusBar.update(contextWindow: contextWindow)
        }
        await printActiveToolsIfNeeded()
        renderSavedSessionHistory(activeSessionTranscript)
        writeSystemMessage(
            "Loaded session: \(savedSession.name) (\(savedSession.messageCount) messages).\n"
        )
    }

    public func renderSavedSessionHistory(_ history: [AgentRuntimeMessage]) {
        guard Self.savedSessionHistoryHasVisibleContent(history) else {
            return
        }

        finishThoughtOutputIfNeeded()
        finishAssistantContentFormatting()
        writeSystemMessage("\nRestored transcript:\n")
        var renderedToolResultIDs = Set<String>()
        for message in history {
            switch message.role {
            case .user:
                renderSavedUserMessage(message)
            case .assistant:
                renderSavedAssistantMessage(
                    message,
                    history: history,
                    renderedToolResultIDs: &renderedToolResultIDs
                )
            case .tool:
                renderSavedUnmatchedToolResultIfNeeded(
                    message,
                    renderedToolResultIDs: &renderedToolResultIDs
                )
            case .system:
                continue
            }
        }
        finishThoughtOutputIfNeeded()
        finishAssistantContentFormatting()
        writeChatOutput("\n")
    }

    private func renderSavedUserMessage(_ message: AgentRuntimeMessage) {
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            return
        }
        writeSubmittedPrompt(content)
    }

    private func renderSavedAssistantMessage(
        _ message: AgentRuntimeMessage,
        history: [AgentRuntimeMessage],
        renderedToolResultIDs: inout Set<String>
    ) {
        if let reasoning = message.reasoningContent?.nilIfBlank {
            writeThought(reasoning)
            finishThoughtOutputIfNeeded()
        }

        let content = message.content.trimmingCharacters(in: .newlines)
        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            writeAssistantContent(content)
            finishAssistantContentFormatting()
            writeChatOutput("\n")
        }

        for toolCall in message.toolCalls {
            let directToolCall = Self.directToolCall(from: toolCall)
            if let toolResult = Self.toolResult(
                for: toolCall,
                in: history,
                renderedToolResultIDs: &renderedToolResultIDs
            ) {
                writeToolCallCompleted(directToolCall, result: toolResult)
            } else {
                writeToolCallStarted(directToolCall)
            }
        }
    }

    private func renderSavedUnmatchedToolResultIfNeeded(
        _ message: AgentRuntimeMessage,
        renderedToolResultIDs: inout Set<String>
    ) {
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            return
        }
        let toolCallID = message.toolCallID ?? "restored-tool-\(UUID().uuidString.lowercased())"
        guard renderedToolResultIDs.insert(toolCallID).inserted else {
            return
        }

        let toolCall = DirectAgentToolCall(
            id: toolCallID,
            name: message.toolName ?? "tool.result",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )
        writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(
                output: content,
                summary: Self.savedToolResultSummary(content)
            )
        )
    }

    private static func savedSessionHistoryHasVisibleContent(
        _ history: [AgentRuntimeMessage]
    ) -> Bool {
        history.contains { message in
            switch message.role {
            case .user, .tool:
                return message.content.nilIfBlank != nil
            case .assistant:
                return message.content.nilIfBlank != nil
                    || message.reasoningContent?.nilIfBlank != nil
                    || !message.toolCalls.isEmpty
            case .system:
                return false
            }
        }
    }

    private static func directToolCall(
        from toolCall: AgentRuntimeToolCall
    ) -> DirectAgentToolCall {
        DirectAgentToolCall(
            id: toolCall.id ?? "restored-tool-\(UUID().uuidString.lowercased())",
            name: toolCall.name,
            argumentsObject: [:],
            argumentsJSON: toolCall.argumentsJSON
        )
    }

    private static func toolResult(
        for toolCall: AgentRuntimeToolCall,
        in history: [AgentRuntimeMessage],
        renderedToolResultIDs: inout Set<String>
    ) -> DirectAgentToolResult? {
        guard let toolCallID = toolCall.id else {
            return nil
        }
        guard let message = history.first(where: {
            $0.role == .tool && $0.toolCallID == toolCallID
        }) else {
            return nil
        }
        guard renderedToolResultIDs.insert(toolCallID).inserted else {
            return nil
        }
        return DirectAgentToolResult(
            output: message.content,
            summary: savedToolResultSummary(message.content)
        )
    }

    private static func savedToolResultSummary(_ output: String) -> String {
        output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank ?? "restored tool output"
    }

    public static func savedSessionDisplayHistory(
        _ savedSession: MLXTerminalSavedSession
    ) -> [AgentRuntimeMessage] {
        if let transcriptHistory = savedSession.transcriptHistory {
            return transcriptHistory
        }

        guard let compactedSummary = compactionSummaryDisplayText(
            from: savedSession.systemPrompt
        ) else {
            return savedSession.history
        }

        return [
            AgentRuntimeMessage(
                role: .assistant,
                content: compactedSummary
            )
        ] + savedSession.history
    }

    private static func compactionSummaryDisplayText(
        from systemPrompt: String?
    ) -> String? {
        guard let systemPrompt,
              let summaryRange = systemPrompt.range(
                of: AgentConversationCompactionSupport.memorySummaryHeader
              ) else {
            return nil
        }
        let summary = String(systemPrompt[summaryRange.lowerBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            return nil
        }
        return """
        Restored compacted context:

        \(summary)
        """
    }

    private func promptSavedSessionDeleteConfirmation(_ name: String) -> Bool {
        while true {
            guard let line = interactiveReader.readLine(
                prompt: "Delete session \"\(name)\"? [y/N]: "
            ) else {
                return false
            }

            switch line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "":
                return false
            case "y", "yes", "true", "1":
                return true
            case "n", "no", "false", "0":
                return false
            default:
                writeFailureMessage("mlx-coder: answer yes or no.\n")
            }
        }
    }

    public func renderSavedSessionList(_ sessions: [MLXTerminalSavedSession]) {
        writeSystemMessage("\nSaved sessions:\n")
        for (offset, session) in sessions.enumerated() {
            let marker = activeSavedSessionName == session.name ? " *" : ""
            writeSystemMessage(
                "  \(offset + 1). \(session.name) - \(savedSessionDetail(session))\(marker)\n"
            )
        }
        writeSystemMessage("\n")
    }

    public func savedSessionSelectionItems(
        _ sessions: [MLXTerminalSavedSession]
    ) -> [TerminalCheckboxMenuItem<String>] {
        sessions.map { session in
            TerminalCheckboxMenuItem(
                value: session.name,
                title: session.name,
                detail: savedSessionDetail(session)
            )
        }
    }

    public func savedSessionDetail(_ session: MLXTerminalSavedSession) -> String {
        var parts: [String] = []
        if let modelID = session.modelID {
            parts.append(modelID)
        }
        parts.append("\(session.messageCount) messages")
        if let usedTokens = session.contextWindow?.usedTokens {
            parts.append("ctx \(Self.savedSessionTokenCountText(usedTokens))")
        }
        parts.append("saved \(Self.savedSessionTimestamp(session.savedAt))")
        return parts.joined(separator: " · ")
    }

    public func restoredAgent(
        for savedSession: MLXTerminalSavedSession
    ) throws -> AgentProfile? {
        guard savedSession.agentID != nil || savedSession.agentName != nil else {
            return nil
        }
        let agents = try availableAgents()
        if let agentID = savedSession.agentID,
           let agent = agents.first(where: { $0.id == agentID }) {
            return agent
        }
        if let agentName = savedSession.agentName {
            let key = Self.agentSelectionKey(agentName)
            return agents.first { Self.agentSelectionKey($0.name) == key }
        }
        return nil
    }

    public static func renderSessionSelectionUsage() -> String {
        "Usage: /sessions [session name]\n       /sessions delete\n"
    }

    public static func selectedToolSelectionNames(
        _ selectedToolKeys: Set<String>
    ) -> [String] {
        selectedToolKeys.sorted()
    }

    public static func savedSessionCacheKey(
        name: String,
        workingDirectory: URL
    ) -> String {
        let stem = MLXTerminalSessionStore.filenameStem(for: name)
        return "\(AgentKVCachePersistencePolicy.terminalDiskCacheKey(workingDirectoryPath: workingDirectory.path)):session:\(stem)"
    }

    public static func savedSessionTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    public static func savedSessionTokenCountText(_ value: Int) -> String {
        let absoluteValue = abs(value)
        if absoluteValue >= 1_048_576 {
            return String(format: "%.1fm", Double(value) / 1_048_576)
        }
        if absoluteValue >= 1_024 {
            return String(format: "%.1fk", Double(value) / 1_024)
        }
        return "\(value)"
    }
}
