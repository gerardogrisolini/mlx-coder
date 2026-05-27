//
//  Generated split from TerminalChat.swift
//  mlx-coder
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

extension TerminalChat {
    public func createCurrentSession() async throws {
        try await sessionRunner.createSession(
            configuration: await currentSessionConfiguration()
        )
    }

    public func currentSessionConfiguration(
        discoverExternalTools: Bool = true
    ) async -> AgentCoreSessionConfiguration {
        let allowedToolNames = await selectedAllowedToolNames(
            discoverExternalTools: discoverExternalTools
        )
        return currentSessionConfiguration(allowedToolNames: allowedToolNames)
    }

    public func currentSessionConfiguration(
        allowedToolNames: Set<String>
    ) -> AgentCoreSessionConfiguration {
        let systemPrompt = currentSystemPrompt(allowedToolNames: allowedToolNames)
        return AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: currentEffectiveModelID(),
            bearerToken: configuration.bearerToken,
            workingDirectory: configuration.workingDirectory,
            systemPrompt: systemPrompt,
            cacheKey: nil,
            sessionRevision: 0,
            history: [],
            allowedToolNames: allowedToolNames,
            maxToolRounds: configuration.maxToolRounds,
            maxOutputTokens: configuration.maxOutputTokens,
            verboseLogging: configuration.verboseLogging,
            appMode: configuration.appMode,
            thinkingSelection: currentAgentThinkingSelection(),
            preserveThinking: false
        )
    }

    public func currentSystemPrompt(allowedToolNames: Set<String>) -> String {
        let memoryToolEnabled = Self.memoryToolEnabled(allowedToolNames)
        return AgentStandaloneSystemPrompt.prompt(
            cwd: configuration.workingDirectory.path,
            memoryToolEnabled: memoryToolEnabled,
            selectedAgentSection: selectedAgent?.promptSection(memoryToolEnabled: memoryToolEnabled),
            selectedSkillSection: MLXSystemPromptBuilder.selectedSkillSection(
                skills: selectedPromptSkills()
            )
        )
    }

    public func refreshInitialStatusBarContextWindow() {
        if let hostedModel = hostedModelManifest(for: currentEffectiveModelID()),
           let maxTokens = hostedModel.configuredContextWindowLimit {
            _ = statusBar.update(
                contextWindow: DirectAgentContextWindowStatus(
                    usedTokens: 0,
                    maxTokens: maxTokens,
                    modelID: hostedModel.modelID,
                    isApproximate: true
                )
            )
            return
        }

        guard let selection = AgentSettingsStore.defaultSelection(
            explicitModelID: currentEffectiveModelID()
        ),
              let maxTokens = selection.configuredContextWindowLimit else {
            return
        }

        _ = statusBar.update(
            contextWindow: DirectAgentContextWindowStatus(
                usedTokens: 0,
                maxTokens: maxTokens,
                modelID: selection.modelID,
                isApproximate: true
            )
        )
    }

    public func currentAgentThinkingSelection() -> AgentThinkingSelection? {
        if let manualThinkingSelectionOverride {
            return manualThinkingSelectionOverride
        }
        if let hostedModel = hostedModelManifest(for: currentEffectiveModelID()) {
            return hostedModel.resolvedDefaultThinkingSelection
        }
        return AgentSettingsStore.defaultSelection(
            explicitModelID: currentEffectiveModelID()
        )?.thinkingSelection
    }

    public func hostedModelManifest(
        for modelID: String?
    ) -> AgentSettingsModelManifest? {
        guard let modelID,
              let hostedModels = configuration.hostedModels else {
            return nil
        }
        return hostedModels.first { $0.matches(modelID) }
    }

    public func selectedAllowedToolNames(
        discoverExternalTools: Bool = true
    ) async -> Set<String> {
        guard !selectedToolGroups.isEmpty else {
            return []
        }

        var toolNames = Set(DirectToolCatalog.baseDescriptors.map(\.name))
        if selectedToolGroups.contains(.xcode) || selectedToolGroups.contains(.figma) {
            var mcpDiscoveryToolNames = Set<String>()
            if selectedToolGroups.contains(.xcode) {
                mcpDiscoveryToolNames.insert("xcode.BuildProject")
            }
            if selectedToolGroups.contains(.figma) {
                mcpDiscoveryToolNames.insert("figma.")
            }
            let mcpDescriptors: [DirectToolDescriptor]
            if discoverExternalTools {
                mcpDescriptors = await sessionRunner.mcpToolDescriptors(
                    allowedToolNames: mcpDiscoveryToolNames
                )
            } else {
                mcpDescriptors = await sessionRunner.knownMCPToolDescriptors(
                    allowedToolNames: mcpDiscoveryToolNames
                )
            }
            toolNames.formUnion(mcpDescriptors.map(\.name))
        }

        return Set(toolNames.filter { toolName in
            selectedToolGroups.contains { group in
                group.allows(toolName: toolName)
            }
        })
    }

    @discardableResult
    public func updateCurrentSessionToolOptions(
        discoverExternalTools: Bool = true
    ) async -> Set<String> {
        let allowedToolNames = await selectedAllowedToolNames(
            discoverExternalTools: discoverExternalTools
        )
        do {
            try await sessionRunner.updateSessionOptions(
                configuration: currentSessionConfiguration(
                    allowedToolNames: allowedToolNames
                )
            )
        } catch {
            AgentOutput.standardError.writeString("mlx-coder: \(error.localizedDescription)\n")
        }
        didPrintActiveTools = false
        return allowedToolNames
    }

    public func ensureWorkspaceAccessIfNeeded() async {
        guard stdinIsTerminal,
              !configuration.appMode,
              !selectedToolGroups.isDisjoint(with: Self.workspaceAccessToolGroups) else {
            return
        }

        #if os(macOS)
        let granted = await TerminalWorkspaceToolAccessStore.shared.ensureAccess(
            for: configuration.workingDirectory
        )
        guard !granted else {
            return
        }

        let disabledGroups = selectedToolGroups.intersection(Self.workspaceAccessToolGroups)
        selectedToolGroups.subtract(disabledGroups)
        let disabledGroupNames = disabledGroups
            .sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
            .map(\.displayTitle)
            .joined(separator: ", ")
        AgentOutput.standardError.writeString(
            """
            Workspace access was not granted for \(configuration.workingDirectory.path).
            Disabled tool groups: \(disabledGroupNames).

            """
        )
        #endif
    }

    private static let workspaceAccessToolGroups: Set<TerminalToolGroup> = [
        .bash,
        .git,
        .memory
    ]
}
