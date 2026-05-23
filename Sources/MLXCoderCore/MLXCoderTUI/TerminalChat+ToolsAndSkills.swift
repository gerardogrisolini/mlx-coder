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
    public func handleToolsCommand(_ command: String) async {
        let rawArguments = String(command.dropFirst("/tools".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if rawArguments.isEmpty {
            guard stdinIsTerminal else {
                await printToolSelectionStatus()
                AgentOutput.standardError.writeString(Self.renderToolSelectionUsage())
                return
            }

            let selectedGroups = TerminalCheckboxMenu.select(
                title: "Tool groups",
                items: Self.toolCheckboxItems(),
                selected: selectedToolGroups,
                reservedBottomRows: statusBar.reservedRowsForOverlay()
            )
            if let selectedGroups {
                await applyToolSelection(selectedGroups)
            } else {
                await printToolSelectionStatus()
            }
            return
        }

        await applyToolSelection(rawArguments)
    }

    public func applyToolSelection(_ rawSelection: String) async {
        do {
            let selectedGroups = try Self.parseToolSelection(rawSelection)
            await applyToolSelection(selectedGroups)
        } catch {
            AgentOutput.standardError.writeString("mlx-coder: \(error.localizedDescription)\n")
            AgentOutput.standardError.writeString(Self.renderToolSelectionUsage())
        }
    }

    public func applyToolSelection(_ selectedGroups: Set<TerminalToolGroup>) async {
        selectedToolGroups = selectedGroups
        await ensureWorkspaceAccessIfNeeded()
        let allowedToolNames = await updateCurrentSessionToolOptions()
        AgentOutput.standardError.writeString(Self.renderSelectedToolGroups(selectedToolGroups))
        AgentOutput.standardError.writeString(Self.renderActiveTools(Array(allowedToolNames)))
        didPrintActiveTools = true
    }

    public func printToolSelectionStatus() async {
        let allowedToolNames = await selectedAllowedToolNames()
        AgentOutput.standardError.writeString(Self.renderSelectedToolGroups(selectedToolGroups))
        AgentOutput.standardError.writeString(Self.renderActiveTools(Array(allowedToolNames)))
    }

    public static func toolCheckboxItems() -> [TerminalCheckboxMenuItem<TerminalToolGroup>] {
        TerminalToolGroup.allCases.map { group in
            TerminalCheckboxMenuItem(
                value: group,
                title: group.displayTitle,
                detail: group.description
            )
        }
    }

    public static func parseToolSelection(_ rawSelection: String) throws -> Set<TerminalToolGroup> {
        let tokens = rawSelection
            .replacingOccurrences(of: ",", with: " ")
            .split { $0.isWhitespace }
            .map(String.init)

        guard !tokens.isEmpty else {
            return []
        }

        if tokens.count == 1 {
            let normalizedToken = tokens[0].lowercased()
            if normalizedToken == "all" {
                return Set(TerminalToolGroup.allCases)
            }
            if ["none", "off", "clear", "disabled"].contains(normalizedToken) {
                return []
            }
        }

        var groups = Set<TerminalToolGroup>()
        for token in tokens {
            if let index = Int(token),
               TerminalToolGroup.allCases.indices.contains(index - 1) {
                groups.insert(TerminalToolGroup.allCases[index - 1])
                continue
            }
            guard let group = TerminalToolGroup.group(named: token) else {
                throw TerminalToolSelectionError.unknownToken(token)
            }
            groups.insert(group)
        }
        return groups
    }

    public func applyInitialAgentSelectionIfNeeded() {
        guard let selectedAgent else {
            return
        }
        applyAgentProfile(selectedAgent)
    }

    public func applyInitialSkillSelectionIfNeeded() throws {
        guard let initialSkillSelection = configuration.initialSkillSelection else {
            return
        }

        selectedSkillIDs = try Self.parseSkillSelection(
            initialSkillSelection,
            availableSkills: availableSkills()
        )
    }

    public func handleSkillsCommand(_ command: String) async {
        let rawArguments = String(command.dropFirst("/skills".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if rawArguments.isEmpty {
            guard stdinIsTerminal else {
                printSkillSelectionStatus()
                AgentOutput.standardError.writeString(Self.renderSkillSelectionUsage())
                return
            }

            let skillItems = skillCheckboxItems()
            guard !skillItems.isEmpty else {
                AgentOutput.standardError.writeString("No prompt skills installed by the app.\n")
                printSkillSelectionStatus()
                return
            }
            let selectedSkillIDs = TerminalCheckboxMenu.select(
                title: "Prompt skills",
                items: skillItems,
                selected: selectedSkillIDs,
                reservedBottomRows: statusBar.reservedRowsForOverlay()
            )
            if let selectedSkillIDs {
                await applySkillSelection(selectedSkillIDs)
            } else {
                printSkillSelectionStatus()
            }
            return
        }

        await applySkillSelection(rawArguments)
    }

    public func applySkillSelection(_ rawSelection: String) async {
        do {
            let selectedSkillIDs = try Self.parseSkillSelection(
                rawSelection,
                availableSkills: availableSkills()
            )
            await applySkillSelection(selectedSkillIDs)
        } catch {
            AgentOutput.standardError.writeString("mlx-coder: \(error.localizedDescription)\n")
            AgentOutput.standardError.writeString(Self.renderSkillSelectionUsage())
        }
    }

    public func applySkillSelection(_ selectedSkillIDs: Set<String>) async {
        self.selectedSkillIDs = selectedSkillIDs
        do {
            try await createCurrentSession()
        } catch {
            AgentOutput.standardError.writeString("mlx-coder: \(error.localizedDescription)\n")
        }
        statusBar.reset()
        refreshInitialStatusBarContextWindow()
        printSkillSelectionStatus()
    }

    public func printSkillSelectionStatus() {
        AgentOutput.standardError.writeString(Self.renderSelectedSkills(selectedPromptSkills()))
    }

    public func skillCheckboxItems() -> [TerminalCheckboxMenuItem<String>] {
        availableSkills().map { skill in
            let canonicalName = skill.canonicalName == skill.title
                ? ""
                : " (\(skill.canonicalName))"
            return TerminalCheckboxMenuItem(
                value: skill.id,
                title: "\(skill.title)\(canonicalName)",
                detail: Self.truncatedInline(skill.summary, limit: 96)
            )
        }
    }

    public func availableSkills() -> [MLXPromptSkill] {
        if let availableSkillsCache {
            return availableSkillsCache
        }

        let skills = MLXPromptSkillCatalog.discoverSkills(
            searchRoots: MLXPromptSkillCatalog.appCatalogSearchRoots()
        )
        availableSkillsCache = skills
        return skills
    }

    public func selectedPromptSkills() -> [MLXPromptSkill] {
        let skills = availableSkills()
        guard !selectedSkillIDs.isEmpty else {
            return []
        }

        return skills.filter { selectedSkillIDs.contains($0.id) }
    }

    public static func parseSkillSelection(
        _ rawSelection: String,
        availableSkills: [MLXPromptSkill]
    ) throws -> Set<String> {
        let tokens = rawSelection
            .replacingOccurrences(of: ",", with: " ")
            .split { $0.isWhitespace }
            .map(String.init)

        guard !tokens.isEmpty else {
            return []
        }

        if tokens.count == 1 {
            let normalizedToken = tokens[0].lowercased()
            if normalizedToken == "all" {
                return Set(availableSkills.map(\.id))
            }
            if ["none", "off", "clear", "disabled"].contains(normalizedToken) {
                return []
            }
        }

        var selectedSkillIDs = Set<String>()
        for token in tokens {
            if let index = Int(token),
               availableSkills.indices.contains(index - 1) {
                selectedSkillIDs.insert(availableSkills[index - 1].id)
                continue
            }
            guard let skill = skill(matching: token, in: availableSkills) else {
                throw TerminalSkillSelectionError.unknownToken(token)
            }
            selectedSkillIDs.insert(skill.id)
        }
        return selectedSkillIDs
    }

    public static func skill(
        matching rawToken: String,
        in availableSkills: [MLXPromptSkill]
    ) -> MLXPromptSkill? {
        let token = selectionKey(rawToken)
        guard !token.isEmpty else {
            return nil
        }

        return availableSkills.first { skill in
            token == selectionKey(skill.canonicalName)
                || token == selectionKey(skill.title)
                || skill.sourceHash.hasPrefix(token)
                || skill.id.hasPrefix(token)
        }
    }

    public static func selectionKey(_ value: String) -> String {
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
