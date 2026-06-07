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
            configuration: await currentSessionConfiguration(
                discoverExternalTools: false
            )
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
        let systemPrompt = activeSessionSystemPromptOverride
            ?? currentSystemPrompt(allowedToolNames: allowedToolNames)
        return AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: currentEffectiveModelID(),
            bearerToken: configuration.bearerToken,
            workingDirectory: configuration.workingDirectory,
            systemPrompt: systemPrompt,
            cacheKey: activeSessionCacheKey ?? sessionID,
            sessionRevision: 0,
            history: activeSessionHistory,
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
        let effectiveModelID = currentEffectiveModelID()
        if let hostedModel = hostedModelManifest(for: effectiveModelID) {
            _ = statusBar.update(modelID: hostedModel.modelID)
            guard let maxTokens = hostedModel.configuredContextWindowLimit else {
                return
            }
            _ = statusBar.update(
                contextWindow: DirectAgentContextWindowStatus(
                    usedTokens: nil,
                    maxTokens: maxTokens,
                    modelID: hostedModel.modelID,
                    isApproximate: true
                )
            )
            return
        }

        guard let selection = AgentSettingsStore.defaultSelection(
            explicitModelID: effectiveModelID
        ) else {
            if let effectiveModelID {
                _ = statusBar.update(modelID: effectiveModelID)
            }
            return
        }

        _ = statusBar.update(modelID: selection.modelID)
        guard let maxTokens = selection.configuredContextWindowLimit else {
            return
        }

        _ = statusBar.update(
            contextWindow: DirectAgentContextWindowStatus(
                usedTokens: nil,
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
        let intrinsicToolNames = intrinsicAllowedToolNamesForSelectedAgent()
        let baseItems = await toolSelectionItems()
        guard !selectedToolKeys.isEmpty else {
            return intrinsicToolNames
        }

        selectedToolKeys = TerminalToolSelectionCatalog.normalizedSelectionKeys(
            selectedToolKeys,
            items: baseItems
        )
        let dynamicToolPrefixes = TerminalToolSelectionCatalog.externalDiscoveryPrefixes(
            for: selectedToolKeys,
            items: baseItems
        )
        let mcpDiscoveryToolNames = Set(
            dynamicToolPrefixes.filter { $0 == "xcode." || $0 == "figma." }
        )
        let mcpDescriptors: [DirectToolDescriptor]
        if mcpDiscoveryToolNames.isEmpty {
            mcpDescriptors = []
        } else if discoverExternalTools {
            mcpDescriptors = await sessionRunner.mcpToolDescriptors(
                allowedToolNames: mcpDiscoveryToolNames
            )
        } else {
            mcpDescriptors = await sessionRunner.knownMCPToolDescriptors(
                allowedToolNames: mcpDiscoveryToolNames
            )
        }

        let items = await toolSelectionItems(
            additionalDescriptors: mcpDescriptors
        )
        var allowedToolNames = TerminalToolSelectionCatalog.allowedToolNames(
            for: selectedToolKeys,
            items: items
        )
        allowedToolNames.formUnion(intrinsicToolNames)
        return allowedToolNames
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
            writeFailureMessage("mlx-coder: \(error.localizedDescription)\n")
        }
        didPrintActiveTools = false
        return allowedToolNames
    }

    public func ensureWorkspaceAccessIfNeeded() async {
        let items = await toolSelectionItems()
        let workspaceSelectionKeys = TerminalToolSelectionCatalog.workspaceAccessSelectionKeys(
            for: selectedToolKeys,
            items: items
        )
        guard stdinIsTerminal,
              !configuration.appMode,
              !workspaceSelectionKeys.isEmpty else {
            return
        }

        #if os(macOS)
        let granted = await TerminalWorkspaceToolAccessStore.shared.ensureAccess(
            for: configuration.workingDirectory
        )
        guard !granted else {
            return
        }

        selectedToolKeys.subtract(workspaceSelectionKeys)
        let disabledToolNames = items
            .filter { workspaceSelectionKeys.contains($0.key) }
            .map(\.title)
            .joined(separator: ", ")
        writeSystemMessage(
            """
            Workspace access was not granted for \(configuration.workingDirectory.path).
            Disabled tools: \(disabledToolNames).

            """
        )
        #endif
    }
}
