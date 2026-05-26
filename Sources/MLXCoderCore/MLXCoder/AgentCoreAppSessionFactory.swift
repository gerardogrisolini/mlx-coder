//
//  AgentCoreAppSessionFactory.swift
//  mlx-coder
//

import Foundation

public struct AgentCoreAppSessionRequest: Sendable {
    public let sessionID: String
    public let modelID: String?
    public let agentName: String?
    public let bearerToken: String?
    public let workingDirectory: URL
    public let systemPrompt: String?
    public let cacheKey: String?
    public let history: [AgentRuntimeMessage]
    public let allowedToolNames: Set<String>?
    public let maxToolRounds: Int
    public let maxOutputTokens: Int?
    public let verboseLogging: Bool
    public let thinkingSelection: AgentThinkingSelection?
    public let preserveThinking: Bool

    public init(
        sessionID: String,
        modelID: String? = nil,
        agentName: String? = nil,
        bearerToken: String? = nil,
        workingDirectory: URL,
        systemPrompt: String? = nil,
        cacheKey: String? = nil,
        history: [AgentRuntimeMessage] = [],
        allowedToolNames: Set<String>? = nil,
        maxToolRounds: Int = 100,
        maxOutputTokens: Int? = nil,
        verboseLogging: Bool = false,
        thinkingSelection: AgentThinkingSelection? = nil,
        preserveThinking: Bool = false
    ) {
        self.sessionID = sessionID
        self.modelID = modelID
        self.agentName = agentName
        self.bearerToken = bearerToken
        self.workingDirectory = workingDirectory
        self.systemPrompt = systemPrompt
        self.cacheKey = cacheKey
        self.history = history
        self.allowedToolNames = allowedToolNames
        self.maxToolRounds = maxToolRounds
        self.maxOutputTokens = maxOutputTokens
        self.verboseLogging = verboseLogging
        self.thinkingSelection = thinkingSelection
        self.preserveThinking = preserveThinking
    }
}

public enum AgentCoreAppSessionFactory {
    public static func makeConfiguration(
        request: AgentCoreAppSessionRequest
    ) throws -> AgentCoreSessionConfiguration {
        let agentConfiguration = try resolvedAgentConfiguration(for: request)
        let allowedToolNames = request.allowedToolNames
            ?? agentConfiguration.selectedAgent?.allowedToolNames()
        let effectiveModelID = agentConfiguration.effectiveModelID
        let systemPrompt = resolvedSystemPrompt(
            providedSystemPrompt: request.systemPrompt,
            cwd: request.workingDirectory.path,
            selectedAgent: agentConfiguration.selectedAgent,
            allowedToolNames: allowedToolNames
        )
        let thinkingSelection = request.thinkingSelection
            ?? AgentSettingsStore.defaultSelection(
                explicitModelID: effectiveModelID
            )?.thinkingSelection

        return AgentCoreSessionConfiguration(
            sessionID: request.sessionID,
            modelID: effectiveModelID,
            bearerToken: request.bearerToken ?? agentConfiguration.bearerToken,
            workingDirectory: request.workingDirectory,
            systemPrompt: systemPrompt,
            cacheKey: request.cacheKey,
            history: request.history,
            allowedToolNames: allowedToolNames,
            maxToolRounds: request.maxToolRounds,
            maxOutputTokens: request.maxOutputTokens,
            verboseLogging: request.verboseLogging,
            appMode: true,
            thinkingSelection: thinkingSelection,
            preserveThinking: request.preserveThinking
        )
    }

    public static func resolvedSystemPrompt(
        providedSystemPrompt: String?,
        cwd: String,
        selectedAgent: AgentProfile?,
        allowedToolNames: Set<String>?
    ) -> String {
        let selectedAgentSection = selectedAgent?.promptSection
        let selectedSkillSection = selectedAgentSkillSection(for: selectedAgent)
        let providedSystemPrompt = providedSystemPrompt?.nilIfBlank

        if let providedSystemPrompt {
            return [selectedAgentSection, selectedSkillSection, providedSystemPrompt]
                .compactMap { $0?.nilIfBlank }
                .joined(separator: "\n\n")
        }

        return AgentStandaloneSystemPrompt.prompt(
            cwd: cwd,
            memoryToolEnabled: memoryToolEnabled(allowedToolNames),
            selectedAgentSection: selectedAgentSection,
            selectedSkillSection: selectedSkillSection
        )
    }

    public static func memoryToolEnabled(_ allowedToolNames: Set<String>?) -> Bool {
        guard let allowedToolNames else {
            return true
        }
        return allowedToolNames.contains { $0.hasPrefix("memory.") }
    }

    private static func resolvedAgentConfiguration(
        for request: AgentCoreAppSessionRequest
    ) throws -> AgentConfiguration {
        var arguments = [
            "mlx-coder",
            "--app",
            "--cwd",
            request.workingDirectory.path,
            "--max-tool-rounds",
            "\(max(1, request.maxToolRounds))"
        ]

        if let modelID = request.modelID?.nilIfBlank {
            arguments.append(contentsOf: ["--model", modelID])
        }
        if let agentName = request.agentName?.nilIfBlank {
            arguments.append(contentsOf: ["--agent", agentName])
        }
        if let bearerToken = request.bearerToken?.nilIfBlank {
            arguments.append(contentsOf: ["--bearer-token", bearerToken])
        }
        if let maxOutputTokens = request.maxOutputTokens {
            arguments.append(contentsOf: ["--max-output-tokens", "\(max(1, maxOutputTokens))"])
        }
        if request.verboseLogging {
            arguments.append("--verbose")
        }

        return try AgentConfiguration(arguments: arguments)
    }

    private static func selectedAgentSkillSection(for selectedAgent: AgentProfile?) -> String? {
        guard let selectedAgent,
              !selectedAgent.skills.isEmpty else {
            return nil
        }

        let availableSkills = MLXPromptSkillCatalog.discoverSkills(
            searchRoots: MLXPromptSkillCatalog.appCatalogSearchRoots()
        )
        let selectedSkillIDs = selectedAgent.selectedSkillIDs(
            availableSkills: availableSkills
        )
        let selectedSkills = availableSkills.filter { selectedSkillIDs.contains($0.id) }
        return MLXSystemPromptBuilder.selectedSkillSection(skills: selectedSkills)
    }
}
