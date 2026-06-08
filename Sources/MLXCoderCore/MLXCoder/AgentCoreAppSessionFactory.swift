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
    public let selectedToolKeys: Set<String>?
    public let selectedSkillIDs: Set<String>
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
        selectedToolKeys: Set<String>? = nil,
        selectedSkillIDs: Set<String> = [],
        maxToolRounds: Int = AgentToolRoundPolicy.defaultMaxToolRounds,
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
        self.selectedToolKeys = selectedToolKeys
        self.selectedSkillIDs = selectedSkillIDs
        self.maxToolRounds = AgentToolRoundPolicy.normalizedMaxToolRounds(maxToolRounds)
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
        let allowedToolNames = resolvedAllowedToolNames(
            selectedToolKeys: request.selectedToolKeys,
            explicitAllowedToolNames: request.allowedToolNames,
            selectedAgent: agentConfiguration.selectedAgent
        )
        let effectiveModelID = agentConfiguration.effectiveModelID
        let systemPrompt = resolvedSystemPrompt(
            providedSystemPrompt: request.systemPrompt,
            cwd: request.workingDirectory.path,
            selectedAgent: agentConfiguration.selectedAgent,
            allowedToolNames: allowedToolNames,
            selectedSkillIDs: request.selectedSkillIDs
        )
        let thinkingSelection = resolvedThinkingSelection(
            request.thinkingSelection,
            modelID: effectiveModelID
        )
        let cacheKey = scopedCacheKey(
            request.cacheKey,
            sessionID: request.sessionID,
            modelID: effectiveModelID,
            workingDirectory: request.workingDirectory,
            systemPrompt: systemPrompt,
            allowedToolNames: allowedToolNames,
            selectedSkillIDs: request.selectedSkillIDs,
            preserveThinking: request.preserveThinking
        )

        return AgentCoreSessionConfiguration(
            sessionID: request.sessionID,
            modelID: effectiveModelID,
            bearerToken: request.bearerToken ?? agentConfiguration.bearerToken,
            workingDirectory: request.workingDirectory,
            systemPrompt: systemPrompt,
            cacheKey: cacheKey,
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
        allowedToolNames: Set<String>?,
        selectedSkillIDs: Set<String> = []
    ) -> String {
        let memoryToolEnabled = memoryToolEnabled(allowedToolNames)
        let selectedAgentSection = selectedAgent?.promptSection(memoryToolEnabled: memoryToolEnabled)
        let selectedSkillSection = selectedSkillSection(
            for: selectedAgent,
            selectedSkillIDs: selectedSkillIDs
        )
        let providedSystemPrompt = providedSystemPrompt?.nilIfBlank

        if let providedSystemPrompt {
            return [
                MLXSystemPromptBuilder.responseLanguageSection,
                selectedAgentSection,
                selectedSkillSection,
                providedSystemPrompt
            ]
                .compactMap { $0?.nilIfBlank }
                .joined(separator: "\n\n")
        }

        return AgentStandaloneSystemPrompt.prompt(
            cwd: cwd,
            memoryToolEnabled: memoryToolEnabled,
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
            "--cwd",
            request.workingDirectory.path,
            "--max-tool-rounds",
            "\(AgentToolRoundPolicy.normalizedMaxToolRounds(request.maxToolRounds))"
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

        return try AgentConfiguration(arguments: arguments, appModeOverride: true)
    }

    static func resolvedAllowedToolNames(
        selectedToolKeys: Set<String>?,
        explicitAllowedToolNames: Set<String>?,
        selectedAgent: AgentProfile?
    ) -> Set<String>? {
        if let explicitAllowedToolNames {
            return explicitAllowedToolNames
        }
        if let selectedToolKeys {
            let normalizedKeys = selectedToolKeys
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let items = TerminalToolSelectionCatalog.items(featureStatuses: [])
            var allowedToolNames = TerminalToolSelectionCatalog.allowedToolNames(
                for: Set(normalizedKeys),
                items: items
            )
            allowedToolNames.formUnion(intrinsicAllowedToolNames(for: selectedAgent))
            return allowedToolNames
        }
        return selectedAgent?.allowedToolNames()
    }

    private static func intrinsicAllowedToolNames(for selectedAgent: AgentProfile?) -> Set<String> {
        AgentProfileStore.isBuilderAgent(selectedAgent)
            ? AgentProfileStore.featureManagementToolNames
            : []
    }

    private static func resolvedThinkingSelection(
        _ requestedSelection: AgentThinkingSelection?,
        modelID: String?
    ) -> AgentThinkingSelection? {
        if let modelID = modelID?.nilIfBlank,
           let model = AgentSettingsStore.availableModels().first(where: { $0.matches(modelID) }) {
            return model.thinkingSelection(for: requestedSelection)
        }
        return requestedSelection
            ?? AgentSettingsStore.defaultSelection(
                explicitModelID: modelID
            )?.thinkingSelection
    }

    private static func scopedCacheKey(
        _ requestedCacheKey: String?,
        sessionID: String,
        modelID: String?,
        workingDirectory: URL,
        systemPrompt: String,
        allowedToolNames: Set<String>?,
        selectedSkillIDs: Set<String>,
        preserveThinking: Bool
    ) -> String? {
        let seed = requestedCacheKey?.nilIfBlank ?? sessionID.nilIfBlank
        guard let seed else {
            return nil
        }

        let baseHash = cacheKeyBaseHash(from: seed)
        let identityPayload = [
            "model=\(modelID?.nilIfBlank ?? "")",
            "cwd=\(workingDirectory.standardizedFileURL.path)",
            "system=\(systemPrompt)",
            "tools=\((allowedToolNames ?? []).sorted().joined(separator: ","))",
            "skills=\(selectedSkillIDs.sorted().joined(separator: ","))",
            "preserveThinking=\(preserveThinking)"
        ].joined(separator: "\u{1f}")
        return "\(appCacheKeyPrefix)\(baseHash):\(stableHash(identityPayload))"
    }

    private static let appCacheKeyPrefix = "app-session-cache-v1:"

    private static func cacheKeyBaseHash(from rawValue: String) -> String {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmedValue.split(separator: ":", omittingEmptySubsequences: false)
        if trimmedValue.hasPrefix(appCacheKeyPrefix),
           parts.count >= 3,
           !parts[1].isEmpty {
            return String(parts[1])
        }
        return stableHash(trimmedValue)
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    private static func selectedSkillSection(
        for selectedAgent: AgentProfile?,
        selectedSkillIDs explicitSelectedSkillIDs: Set<String>
    ) -> String? {
        guard !explicitSelectedSkillIDs.isEmpty || selectedAgent?.skills.isEmpty == false else {
            return nil
        }

        let availableSkills = MLXPromptSkillCatalog.discoverSkills(
            searchRoots: MLXPromptSkillCatalog.appCatalogSearchRoots()
        )
        var selectedSkillIDs = explicitSelectedSkillIDs
        if let selectedAgent {
            selectedSkillIDs.formUnion(
                selectedAgent.selectedSkillIDs(availableSkills: availableSkills)
            )
        }
        let selectedSkills = availableSkills.filter { selectedSkillIDs.contains($0.id) }
        return MLXSystemPromptBuilder.selectedSkillSection(skills: selectedSkills)
    }
}
