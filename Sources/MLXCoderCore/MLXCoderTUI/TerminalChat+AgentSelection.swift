//
//  TerminalChat+AgentSelection.swift
//  mlx-coder
//
//  Created by Codex on 09/05/26.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

extension TerminalChat {
    public func handleAgentsCommand(_ command: String) async throws {
        let rawArguments = String(command.dropFirst("/agents".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if rawArguments.isEmpty {
            guard stdinIsTerminal else {
                printAgentSelectionStatus()
                renderAgentList(agents: try availableAgents())
                writeSystemMessage(Self.renderAgentSelectionUsage())
                return
            }

            let selectedAgent = TerminalCheckboxMenu.selectOne(
                title: "Agent profiles",
                items: try agentSelectionItems(),
                selected: selectedAgent,
                reservedBottomRows: statusBar.reservedRowsForOverlay()
            )
            if let selectedAgent {
                try await applyAgentSelection(selectedAgent)
            } else {
                printAgentSelectionStatus()
            }
            return
        }

        switch rawArguments.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "list", "ls", "status":
            printAgentSelectionStatus()
            renderAgentList(agents: try availableAgents())
            return
        default:
            break
        }

        let agent = try parseAgentSelection(
            rawArguments,
            availableAgents: try availableAgents()
        )
        try await applyAgentSelection(agent)
    }

    public func applyAgentSelection(_ agent: AgentProfile) async throws {
        selectedAgent = agent
        applyAgentProfile(agent)
        activeSessionSystemPromptOverride = nil
        manualModelIDOverride = configuration.hostedModels == nil
            ? nil
            : configuration.modelID
        manualThinkingSelectionOverride = nil
        await ensureWorkspaceAccessIfNeeded()

        await sessionRunner.shutdown()
        printedModelID = nil
        didPrintActiveTools = false
        statusBar.reset()
        try await createCurrentSession()
        refreshInitialStatusBarContextWindow()
        _ = try await preloadCurrentModel()
        await printActiveToolsIfNeeded()
        writeSystemMessage("Switched to agent: \(agent.displayName). Session reset.\n")
    }

    public func applyAgentProfile(_ agent: AgentProfile) {
        selectedToolGroups = Set(
            agent.tools.compactMap { TerminalToolGroup.group(named: $0) }
        )
        selectedSkillIDs = agent.selectedSkillIDs(
            availableSkills: availableSkills()
        )
    }

    public func availableAgents() throws -> [AgentProfile] {
        if let hostedAgentProfiles = configuration.hostedAgentProfiles {
            return hostedAgentProfiles
        }
        return try AgentProfileStore.loadRequired()
    }

    public func agentSelectionItems() throws -> [TerminalCheckboxMenuItem<AgentProfile>] {
        try availableAgents().map { agent in
            TerminalCheckboxMenuItem(
                value: agent,
                title: agent.displayName,
                detail: agentSelectionDetail(agent)
            )
        }
    }

    public func parseAgentSelection(
        _ rawSelection: String,
        availableAgents: [AgentProfile]
    ) throws -> AgentProfile {
        let token = rawSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedToken = Self.agentSelectionKey(token)
        guard !normalizedToken.isEmpty else {
            throw TerminalAgentSelectionError.unknownAgent(token)
        }

        if let index = Int(token),
           availableAgents.indices.contains(index - 1) {
            return availableAgents[index - 1]
        }

        if let agent = availableAgents.first(where: {
            Self.agentSelectionKey($0.id) == normalizedToken
                || Self.agentSelectionKey($0.name) == normalizedToken
        }) {
            return agent
        }

        throw TerminalAgentSelectionError.unknownAgent(token)
    }

    public func printAgentSelectionStatus() {
        writeSystemMessage(Self.renderSelectedAgent(selectedAgent))
    }

    public func renderAgentList(agents: [AgentProfile]) {
        guard !agents.isEmpty else {
            writeSystemMessage(
                "No agents configured in \(AgentProfileStore.agentsManifestURL().path).\n"
            )
            return
        }

        writeSystemMessage("\nAvailable agents:\n")
        for (offset, agent) in agents.enumerated() {
            let marker = selectedAgent == agent ? " *" : ""
            let detail = agentSelectionDetail(agent)
            writeSystemMessage(
                "  \(offset + 1). \(agent.displayName) - \(detail)\(marker)\n"
            )
        }
        writeSystemMessage("\n")
    }

    public func agentSelectionDetail(_ agent: AgentProfile) -> String {
        var parts: [String] = []
        if let modelID = agent.modelID {
            parts.append(modelID)
        } else {
            parts.append("default model")
        }
        if !agent.tools.isEmpty {
            parts.append("tools: \(agent.tools.joined(separator: ", "))")
        } else {
            parts.append("tools: none")
        }
        if !agent.skills.isEmpty {
            parts.append("skills: \(agent.skills.count)")
        }
        return parts.joined(separator: " · ")
    }

    public static func renderSelectedAgent(_ agent: AgentProfile?) -> String {
        guard let agent else {
            return "Selected agent: unavailable\n"
        }
        return "Selected agent: \(agent.displayName)\n"
    }

    public static func renderAgentSelectionUsage() -> String {
        "Usage: /agents [list|<agent name>|<number>]\n"
    }

    public static func agentSelectionKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

public enum TerminalAgentSelectionError: LocalizedError {
    case unknownAgent(String)

    public var errorDescription: String? {
        switch self {
        case let .unknownAgent(name):
            return "Unknown agent '\(name)'."
        }
    }
}
