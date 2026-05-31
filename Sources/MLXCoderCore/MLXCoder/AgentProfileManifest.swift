//
//  AgentProfileManifest.swift
//  MLXCoder
//
//  Created by Codex on 09/05/26.
//

import Foundation

public struct AgentProfileManifest: Codable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let agents: [AgentProfile]

    public init(
        version: Int = Self.currentVersion,
        agents: [AgentProfile]
    ) {
        self.version = version
        self.agents = agents
    }
}

public struct AgentProfile: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let instructions: String?
    public let symbolName: String?
    public let tools: [String]
    public let skills: [AgentProfileSkill]
    public let modelID: String?
    public let modelProvider: String?

    public init(
        id: String,
        name: String,
        instructions: String? = nil,
        symbolName: String? = nil,
        tools: [String] = [],
        skills: [AgentProfileSkill] = [],
        modelID: String? = nil,
        modelProvider: String? = nil
    ) {
        self.id = id.nilIfBlank ?? UUID().uuidString
        self.name = name.nilIfBlank ?? AgentProfileStore.defaultAgentName
        self.instructions = instructions?.nilIfBlank
        self.symbolName = symbolName?.nilIfBlank
        self.tools = tools
        self.skills = skills
        self.modelID = modelID?.nilIfBlank
        self.modelProvider = modelProvider?.nilIfBlank
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.instructions = try container.decodeIfPresent(String.self, forKey: .instructions)?.nilIfBlank
        self.symbolName = try container.decodeIfPresent(String.self, forKey: .symbolName)?.nilIfBlank
        self.tools = try container.decodeIfPresent([String].self, forKey: .tools) ?? []
        self.skills = try container.decodeIfPresent([AgentProfileSkill].self, forKey: .skills) ?? []
        self.modelID = try container.decodeIfPresent(String.self, forKey: .modelID)?.nilIfBlank
        self.modelProvider = try container.decodeIfPresent(String.self, forKey: .modelProvider)?.nilIfBlank
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case instructions
        case symbolName
        case tools
        case skills
        case modelID
        case modelProvider
    }

    public var displayName: String {
        name.nilIfBlank ?? "Unnamed Agent"
    }

    public var promptSection: String? {
        promptSection(memoryToolEnabled: true)
    }

    public func promptSection(memoryToolEnabled: Bool) -> String? {
        var lines = ["Selected agent: \(displayName)"]
        if instructions != nil {
            lines.append("Agent instructions:")
            lines.append(resolvedInstructions(memoryToolEnabled: memoryToolEnabled))
        }
        return lines.joined(separator: "\n").nilIfBlank
    }

    private func resolvedInstructions(memoryToolEnabled: Bool) -> String {
        guard let instructions else {
            return ""
        }
        let defaultInstructionsWithMemory = MLXSystemPromptBuilder.defaultAgentInstructions(memoryToolEnabled: true)
        let defaultInstructionsWithoutMemory = MLXSystemPromptBuilder.defaultAgentInstructions(memoryToolEnabled: false)
        guard instructions == defaultInstructionsWithMemory || instructions == defaultInstructionsWithoutMemory else {
            return instructions
        }
        return MLXSystemPromptBuilder.defaultAgentInstructions(memoryToolEnabled: memoryToolEnabled)
    }

    public func allowedToolNames() -> Set<String> {
        let items = TerminalToolSelectionCatalog.items(
            featureStatuses: SwiftFeatureRuntime.defaultFeatureStatuses()
        )
        var selectedKeys = Set<String>()
        var allowedToolNames = Set<String>()
        for tool in tools {
            let matchingKeys = TerminalToolSelectionCatalog.selectionKeys(
                for: tool,
                items: items
            )
            if matchingKeys.isEmpty {
                if let normalizedName = tool.nilIfBlank {
                    guard !AgentProfileStore.isFeatureManagementToolReference(normalizedName) else {
                        continue
                    }
                    allowedToolNames.insert(normalizedName)
                }
            } else {
                selectedKeys.formUnion(matchingKeys)
            }
        }
        allowedToolNames.formUnion(
            TerminalToolSelectionCatalog.allowedToolNames(
                for: selectedKeys,
                items: items
            )
        )
        if AgentProfileStore.isBuilderAgent(self) {
            allowedToolNames.formUnion(AgentProfileStore.featureManagementToolNames)
        }
        return allowedToolNames
    }

    public func selectedSkillIDs(availableSkills: [MLXPromptSkill]) -> Set<String> {
        return Set(
            skills.compactMap { skill in
                skill.matchingSkillID(in: availableSkills)
            }
        )
    }

}

public struct AgentProfileSkill: Codable, Hashable, Sendable {
    public let id: String
    public let canonicalName: String?
    public let title: String?
    public let summary: String?
    public let symbolName: String?

    public init(
        id: String,
        canonicalName: String? = nil,
        title: String? = nil,
        summary: String? = nil,
        symbolName: String? = nil
    ) {
        self.id = id.nilIfBlank ?? ""
        self.canonicalName = canonicalName?.nilIfBlank
        self.title = title?.nilIfBlank
        self.summary = summary?.nilIfBlank
        self.symbolName = symbolName?.nilIfBlank
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id)?.nilIfBlank ?? ""
        self.canonicalName = try container.decodeIfPresent(String.self, forKey: .canonicalName)?.nilIfBlank
        self.title = try container.decodeIfPresent(String.self, forKey: .title)?.nilIfBlank
        self.summary = try container.decodeIfPresent(String.self, forKey: .summary)?.nilIfBlank
        self.symbolName = try container.decodeIfPresent(String.self, forKey: .symbolName)?.nilIfBlank
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case canonicalName
        case title
        case summary
        case symbolName
    }

    public func matchingSkillID(in availableSkills: [MLXPromptSkill]) -> String? {
        let idKey = id.selectionKey.nilIfBlank
        let canonicalNameKey = canonicalName?.selectionKey.nilIfBlank
        let titleKey = title?.selectionKey.nilIfBlank
        let summaryKey = summary?.selectionKey.nilIfBlank

        if let idKey,
           let skill = availableSkills.first(where: { $0.id.selectionKey == idKey }) {
            return skill.id
        }

        if let canonicalNameKey,
           let skill = availableSkills.first(where: { $0.canonicalName.selectionKey == canonicalNameKey }) {
            return skill.id
        }

        if let titleKey,
           let summaryKey,
           let skill = availableSkills.first(where: {
               $0.title.selectionKey == titleKey && $0.summary.selectionKey == summaryKey
           }) {
            return skill.id
        }

        if let titleKey {
            let matches = availableSkills.filter { $0.title.selectionKey == titleKey }
            if matches.count == 1 {
                return matches[0].id
            }
        }

        return nil
    }
}

public enum AgentProfileStore {
    public static let defaultAgentName = "Default"
    public static let defaultAgentID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public static let bugfixAgentID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    public static let featureAgentID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    public static let reviewAgentID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    public static let researchAgentID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
    public static let refactorAgentID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
    public static let builderAgentID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
    public static let builderAgentName = "Builder"
    public static let manifestFilename = "agents.json"
    public static let codingToolNames: [String] = [
        "shell",
        "files",
        TerminalToolSelectionCatalog.featurePackageKey(id: "mlx-search-tools"),
        "text",
        TerminalToolSelectionCatalog.featurePackageKey(id: "mlx-git-tools"),
        "memory"
    ]
    public static let defaultToolNames: [String] = codingToolNames + [
        TerminalToolSelectionCatalog.featurePackageKey(id: "mlx-web-tools"),
        "orchestration"
    ]
    public static let implementationToolNames: [String] = codingToolNames
    public static let featureToolNames: [String] = codingToolNames + [
        TerminalToolSelectionCatalog.featurePackageKey(id: "mlx-web-tools"),
        "orchestration"
    ]
    public static let builderToolNames: [String] = defaultToolNames
    public static let reviewToolNames: [String] = codingToolNames
    public static let researchToolNames: [String] = codingToolNames + [
        TerminalToolSelectionCatalog.featurePackageKey(id: "mlx-web-tools"),
        "orchestration"
    ]
    public static let featureManagementToolNames = Set(DirectToolCatalog.featureDescriptors.map(\.name))

    public static func loadRequired(fileManager: FileManager = .default) throws -> [AgentProfile] {
        let url = agentsManifestURL(fileManager: fileManager)
        guard fileManager.fileExists(atPath: url.path) else {
            throw AgentProfileStoreError.missingFile(url)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AgentProfileStoreError.unreadableFile(url, error)
        }

        let manifest: AgentProfileManifest
        do {
            manifest = try JSONDecoder().decode(AgentProfileManifest.self, from: data)
        } catch {
            throw AgentProfileStoreError.invalidFile(url, error)
        }

        guard manifest.version == AgentProfileManifest.currentVersion else {
            throw AgentProfileStoreError.unsupportedVersion(
                url,
                manifest.version,
                AgentProfileManifest.currentVersion
            )
        }

        guard !manifest.agents.isEmpty else {
            throw AgentProfileStoreError.noAgents(url)
        }
        return manifest.agents
    }

    public static func save(
        _ agents: [AgentProfile],
        fileManager: FileManager = .default
    ) throws {
        let url = agentsManifestURL(fileManager: fileManager)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let manifest = AgentProfileManifest(
            agents: normalizedAgentsForSave(agents).sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: [.atomic])
    }

    @discardableResult
    public static func ensureDefaultManifestExists(
        fileManager: FileManager = .default
    ) throws -> URL {
        let url = agentsManifestURL(fileManager: fileManager)
        guard !fileManager.fileExists(atPath: url.path) else {
            _ = try loadRequired(fileManager: fileManager)
            return url
        }

        try save(defaultProfiles(), fileManager: fileManager)
        return url
    }

    public static func defaultProfiles() -> [AgentProfile] {
        [
            AgentProfile(
                id: defaultAgentID.uuidString,
                name: defaultAgentName,
                instructions: MLXSystemPromptBuilder.defaultAgentInstructions(),
                symbolName: "person.crop.circle",
                tools: defaultToolNames
            ),
            AgentProfile(
                id: bugfixAgentID.uuidString,
                name: "Bugfix",
                instructions: """
                Work as a focused bug-fixing agent. Reproduce or narrow the defect before changing code when practical. Keep edits minimal, preserve existing behavior outside the bug, and verify the fix with the smallest meaningful build or test. Use memory to understand project context before touching code.
                """,
                symbolName: "bandage",
                tools: implementationToolNames
            ),
            AgentProfile(
                id: builderAgentID.uuidString,
                name: builderAgentName,
                instructions: """
                Work as the dedicated feature-builder agent. Create, install, validate, build, enable, disable, and delete Swift feature packages only when the user asks for reusable runtime capability. Keep generated feature packages focused, Swift tools 6.3 compatible, and aligned with the existing feature runtime contract.
                """,
                symbolName: "hammer",
                tools: builderToolNames
            ),
            AgentProfile(
                id: featureAgentID.uuidString,
                name: "Feature",
                instructions: """
                Work as a feature implementation agent. Clarify ambiguous product or API behavior before committing to a broad design. Match existing architecture and UI patterns, keep the feature complete for the requested workflow, and verify the main path. Use memory to resume project context and record durable decisions when the work is significant.
                """,
                symbolName: "sparkles",
                tools: featureToolNames
            ),
            AgentProfile(
                id: reviewAgentID.uuidString,
                name: "Review",
                instructions: """
                Work as a code review agent. Do not modify files unless explicitly asked. Prioritize correctness bugs, regressions, security risks, performance issues, and missing tests. Report findings first, ordered by severity, with precise file and line references. Keep summaries brief.
                """,
                symbolName: "checklist",
                tools: reviewToolNames
            ),
            AgentProfile(
                id: researchAgentID.uuidString,
                name: "Research",
                instructions: """
                Work as a research agent. Gather facts, inspect relevant sources, and separate confirmed information from inference. Do not make code changes unless explicitly requested. When current or external information matters, prefer primary sources and cite what you used.
                """,
                symbolName: "magnifyingglass",
                tools: researchToolNames
            ),
            AgentProfile(
                id: refactorAgentID.uuidString,
                name: "Refactor",
                instructions: """
                Work as a refactoring agent. Preserve observable behavior unless the user explicitly requests a behavior change. Keep the scope tight, prefer existing abstractions, avoid churn, and verify equivalence with targeted tests or builds. Explain risky moves before making them.
                """,
                symbolName: "arrow.triangle.2.circlepath",
                tools: implementationToolNames
            )
        ]
    }

    public static func isBuilderAgent(_ agent: AgentProfile?) -> Bool {
        guard let agent else {
            return false
        }
        return agent.id.selectionKey == builderAgentID.uuidString.selectionKey
            || agent.name.selectionKey == builderAgentName.selectionKey
    }

    public static func normalizedAgentsForSave(_ agents: [AgentProfile]) -> [AgentProfile] {
        agents.map(normalizedAgentForSave)
    }

    public static func normalizedAgentForSave(_ agent: AgentProfile) -> AgentProfile {
        let tools = normalizedToolReferencesForSave(agent.tools)

        return AgentProfile(
            id: agent.id,
            name: agent.name,
            instructions: agent.instructions,
            symbolName: agent.symbolName,
            tools: tools,
            skills: agent.skills,
            modelID: agent.modelID,
            modelProvider: agent.modelProvider
        )
    }

    public static func defaultProfile(in agents: [AgentProfile]) throws -> AgentProfile {
        guard let agent = agents.first(where: { $0.name.selectionKey == defaultAgentName.selectionKey }) else {
            throw AgentProfileStoreError.defaultAgentMissing(agentsManifestURL())
        }
        return agent
    }

    public static func agentsManifestURL(fileManager: FileManager = .default) -> URL {
        return AgentSettingsManifestStore.settingsURL(fileManager: fileManager)
            .deletingLastPathComponent()
            .appendingPathComponent(manifestFilename)
            .standardizedFileURL
    }

    private static func normalizedToolReferencesForSave(_ tools: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for rawTool in tools {
            guard let tool = rawTool.nilIfBlank,
                  !isFeatureManagementToolReference(tool) else {
                continue
            }
            let key = toolReferenceKey(tool)
            guard seen.insert(key).inserted else {
                continue
            }
            result.append(tool)
        }
        return result
    }

    fileprivate static func isFeatureManagementToolReference(_ value: String) -> Bool {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedValue.lowercased().hasPrefix("feature.") {
            return true
        }
        let normalizedValue = toolReferenceKey(value)
        return normalizedValue == toolReferenceKey(TerminalToolSelectionCatalog.featureBuilderKey)
            || normalizedValue == "feature-builder"
            || normalizedValue == "feature-manager"
            || normalizedValue == "feature"
            || normalizedValue == "features"
            || normalizedValue == "kernel"
    }

    private static func toolReferenceKey(_ value: String) -> String {
        let foldedValue = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        let characters = foldedValue.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        return String(characters)
            .replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

public enum AgentProfileStoreError: LocalizedError {
    case missingFile(URL)
    case unreadableFile(URL, Error)
    case invalidFile(URL, Error)
    case unsupportedVersion(URL, Int, Int)
    case noAgents(URL)
    case defaultAgentMissing(URL)

    public var errorDescription: String? {
        switch self {
        case let .missingFile(url):
            return "Missing mlx-coder agents file: \(url.path)"
        case let .unreadableFile(url, error):
            return "Unable to read mlx-coder agents file \(url.path): \(error.localizedDescription)"
        case let .invalidFile(url, error):
            return "Invalid mlx-coder agents file \(url.path): \(error.localizedDescription)"
        case let .unsupportedVersion(url, found, expected):
            return "Unsupported mlx-coder agents file \(url.path): version \(found), expected \(expected)"
        case let .noAgents(url):
            return "The mlx-coder agents file \(url.path) does not contain any agents."
        case let .defaultAgentMissing(url):
            return "The mlx-coder agents file \(url.path) does not contain the Default agent."
        }
    }
}

extension String {
    fileprivate var selectionKey: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}
