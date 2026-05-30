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
                writeSystemMessage(Self.renderToolSelectionUsage())
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
            writeChatError("mlx-coder: \(error.localizedDescription)\n")
            writeSystemMessage(Self.renderToolSelectionUsage())
        }
    }

    public func applyToolSelection(_ selectedGroups: Set<TerminalToolGroup>) async {
        let previousGroups = selectedToolGroups
        selectedToolGroups = selectedGroups
        await ensureWorkspaceAccessIfNeeded()
        let shouldDiscoverExternalTools = Self.shouldDiscoverExternalTools(
            previousGroups: previousGroups,
            selectedGroups: selectedToolGroups
        )
        let allowedToolNames = await updateCurrentSessionToolOptions(
            discoverExternalTools: shouldDiscoverExternalTools
        )
        writeSystemMessage(Self.renderSelectedToolGroups(selectedToolGroups))
        writeSystemMessage(Self.renderActiveTools(Array(allowedToolNames)))
        didPrintActiveTools = true
    }

    public func printToolSelectionStatus() async {
        let allowedToolNames = await selectedAllowedToolNames(
            discoverExternalTools: false
        )
        writeSystemMessage(Self.renderSelectedToolGroups(selectedToolGroups))
        writeSystemMessage(Self.renderActiveTools(Array(allowedToolNames)))
    }

    public static func shouldDiscoverExternalTools(
        previousGroups: Set<TerminalToolGroup>,
        selectedGroups: Set<TerminalToolGroup>
    ) -> Bool {
        let externalGroups: Set<TerminalToolGroup> = [.xcode, .figma]
        let newlySelectedExternalGroups = selectedGroups
            .intersection(externalGroups)
            .subtracting(previousGroups)
        return !newlySelectedExternalGroups.isEmpty
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

        if Self.isSkillInstallRequest(rawArguments),
           Self.githubSkillInstallURL(from: rawArguments) == nil,
           Self.localSkillInstallURL(
               from: rawArguments,
               baseDirectory: configuration.workingDirectory
           ) == nil {
            writeChatError("mlx-coder: /skills install requires a GitHub URL or local path.\n")
            writeSystemMessage(Self.renderSkillSelectionUsage())
            return
        }

        if let installURL = Self.githubSkillInstallURL(from: rawArguments) {
            await installSkill(fromGitHubURL: installURL)
            return
        }

        if let localURL = Self.localSkillInstallURL(
            from: rawArguments,
            baseDirectory: configuration.workingDirectory
        ) {
            await installSkill(fromLocalURL: localURL)
            return
        }

        if rawArguments.isEmpty {
            guard stdinIsTerminal else {
                printSkillSelectionStatus()
                writeSystemMessage(Self.renderSkillSelectionUsage())
                return
            }

            let skillItems = skillCheckboxItems()
            guard !skillItems.isEmpty else {
                writeSystemMessage("No prompt skills installed by the app.\n")
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

    public func installSkill(fromGitHubURL url: URL) async {
        writeSystemMessage("Installing skill from \(url.absoluteString)...\n")
        do {
            let result = try await MLXPromptSkillInstaller.install(fromGitHubURL: url)
            await finishInstalledSkill(result)
        } catch {
            writeChatError("mlx-coder: \(error.localizedDescription)\n")
            writeSystemMessage(Self.renderSkillSelectionUsage())
        }
    }

    public func installSkill(fromLocalURL url: URL) async {
        writeSystemMessage("Installing skill from \(url.path)...\n")
        do {
            let result = try MLXPromptSkillInstaller.install(fromLocalURL: url)
            await finishInstalledSkill(result)
        } catch {
            writeChatError("mlx-coder: \(error.localizedDescription)\n")
            writeSystemMessage(Self.renderSkillSelectionUsage())
        }
    }

    private func finishInstalledSkill(_ result: MLXPromptSkillInstallResult) async {
        availableSkillsCache = nil
        selectedSkillIDs.insert(result.skill.id)
        do {
            try await createCurrentSession()
        } catch {
            writeChatError("mlx-coder: \(error.localizedDescription)\n")
        }
        statusBar.reset()
        refreshInitialStatusBarContextWindow()
        writeSystemMessage(
            "Installed and selected skill: \(result.skill.title)\n"
        )
    }

    public func applySkillSelection(_ rawSelection: String) async {
        do {
            let selectedSkillIDs = try Self.parseSkillSelection(
                rawSelection,
                availableSkills: availableSkills()
            )
            await applySkillSelection(selectedSkillIDs)
        } catch {
            writeChatError("mlx-coder: \(error.localizedDescription)\n")
            writeSystemMessage(Self.renderSkillSelectionUsage())
        }
    }

    public func applySkillSelection(_ selectedSkillIDs: Set<String>) async {
        self.selectedSkillIDs = selectedSkillIDs
        do {
            try await createCurrentSession()
        } catch {
            writeChatError("mlx-coder: \(error.localizedDescription)\n")
        }
        statusBar.reset()
        refreshInitialStatusBarContextWindow()
        printSkillSelectionStatus()
    }

    public func printSkillSelectionStatus() {
        writeSystemMessage(Self.renderSelectedSkills(selectedPromptSkills()))
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

    public static func githubSkillInstallURL(from rawArguments: String) -> URL? {
        guard let rawValue = skillInstallValue(from: rawArguments),
              let urlToken = rawValue.split(whereSeparator: \.isWhitespace).first.map(String.init) else {
            return nil
        }

        guard let url = URL(string: urlToken),
              let host = url.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else {
            return nil
        }
        return url
    }

    public static func localSkillInstallURL(
        from rawArguments: String,
        baseDirectory: URL
    ) -> URL? {
        guard let rawValue = skillInstallValue(from: rawArguments) else {
            return nil
        }

        if rawValue.lowercased().hasPrefix("file://"),
           let url = URL(string: rawValue),
           url.isFileURL {
            return url.standardizedFileURL
        }

        if rawValue.hasPrefix("~/") {
            let expandedPath = NSString(string: rawValue).expandingTildeInPath
            return URL(fileURLWithPath: expandedPath, isDirectory: true)
                .standardizedFileURL
        }

        if rawValue.hasPrefix("/") {
            return URL(fileURLWithPath: rawValue, isDirectory: true)
                .standardizedFileURL
        }

        if rawValue == "."
            || rawValue == ".."
            || rawValue.hasPrefix("./")
            || rawValue.hasPrefix("../") {
            return baseDirectory
                .appendingPathComponent(rawValue, isDirectory: true)
                .standardizedFileURL
        }

        return nil
    }

    public static func isSkillInstallRequest(_ rawArguments: String) -> Bool {
        let tokens = rawArguments
            .split { $0.isWhitespace }
        guard let command = tokens.first?.lowercased() else {
            return false
        }
        return ["install", "add"].contains(command)
    }

    public static func skillInstallValue(from rawArguments: String) -> String? {
        let trimmedArguments = rawArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedArguments.isEmpty else {
            return nil
        }

        guard let commandEndIndex = trimmedArguments.firstIndex(where: \.isWhitespace) else {
            return isSkillInstallRequest(trimmedArguments) ? nil : trimmedArguments
        }

        let command = trimmedArguments[..<commandEndIndex].lowercased()
        guard ["install", "add"].contains(command) else {
            return trimmedArguments
        }

        let value = trimmedArguments[commandEndIndex...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
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
