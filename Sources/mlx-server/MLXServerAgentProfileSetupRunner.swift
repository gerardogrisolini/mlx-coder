//
//  MLXServerAgentProfileSetupRunner.swift
//  mlx-server
//

import Foundation
import MLXCoderCore
#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

enum MLXServerAgentProfileSetupRunner {
    static let option = "--setup-agents"

    static func shouldRunSetup(arguments: [String]) -> Bool {
        arguments.contains(option)
    }

    static func argumentsAfterRemovingSetup(arguments: [String]) -> [String] {
        arguments.filter { $0 != option }
    }

    static func run(arguments: [String]) throws {
        _ = arguments
        guard supportsInteractiveInput() else {
            throw MLXServerAgentProfileSetupError.nonInteractiveTerminal
        }

        let manifestURL = AgentProfileStore.agentsManifestURL()
        FileHandle.standardError.writeString(
            """
            mlx-server agents setup
            Configuro agents.json in:
            \(manifestURL.path)

            """
        )

        let existingAgents = try loadExistingAgentsIfPresent(at: manifestURL)
        var agents = try initialAgents(existingAgents: existingAgents)

        if try promptYesNo("Modificare la lista agenti?", defaultValue: false) {
            agents = try editAgents(agents)
        }

        let normalizedAgents = ensureDefaultAgent(in: uniqueAgents(agents))
        try AgentProfileStore.save(normalizedAgents)
        FileHandle.standardError.writeString(
            "\nAggiornato: agents.json (\(normalizedAgents.count) agenti)\n\n"
        )
    }

    private static func loadExistingAgentsIfPresent(at url: URL) throws -> [AgentProfile]? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let agents = try AgentProfileStore.loadRequired()
            FileHandle.standardError.writeString("Agenti configurati:\n")
            printAgents(agents)
            FileHandle.standardError.writeString("\n")
            return agents
        } catch {
            let shouldOverwrite = try promptYesNo(
                "agents.json esiste ma non e valido. Vuoi riscriverlo?",
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
                "Rigenerare i 6 agenti consigliati?",
                defaultValue: false
            )
            return useRecommended ? AgentProfileStore.defaultProfiles() : existingAgents
        }

        let useRecommended = try promptYesNo(
            "Creare i 6 agenti consigliati?",
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
        } while try promptYesNo("Aggiungere un altro agente?", defaultValue: false)
        return agents
    }

    private static func editAgents(_ initialAgents: [AgentProfile]) throws -> [AgentProfile] {
        var agents = initialAgents
        while true {
            FileHandle.standardError.writeString("\nAgenti:\n")
            printAgents(agents)
            let choice = try promptString(
                "Agente da modificare (numero, add, done)",
                defaultValue: "done",
                allowEmpty: false
            )
            switch choice.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "done", "fine", "exit", "quit":
                return agents
            case "add", "aggiungi", "new", "nuovo":
                agents.append(try readAgent(defaultAgent: nil))
            default:
                guard let index = Int(choice),
                      agents.indices.contains(index - 1) else {
                    FileHandle.standardError.writeString("Scelta non valida.\n")
                    continue
                }
                agents[index - 1] = try readAgent(defaultAgent: agents[index - 1])
            }
        }
    }

    private static func readAgent(defaultAgent: AgentProfile?) throws -> AgentProfile {
        let name = try promptString(
            "Nome agente",
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
                "Tools (virgola/spazio, none per nessuno)",
                defaultValue: (defaultAgent?.tools ?? AgentProfileStore.defaultToolNames)
                    .joined(separator: ", "),
                allowEmpty: true
            )
        )
        let skillIDs = parseList(
            try promptString(
                "Skills (id separati da virgola/spazio, opzionale)",
                defaultValue: defaultAgent.map { skillList($0.skills) },
                allowEmpty: true
            )
        )
        let modelProvider = try promptString(
            "Provider modello dedicato (opzionale)",
            defaultValue: defaultAgent?.modelProvider,
            allowEmpty: true
        ).nilIfBlank
        let modelID = try promptString(
            "Modello dedicato (opzionale)",
            defaultValue: defaultAgent?.modelID,
            allowEmpty: true
        ).nilIfBlank
        let instructions = try promptInstructions(defaultValue: defaultAgent?.instructions)

        return AgentProfile(
            id: defaultAgent?.id ?? UUID().uuidString,
            name: name,
            instructions: instructions,
            symbolName: symbolName,
            tools: tools,
            skills: skillIDs.map { AgentProfileSkill(id: $0) },
            modelID: modelID,
            modelProvider: modelProvider
        )
    }

    private static func promptInstructions(defaultValue: String?) throws -> String? {
        let shouldEdit = try promptYesNo(
            defaultValue == nil ? "Inserire istruzioni agente?" : "Modificare istruzioni agente?",
            defaultValue: defaultValue == nil
        )
        guard shouldEdit else {
            return defaultValue
        }

        FileHandle.standardError.writeString(
            """
            Inserisci le istruzioni. Scrivi solo "." su una riga per terminare.

            """
        )
        var lines: [String] = []
        while true {
            FileHandle.standardError.writeString("> ")
            guard let line = readLine() else {
                throw MLXServerAgentProfileSetupError.inputClosed
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
            FileHandle.standardError.writeString(
                "  \(index + 1). \(agent.displayName) [\(tools)]\(skills)\n"
            )
        }
    }

    private static func uniqueAgents(_ agents: [AgentProfile]) -> [AgentProfile] {
        var seen = Set<String>()
        var result: [AgentProfile] = []
        for agent in agents {
            let key = agent.displayName.agentSetupKey
            guard seen.insert(key).inserted else {
                continue
            }
            result.append(agent)
        }
        return result
    }

    private static func ensureDefaultAgent(in agents: [AgentProfile]) -> [AgentProfile] {
        if agents.contains(where: { $0.displayName.agentSetupKey == AgentProfileStore.defaultAgentName.agentSetupKey }) {
            return agents
        }
        return [AgentProfileStore.defaultProfiles()[0]] + agents
    }

    private static func promptString(
        _ prompt: String,
        defaultValue: String?,
        allowEmpty: Bool
    ) throws -> String {
        while true {
            let suffix = defaultValue.map { " [\($0)]" } ?? ""
            FileHandle.standardError.writeString("\(prompt)\(suffix): ")
            guard let line = readLine() else {
                throw MLXServerAgentProfileSetupError.inputClosed
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
            FileHandle.standardError.writeString("\(prompt) [\(defaultLabel)]: ")
            guard let line = readLine() else {
                throw MLXServerAgentProfileSetupError.inputClosed
            }
            let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.isEmpty {
                return defaultValue
            }
            if ["y", "yes", "s", "si", "sì"].contains(normalized) {
                return true
            }
            if ["n", "no"].contains(normalized) {
                return false
            }
        }
    }

    private static func parseList(_ value: String) -> [String] {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.lowercased() == "none" || normalized.lowercased() == "nessuno" {
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

    private static func supportsInteractiveInput() -> Bool {
        #if os(macOS) || os(Linux)
        return isatty(STDIN_FILENO) == 1
        #else
        return true
        #endif
    }
}

enum MLXServerAgentProfileSetupError: LocalizedError {
    case nonInteractiveTerminal
    case inputClosed

    var errorDescription: String? {
        switch self {
        case .nonInteractiveTerminal:
            return "mlx-server --setup-agents requires an interactive terminal."
        case .inputClosed:
            return "Input closed during mlx-server agents setup."
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var agentSetupKey: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

private extension FileHandle {
    func writeString(_ string: String) {
        try? write(contentsOf: Data(string.utf8))
    }
}
