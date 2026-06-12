//
//  MLXCoderAgentProfileSetupRunner.swift
//  MLXCoderSetup
//

import Foundation
import MLXCoderCore

public enum MLXCoderAgentProfileSetupRunner {
    private static let interactiveLineReader = TerminalInteractiveLineReader()
    static let retiredRecommendedAgentNames = Set(["Feature", "Research"].map(agentSetupNameKey))
    static let retiredRecommendedAgentIDs = Set([
        "00000000-0000-0000-0000-000000000003",
        "00000000-0000-0000-0000-000000000005"
    ].map(agentSetupNameKey))

    private struct AgentSetupModelSelection {
        let modelID: String
        let modelProvider: String?
        let thinkingSelection: AgentThinkingSelection?
    }

    private enum AgentSetupModelChoice: Hashable {
        case defaultModel
        case configuredModel(String)
    }

        public static func configureInteractively() throws {
        guard TerminalRawInput.supportsInteractiveInput() else {
            throw MLXCoderAgentProfileSetupError.nonInteractiveTerminal
        }

        let globalAgentsResult = try ensureGlobalAgentsFile()
        let manifestURL = AgentProfileStore.agentsManifestURL()
        AgentOutput.standardError.writeString(
            """
            mlx-coder agents setup
            Global AGENTS.md:
            \(globalAgentsResult.url.path)
            \(globalAgentsResult.created ? "Created" : "Preserved"): AGENTS.md

            Configuring agents.json at:
            \(manifestURL.path)

            """
        )

        let existingAgents = try loadExistingAgentsIfPresent(at: manifestURL)
        var agents = try initialAgents(existingAgents: existingAgents)

        if try promptYesNo("Edit the agent list?", defaultValue: false) {
            agents = try editAgents(agents)
        }

        let normalizedAgents = preparedAgentsForSave(agents)
        try AgentProfileStore.save(normalizedAgents)
        AgentOutput.standardError.writeString(
            "\nUpdated: agents.json (\(normalizedAgents.count) agents)\n\n"
        )
    }

    private static func ensureGlobalAgentsFile() throws -> (url: URL, created: Bool) {
        let service = MLXAgentsContextService()
        let url = service.globalAgentsFileURL()
        let existedBefore = FileManager.default.fileExists(atPath: url.path)
        guard let ensuredURL = service.ensureGlobalAgentsFileExists() else {
            throw MLXCoderAgentProfileSetupError.unableToCreateGlobalAgents(url)
        }
        return (ensuredURL, !existedBefore)
    }

    private static func loadExistingAgentsIfPresent(at url: URL) throws -> [AgentProfile]? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let agents = try AgentProfileStore.loadRequired()
            AgentOutput.standardError.writeString("Configured agents:\n")
            printAgents(agents)
            AgentOutput.standardError.writeString("\n")
            return agents
        } catch {
            let shouldOverwrite = try promptYesNo(
                "agents.json exists but is invalid. Rewrite it?",
                defaultValue: true
            )
            guard shouldOverwrite else {
                throw error
            }
            return nil
        }
    }

    private static func initialAgents(existingAgents: [AgentProfile]?) throws -> [AgentProfile] {
        if let existingAgents {
            let useRecommended = try promptYesNo(
                "Regenerate the \(recommendedAgentCount) recommended agents?",
                defaultValue: false
            )
            return useRecommended ? AgentProfileStore.defaultProfiles() : existingAgents
        }

        let useRecommended = try promptYesNo(
            "Create the \(recommendedAgentCount) recommended agents?",
            defaultValue: true
        )
        guard !useRecommended else {
            return AgentProfileStore.defaultProfiles()
        }

        return try readCustomAgents()
    }

    static var recommendedAgentCount: Int {
        AgentProfileStore.defaultProfiles().count
    }

    static func preparedAgentsForSave(_ agents: [AgentProfile]) -> [AgentProfile] {
        AgentProfileStore.normalizedAgentsForSave(
            ensureRequiredDefaultAgents(
                in: removeRetiredRecommendedAgents(from: uniqueAgents(agents))
            )
        )
    }

    private static func readCustomAgents() throws -> [AgentProfile] {
        var agents: [AgentProfile] = []
        repeat {
            agents.append(try readAgent(defaultAgent: nil))
        } while try promptYesNo("Add another agent?", defaultValue: false)
        return agents
    }

    private static func editAgents(_ initialAgents: [AgentProfile]) throws -> [AgentProfile] {
        var agents = initialAgents
        while true {
            AgentOutput.standardError.writeString("\nAgents:\n")
            printAgents(agents)
            let choice = try promptString(
                "Agent to edit (number, add, done)",
                defaultValue: "done",
                allowEmpty: false
            )
            switch choice.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "done", "exit", "quit":
                return agents
            case "add", "new":
                agents.append(try readAgent(defaultAgent: nil))
            default:
                guard let index = Int(choice),
                      agents.indices.contains(index - 1) else {
                    AgentOutput.standardError.writeString("Invalid selection.\n")
                    continue
                }
                agents[index - 1] = try readAgent(defaultAgent: agents[index - 1])
            }
        }
    }

    private static func readAgent(defaultAgent: AgentProfile?) throws -> AgentProfile {
        let name = try promptString(
            "Agent name",
            defaultValue: defaultAgent?.name,
            allowEmpty: false
        )
        let symbolName = try promptString(
            "SF Symbol",
            defaultValue: defaultAgent?.symbolName,
            allowEmpty: true
        ).nilIfBlank
        let tools = promptToolSelection(
            title: "Tools for \(name)",
            defaultTools: defaultAgent?.tools ?? AgentProfileStore.defaultToolNames
        )
        let skills = promptSkillSelection(
            title: "Prompt skills for \(name)",
            defaultSkills: defaultAgent?.skills ?? []
        )
        let modelSelection = promptModelSelection(
            title: "Dedicated model for \(name)",
            defaultAgent: defaultAgent
        )
        let instructions = try promptInstructions(defaultValue: defaultAgent?.instructions)

        return AgentProfileStore.normalizedAgentForSave(AgentProfile(
            id: defaultAgent?.id ?? UUID().uuidString,
            name: name,
            instructions: instructions,
            symbolName: symbolName,
            tools: tools,
            skills: skills,
            modelID: modelSelection?.modelID,
            modelProvider: modelSelection?.modelProvider,
            thinkingSelection: modelSelection?.thinkingSelection
        ))
    }

    private static func promptToolSelection(
        title: String,
        defaultTools: [String]
    ) -> [String] {
        let items = toolSelectionItems(existingTools: defaultTools)
        guard !items.isEmpty else {
            return defaultTools
        }
        let selectedKeys = TerminalChat.toolSelectionKeys(
            from: defaultTools,
            items: items
        )
        let selection = TerminalCheckboxMenu.select(
            title: title,
            items: TerminalChat.toolCheckboxItems(items: items),
            selected: selectedKeys
        ) ?? selectedKeys
        return TerminalToolSelectionCatalog.selectedKeyNames(
            selection,
            items: items
        )
    }

    private static func toolSelectionItems(
        existingTools: [String]
    ) -> [TerminalToolSelectionItem] {
        let baseItems = TerminalToolSelectionCatalog.items(
            featureStatuses: SwiftFeatureRuntime.defaultFeatureStatuses()
        )
        var items = baseItems
        let missingTools = existingTools.compactMap(\.nilIfBlank).filter { tool in
            TerminalToolSelectionCatalog.selectionKeys(
                for: tool,
                items: baseItems
            ).isEmpty
        }
        for tool in missingTools {
            items.append(
                TerminalToolSelectionItem(
                    key: tool,
                    title: tool,
                    detail: "saved tool not currently listed",
                    groupTitle: "Saved",
                    allowedToolNames: [tool]
                )
            )
        }
        return items
    }

    private static func promptSkillSelection(
        title: String,
        defaultSkills: [AgentProfileSkill]
    ) -> [AgentProfileSkill] {
        let selectedSkillIDs = Set(defaultSkills.compactMap { $0.id.nilIfBlank })
        let items = skillCheckboxItems(
            availableSkills: MLXPromptSkillCatalog.discoverSkills(
                searchRoots: MLXPromptSkillCatalog.appCatalogSearchRoots()
            ),
            selectedSkillIDs: selectedSkillIDs
        )
        guard !items.isEmpty else {
            AgentOutput.standardError.writeString("No prompt skills installed by the app.\n")
            return defaultSkills
        }
        let selection = TerminalCheckboxMenu.select(
            title: title,
            items: items,
            selected: selectedSkillIDs
        ) ?? selectedSkillIDs
        return selection.sorted().map { AgentProfileSkill(id: $0) }
    }

    static func skillCheckboxItems(
        availableSkills: [MLXPromptSkill],
        selectedSkillIDs: Set<String>
    ) -> [TerminalCheckboxMenuItem<String>] {
        let availableIDs = Set(availableSkills.map(\.id))
        let availableItems = availableSkills.map { skill in
            let canonicalName = skill.canonicalName == skill.title
                ? ""
                : " (\(skill.canonicalName))"
            return TerminalCheckboxMenuItem(
                value: skill.id,
                title: "\(skill.title)\(canonicalName)",
                detail: truncatedInline(skill.summary, limit: 96)
            )
        }
        let missingItems = selectedSkillIDs
            .subtracting(availableIDs)
            .sorted()
            .map { skillID in
                TerminalCheckboxMenuItem(
                    value: skillID,
                    title: skillID,
                    detail: "saved skill not currently installed",
                    groupTitle: "Saved"
                )
            }
        return availableItems + missingItems
    }

    private static func promptModelSelection(
        title: String,
        defaultAgent: AgentProfile?
    ) -> AgentSetupModelSelection? {
        let models = AgentModelCatalogPresentation.sorted(
            AgentSettingsStore.availableModels()
        )
        guard !models.isEmpty else {
            if let modelID = defaultAgent?.modelID?.nilIfBlank {
                AgentOutput.standardError.writeString(
                    "No configured models found. Preserving saved model: \(modelID)\n"
                )
                return AgentSetupModelSelection(
                    modelID: modelID,
                    modelProvider: defaultAgent?.modelProvider,
                    thinkingSelection: defaultAgent?.thinkingSelection
                )
            }
            AgentOutput.standardError.writeString("No configured models found for dedicated agent selection.\n")
            return nil
        }

        let existingModelID = defaultAgent?.modelID?.nilIfBlank
        let initialChoice = existingModelID.map { modelID in
            models.first(where: { $0.matches(modelID) })
                .map { AgentSetupModelChoice.configuredModel($0.id) }
                ?? .configuredModel(modelID)
        } ?? .defaultModel
        let choice = TerminalCheckboxMenu.selectOne(
            title: title,
            items: modelChoiceItems(
                models: models,
                existingModelID: existingModelID
            ),
            selected: initialChoice
        ) ?? initialChoice

        switch choice {
        case .defaultModel:
            return nil
        case let .configuredModel(modelID):
            guard let model = models.first(where: { $0.matches(modelID) }) else {
                return AgentSetupModelSelection(
                    modelID: modelID,
                    modelProvider: defaultAgent?.modelProvider,
                    thinkingSelection: defaultAgent?.thinkingSelection
                )
            }
            return AgentSetupModelSelection(
                modelID: model.id,
                modelProvider: modelProviderTitle(for: model),
                thinkingSelection: promptThinkingSelection(
                    for: model,
                    defaultSelection: defaultAgent?.thinkingSelection
                )
            )
        }
    }

    private static func modelChoiceItems(
        models: [AgentSettingsModelManifest],
        existingModelID: String?
    ) -> [TerminalCheckboxMenuItem<AgentSetupModelChoice>] {
        var items: [TerminalCheckboxMenuItem<AgentSetupModelChoice>] = [
            TerminalCheckboxMenuItem(
                value: .defaultModel,
                title: "Default model",
                detail: defaultModelDetail(),
                groupTitle: "Default"
            )
        ]

        for group in AgentModelCatalogPresentation.groupedByProvider(models) {
            items.append(contentsOf: group.models.map { model in
                TerminalCheckboxMenuItem(
                    value: .configuredModel(model.id),
                    title: AgentModelCatalogPresentation.modelTitle(for: model, in: group),
                    detail: modelChoiceDetail(model),
                    groupTitle: group.title
                )
            })
        }

        if let existingModelID,
           !models.contains(where: { $0.matches(existingModelID) }) {
            items.append(
                TerminalCheckboxMenuItem(
                    value: .configuredModel(existingModelID),
                    title: existingModelID,
                    detail: "saved model not currently configured",
                    groupTitle: "Saved"
                )
            )
        }

        return items
    }

    private static func defaultModelDetail() -> String {
        if let selection = AgentSettingsStore.defaultSelection(explicitModelID: nil) {
            return "current default: \(selection.modelID)"
        }
        return "use mlx-coder default"
    }

    private static func modelChoiceDetail(_ model: AgentSettingsModelManifest) -> String {
        var details = [model.modelID]
        if let thinking = model.resolvedDefaultThinkingSelection {
            details.append("thinking default: \(thinking.displayTitle)")
        }
        return details.joined(separator: " | ")
    }

    private static func modelProviderTitle(for model: AgentSettingsModelManifest) -> String? {
        model.provider?.displayTitle.nilIfBlank
            ?? AgentModelCatalogPresentation.providerGroupTitle(for: model).nilIfBlank
    }

    private static func promptThinkingSelection(
        for model: AgentSettingsModelManifest,
        defaultSelection: AgentThinkingSelection?
    ) -> AgentThinkingSelection? {
        guard model.supportsThinking else {
            return nil
        }
        let resolvedDefaultSelection = model.thinkingSelection(for: defaultSelection)
        return TerminalCheckboxMenu.selectOne(
            title: "Thinking for \(AgentModelCatalogPresentation.modelTitle(for: model))",
            items: thinkingSelectionItems(model.availableThinkingSelections),
            selected: resolvedDefaultSelection
        ) ?? resolvedDefaultSelection
    }

    static func thinkingSelectionItems(
        _ selections: [AgentThinkingSelection]
    ) -> [TerminalCheckboxMenuItem<AgentThinkingSelection>] {
        selections.map { selection in
            TerminalCheckboxMenuItem(
                value: selection,
                title: selection.menuTitle,
                detail: selection.rawValue
            )
        }
    }

    private static func promptInstructions(defaultValue: String?) throws -> String? {
        let shouldEdit = try promptYesNo(
            defaultValue == nil ? "Enter agent instructions?" : "Edit agent instructions?",
            defaultValue: defaultValue == nil
        )
        guard shouldEdit else {
            return defaultValue
        }

        AgentOutput.standardError.writeString(
            """
            Enter the instructions. Type only "." on a line to finish.

            """
        )
        var lines: [String] = []
        while true {
            guard let line = interactiveLineReader.readLine(prompt: "> ") else {
                throw MLXCoderAgentProfileSetupError.inputClosed
            }
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == "." {
                break
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n").nilIfBlank
    }

    private static func printAgents(_ agents: [AgentProfile]) {
        for (index, agent) in agents.enumerated() {
            let tools = agent.tools.isEmpty ? "no tools" : agent.tools.joined(separator: ", ")
            let skills = agent.skills.isEmpty ? "" : " | skills: \(skillList(agent.skills))"
            let model = agent.modelID.map { " | model: \($0)" } ?? ""
            let thinking = agent.thinkingSelection.map { " | thinking: \($0.displayTitle)" } ?? ""
            AgentOutput.standardError.writeString(
                "  \(index + 1). \(agent.displayName) [\(tools)]\(skills)\(model)\(thinking)\n"
            )
        }
    }

    private static func uniqueAgents(_ agents: [AgentProfile]) -> [AgentProfile] {
        var seen = Set<String>()
        var result: [AgentProfile] = []
        for agent in agents {
            let key = agentSetupNameKey(agent.name)
            guard seen.insert(key).inserted else {
                continue
            }
            result.append(agent)
        }
        return result
    }

    private static func removeRetiredRecommendedAgents(from agents: [AgentProfile]) -> [AgentProfile] {
        agents.filter { agent in
            !retiredRecommendedAgentIDs.contains(agentSetupNameKey(agent.id))
                && !retiredRecommendedAgentNames.contains(agentSetupNameKey(agent.name))
        }
    }

    private static func ensureRequiredDefaultAgents(in agents: [AgentProfile]) -> [AgentProfile] {
        var result = agents
        let defaults = AgentProfileStore.defaultProfiles()
        for defaultAgent in defaults where requiredDefaultAgentNames.contains(agentSetupNameKey(defaultAgent.name)) {
            guard !containsAgent(named: defaultAgent.name, in: result) else {
                continue
            }
            result.insert(defaultAgent, at: requiredDefaultAgentInsertIndex(for: defaultAgent, in: result))
        }
        return result
    }

    private static var requiredDefaultAgentNames: Set<String> {
        Set([
            AgentProfileStore.defaultAgentName,
            "Minimal",
            AgentProfileStore.builderAgentName
        ].map(agentSetupNameKey))
    }

    private static func requiredDefaultAgentInsertIndex(
        for defaultAgent: AgentProfile,
        in agents: [AgentProfile]
    ) -> Int {
        let preferredOrder = AgentProfileStore.defaultProfiles().map { agentSetupNameKey($0.name) }
        let defaultAgentOrder = preferredOrder.firstIndex(of: agentSetupNameKey(defaultAgent.name)) ?? 0
        return agents.firstIndex { agent in
            let agentOrder = preferredOrder.firstIndex(of: agentSetupNameKey(agent.name)) ?? Int.max
            return agentOrder > defaultAgentOrder
        } ?? agents.count
    }

    private static func containsAgent(named name: String, in agents: [AgentProfile]) -> Bool {
        let expectedKey = agentSetupNameKey(name)
        return agents.contains { agentSetupNameKey($0.name) == expectedKey }
    }

    private static func agentSetupNameKey(_ name: String) -> String {
        name.agentSetupKey
    }

    private static func promptString(
        _ prompt: String,
        defaultValue: String?,
        allowEmpty: Bool
    ) throws -> String {
        while true {
            let suffix = defaultValue.map { " [\($0)]" } ?? ""
            guard let line = interactiveLineReader.readLine(prompt: "\(prompt)\(suffix): ") else {
                throw MLXCoderAgentProfileSetupError.inputClosed
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty, let defaultValue {
                return defaultValue
            }
            if trimmed.isEmpty, allowEmpty {
                return ""
            }
            if !trimmed.isEmpty {
                return trimmed
            }
        }
    }

    private static func promptYesNo(
        _ prompt: String,
        defaultValue: Bool
    ) throws -> Bool {
        let defaultLabel = defaultValue ? "Y/n" : "y/N"
        while true {
            guard let line = interactiveLineReader.readLine(prompt: "\(prompt) [\(defaultLabel)]: ") else {
                throw MLXCoderAgentProfileSetupError.inputClosed
            }
            let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.isEmpty {
                return defaultValue
            }
            if ["y", "yes"].contains(normalized) {
                return true
            }
            if ["n", "no"].contains(normalized) {
                return false
            }
        }
    }

    private static func skillList(_ skills: [AgentProfileSkill]) -> String {
        skills.map(\.id).filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private static func truncatedInline(_ value: String, limit: Int) -> String {
        let inline = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard inline.count > limit else {
            return inline
        }
        return String(inline.prefix(max(0, limit - 3))) + "..."
    }
}

enum MLXCoderAgentProfileSetupError: LocalizedError {
    case nonInteractiveTerminal
    case inputClosed
    case unableToCreateGlobalAgents(URL)

    var errorDescription: String? {
        switch self {
                case .nonInteractiveTerminal:
            return "mlx-coder agents setup requires an interactive terminal."
        case .inputClosed:
            return "Input closed during mlx-coder agents setup."
        case let .unableToCreateGlobalAgents(url):
            return "Unable to create global AGENTS.md at \(url.path)."
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var agentSetupKey: String {
        components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

private extension FileHandle {
    func writeString(_ string: String) {
        try? write(contentsOf: Data(string.utf8))
    }
}
