//
//  MLXCoderAgentProfileSetupRunner.swift
//  MLXCoderSetup
//

import Foundation
import MLXCoderCore

public enum MLXCoderAgentProfileSetupRunner {
    public static let option = "--setup-agents"
    private static let interactiveLineReader = TerminalInteractiveLineReader()

    public static func shouldRunSetup(arguments: [String]) -> Bool {
        arguments.dropFirst().contains(option)
    }

    public static func argumentsAfterRemovingSetup(arguments: [String]) -> [String] {
        arguments.filter { $0 != option }
    }

    public static func run(arguments: [String]) throws {
        _ = arguments
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

        let normalizedAgents = AgentProfileStore.normalizedAgentsForSave(
            ensureRequiredDefaultAgents(in: uniqueAgents(agents))
        )
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
                "Regenerate the 7 recommended agents?",
                defaultValue: false
            )
            return useRecommended ? AgentProfileStore.defaultProfiles() : existingAgents
        }

        let useRecommended = try promptYesNo(
            "Create the 7 recommended agents?",
            defaultValue: true
        )
        guard !useRecommended else {
            return AgentProfileStore.defaultProfiles()
        }

        return try readCustomAgents()
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
        let tools = parseList(
            try promptString(
                "Tools (comma/space separated, none for no tools)",
                defaultValue: (defaultAgent?.tools ?? AgentProfileStore.defaultToolNames)
                    .joined(separator: ", "),
                allowEmpty: true
            )
        )
        let skillIDs = parseList(
            try promptString(
                "Skills (comma/space separated ids, optional)",
                defaultValue: defaultAgent.map { skillList($0.skills) },
                allowEmpty: true
            )
        )
        let modelProvider = try promptString(
            "Dedicated model provider (optional)",
            defaultValue: defaultAgent?.modelProvider,
            allowEmpty: true
        ).nilIfBlank
        let modelID = try promptString(
            "Dedicated model (optional)",
            defaultValue: defaultAgent?.modelID,
            allowEmpty: true
        ).nilIfBlank
        let instructions = try promptInstructions(defaultValue: defaultAgent?.instructions)

        return AgentProfileStore.normalizedAgentForSave(AgentProfile(
            id: defaultAgent?.id ?? UUID().uuidString,
            name: name,
            instructions: instructions,
            symbolName: symbolName,
            tools: tools,
            skills: skillIDs.map { AgentProfileSkill(id: $0) },
            modelID: modelID,
            modelProvider: modelProvider
        ))
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
            AgentOutput.standardError.writeString(
                "  \(index + 1). \(agent.displayName) [\(tools)]\(skills)\n"
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

    private static func ensureRequiredDefaultAgents(in agents: [AgentProfile]) -> [AgentProfile] {
        var result = agents
        let defaults = AgentProfileStore.defaultProfiles()
        if !containsAgent(named: AgentProfileStore.defaultAgentName, in: result),
           let defaultAgent = defaults.first(where: { $0.name == AgentProfileStore.defaultAgentName }) {
            result.insert(defaultAgent, at: 0)
        }
        if !containsAgent(named: AgentProfileStore.builderAgentName, in: result),
           let builderAgent = defaults.first(where: { AgentProfileStore.isBuilderAgent($0) }) {
            let insertIndex = result.firstIndex {
                agentSetupNameKey($0.name) == agentSetupNameKey(AgentProfileStore.defaultAgentName)
            }.map { $0 + 1 } ?? 0
            result.insert(builderAgent, at: insertIndex)
        }
        return result
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

    private static func parseList(_ value: String) -> [String] {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.lowercased() == "none" {
            return []
        }
        return normalized
            .split { $0 == "," || $0 == ";" || $0 == " " || $0 == "\n" || $0 == "\t" }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func skillList(_ skills: [AgentProfileSkill]) -> String {
        skills.map(\.id).filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

enum MLXCoderAgentProfileSetupError: LocalizedError {
    case nonInteractiveTerminal
    case inputClosed
    case unableToCreateGlobalAgents(URL)

    var errorDescription: String? {
        switch self {
        case .nonInteractiveTerminal:
            return "mlx-coder --setup-agents requires an interactive terminal."
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
