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
            systemPrompt: snapshot.systemPrompt,
            history: snapshot.history
        )

        do {
            _ = try MLXTerminalSessionStore.save(savedSession)
            activeSavedSessionName = savedSession.name
            writeSystemMessage(
                "Saved session: \(savedSession.name) (\(savedSession.messageCount) messages).\n"
            )
        } catch {
            writeFailureMessage("mlx-coder: \(error.localizedDescription)\n")
        }
    }

    public func loadSavedSession(_ savedSession: MLXTerminalSavedSession) async throws {
        await sessionRunner.resetSession(id: sessionID)
        sessionID = savedSession.sessionID
        activeSessionCacheKey = savedSession.cacheKey
        activeSessionHistory = savedSession.history
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
        await printActiveToolsIfNeeded()
        writeSystemMessage(
            "Loaded session: \(savedSession.name) (\(savedSession.messageCount) messages).\n"
        )
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
        "Usage: /sessions [session name]\n"
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
}
