//
//  TerminalChat+Features.swift
//  mlx-coder
//

import Foundation

enum TerminalFeatureCommandResult: Sendable {
    case none
    case runPrompt(String)
    case prefillPrompt(String)
}

extension TerminalChat {
    func handleFeatureCommand(_ command: String) async -> TerminalFeatureCommandResult {
        let rawArguments = String(command.dropFirst("/feature".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if Self.featureCommandRequiresActiveBuilder(rawArguments: rawArguments),
           !(await featureBuilderIsActive()) {
            writeFailureMessage(Self.renderFeatureBuilderInactiveWarning())
            return .none
        }

        if rawArguments.isEmpty {
            guard stdinIsTerminal else {
                await runFeatureManagementTool(
                    name: "feature.list",
                    arguments: ["includeTools": true]
                )
                writeSystemMessage(Self.renderFeatureCommandUsage())
                return .none
            }
            return await runFeatureWizard()
        }

        var tokens = rawArguments.split(separator: " ").map(String.init)
        let action = tokens.removeFirst().lowercased()
        switch action {
        case "list", "ls", "status":
            await printFeatureList()
            return .none
        case "reload":
            await runFeatureManagementTool(
                name: "feature.reload",
                arguments: ["includeTools": true]
            )
            await updateCurrentSessionToolOptions(discoverExternalTools: false)
            await printFeatureList()
            return .none
        case "enable", "disable", "delete", "build", "validate":
            guard let rawID = tokens.first?.nilIfBlank else {
                writeFailureMessage("mlx-coder: /feature \(action) requires a feature id, name, or list number.\n")
                writeSystemMessage(Self.renderFeatureCommandUsage())
                return .none
            }
            let id: String
            do {
                id = try await resolvedFeatureID(rawID)
            } catch {
                writeFailureMessage("mlx-coder: \(error.localizedDescription)\n")
                return .none
            }
            let toolName = "feature.\(action)"
            let didSucceed = await runFeatureManagementTool(
                name: toolName,
                arguments: ["id": id]
            )
            if didSucceed, action == "delete" {
                selectedToolKeys.remove(TerminalToolSelectionCatalog.featurePackageKey(id: id))
            }
            if didSucceed,
               action == "enable" || action == "disable" || action == "delete" || action == "build" {
                await updateCurrentSessionToolOptions(discoverExternalTools: false)
                await printFeatureList()
            }
            return .none
        default:
            writeFailureMessage("mlx-coder: unknown /feature command '\(action)'.\n")
            writeSystemMessage(Self.renderFeatureCommandUsage())
            return .none
        }
    }

    private func featureBuilderIsActive() async -> Bool {
        AgentProfileStore.isBuilderAgent(selectedAgent)
    }

    private func printFeatureList() async {
        let statuses = await SwiftFeatureRuntime().featureStatuses(
            includeTools: true,
            includeDisabled: true
        )
        writeSystemMessage(Self.renderFeatureStatusList(statuses))
    }

    private func resolvedFeatureID(_ rawValue: String) async throws -> String {
        let statuses = await SwiftFeatureRuntime().featureStatuses(
            includeTools: false,
            includeDisabled: true
        )
        return try Self.resolvedFeatureID(rawValue, statuses: statuses)
    }

    private func runFeatureWizard() async -> TerminalFeatureCommandResult {
        guard let template = TerminalCheckboxMenu.selectOne(
            title: "Feature template",
            items: [
                TerminalCheckboxMenuItem(
                    value: FeatureWizardTemplate.mcpBridge,
                    title: "MCP Bridge",
                    detail: "Expose tools from an HTTP or stdio MCP service"
                ),
                TerminalCheckboxMenuItem(
                    value: FeatureWizardTemplate.basic,
                    title: "Basic Swift Feature",
                    detail: "Create a small editable Swift tool scaffold"
                )
            ],
            selected: .mcpBridge,
            reservedBottomRows: statusBar.reservedRowsForOverlay()
        ) else {
            writeSystemMessage("Feature creation cancelled.\n")
            return .none
        }

        guard let id = promptFeatureLine("Feature id", required: true) else {
            writeSystemMessage("Feature creation cancelled.\n")
            return .none
        }
        let defaultDisplayName = Self.featureWizardDisplayName(from: id)
        guard let displayName = promptFeatureLine(
            "Display name",
            defaultValue: defaultDisplayName
        ) else {
            writeSystemMessage("Feature creation cancelled.\n")
            return .none
        }
        let description = promptFeatureLine(
            "Description",
            defaultValue: template.defaultDescription(displayName: displayName)
        )
        guard let description else {
            writeSystemMessage("Feature creation cancelled.\n")
            return .none
        }

        var arguments: [String: Any] = [
            "id": id,
            "displayName": displayName,
            "description": description
        ]

        switch template {
        case .basic:
            let defaultToolName = "\(Self.featureWizardPrefix(from: id))run"
            guard let toolName = promptFeatureLine(
                "Tool name",
                defaultValue: defaultToolName
            ) else {
                writeSystemMessage("Feature creation cancelled.\n")
                return .none
            }
            arguments["toolName"] = toolName
        case .mcpBridge:
            arguments["template"] = "mcp-bridge"
            let serviceName = promptFeatureLine(
                "Service name",
                defaultValue: displayName
            )
            guard let serviceName else {
                writeSystemMessage("Feature creation cancelled.\n")
                return .none
            }
            arguments["serviceName"] = serviceName

            guard let toolPrefix = promptFeatureLine(
                "Tool prefix",
                defaultValue: Self.featureWizardPrefix(from: id)
            ) else {
                writeSystemMessage("Feature creation cancelled.\n")
                return .none
            }
            arguments["toolPrefix"] = toolPrefix

            guard let transport = TerminalCheckboxMenu.selectOne(
                title: "MCP transport",
                items: [
                    TerminalCheckboxMenuItem(
                        value: FeatureWizardTransport.http,
                        title: "HTTP",
                        detail: "Connect to an MCP endpoint URL"
                    ),
                    TerminalCheckboxMenuItem(
                        value: FeatureWizardTransport.stdio,
                        title: "Stdio",
                        detail: "Launch an MCP server executable"
                    )
                ],
                selected: .http,
                reservedBottomRows: statusBar.reservedRowsForOverlay()
            ) else {
                writeSystemMessage("Feature creation cancelled.\n")
                return .none
            }

            switch transport {
            case .http:
                guard let endpointURL = promptFeatureLine("MCP endpoint URL", required: true) else {
                    writeSystemMessage("Feature creation cancelled.\n")
                    return .none
                }
                arguments["endpointURL"] = endpointURL
            case .stdio:
                guard let executablePath = promptFeatureLine("MCP executable path", required: true) else {
                    writeSystemMessage("Feature creation cancelled.\n")
                    return .none
                }
                arguments["executablePath"] = executablePath
                if let rawArguments = promptFeatureLine("Executable arguments", defaultValue: "") {
                    let parsedArguments = Self.featureWizardArguments(rawArguments)
                    if !parsedArguments.isEmpty {
                        arguments["arguments"] = parsedArguments
                    }
                }
                if let rawEnvironment = promptFeatureLine("Environment KEY=value pairs", defaultValue: "") {
                    let parsedEnvironment = Self.featureWizardEnvironment(rawEnvironment)
                    if !parsedEnvironment.isEmpty {
                        arguments["environment"] = parsedEnvironment
                    }
                }
            }
        }

        let shouldBuild = true
        let shouldEnable = promptFeatureYesNo("Enable feature after build?", defaultValue: true) ?? false
        let shouldSelect = shouldEnable
            ? (promptFeatureYesNo("Select feature for this session?", defaultValue: true) ?? false)
            : false
        guard let requirements = promptFeatureLine(
            "Goal / requirements (empty to edit the generated prompt)",
            required: false
        ) else {
            writeSystemMessage("Feature creation cancelled.\n")
            return .none
        }

        return await createFeatureFromWizard(
            id: id,
            displayName: displayName,
            arguments: arguments,
            shouldBuild: shouldBuild,
            shouldEnable: shouldEnable,
            shouldSelect: shouldSelect,
            requirements: requirements.nilIfBlank
        )
    }

    private func createFeatureFromWizard(
        id: String,
        displayName: String,
        arguments: [String: Any],
        shouldBuild: Bool,
        shouldEnable: Bool,
        shouldSelect: Bool,
        requirements: String?
    ) async -> TerminalFeatureCommandResult {
        guard let scaffoldOutput = await executeFeatureManagementTool(
            name: "feature.scaffold",
            arguments: arguments
        ) else {
            return .none
        }
        writeSystemMessage(Self.renderFeatureManagementToolOutput(name: "feature.scaffold", output: scaffoldOutput))
        guard let scaffoldReport = Self.decodeFeatureOutput(
            SwiftFeatureScaffoldReport.self,
            from: scaffoldOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            return .none
        }

        guard await runFeatureManagementTool(
            name: "feature.validate",
            arguments: ["id": id]
        ) else {
            return .none
        }

        if shouldBuild {
            guard await runFeatureManagementTool(
                name: "feature.build",
                arguments: ["id": id]
            ) else {
                return .none
            }
        }

        if shouldEnable {
            guard await runFeatureManagementTool(
                name: "feature.enable",
                arguments: ["id": id]
            ) else {
                return .none
            }
            await updateCurrentSessionToolOptions(discoverExternalTools: false)
        }

        if shouldSelect {
            var nextSelection = selectedToolKeys
            nextSelection.insert(TerminalToolSelectionCatalog.featurePackageKey(id: id))
            await applyToolSelection(nextSelection)
        }

        writeSystemMessage(
            Self.renderFeatureWizardCompletion(
                id: id,
                built: shouldBuild,
                enabled: shouldEnable,
                selected: shouldSelect
            )
        )

        let implementationPrompt = Self.featureImplementationPrompt(
            id: id,
            displayName: displayName,
            directoryPath: scaffoldReport.directoryPath,
            manifestPath: scaffoldReport.manifestPath,
            sourcePath: scaffoldReport.sourcePath,
            toolName: scaffoldReport.toolName,
            requirements: requirements
        )
        if requirements != nil {
            return .runPrompt(implementationPrompt)
        }
        return .prefillPrompt(implementationPrompt)
    }

    @discardableResult
    private func runFeatureManagementTool(
        name: String,
        arguments: [String: Any]
    ) async -> Bool {
        guard let output = await executeFeatureManagementTool(
            name: name,
            arguments: arguments
        ) else {
            return false
        }
        writeSystemMessage(Self.renderFeatureManagementToolOutput(name: name, output: output))
        return Self.featureManagementToolSucceeded(name: name, output: output)
    }

    private func executeFeatureManagementTool(
        name: String,
        arguments: [String: Any]
    ) async -> String? {
        do {
            return try await SwiftFeatureRuntime().executeManagementTool(
                toolCall: DirectAgentToolCall(
                    id: "terminal-\(name)-\(UUID().uuidString)",
                    name: name,
                    argumentsObject: arguments,
                    argumentsJSON: jsonString(from: arguments)
                )
            )
        } catch {
            writeFailureMessage("mlx-coder: \(error.localizedDescription)\n")
            return nil
        }
    }

    private func promptFeatureLine(
        _ label: String,
        defaultValue: String? = nil,
        required: Bool = false
    ) -> String? {
        while true {
            let prompt = defaultValue?.isEmpty == false
                ? "\(label) [\(defaultValue!)]: "
                : "\(label): "
            guard let line = interactiveReader.readLine(prompt: prompt) else {
                return nil
            }
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
            if let defaultValue {
                return defaultValue
            }
            guard required else {
                return ""
            }
            writeFailureMessage("mlx-coder: \(label) is required.\n")
        }
    }

    private func promptFeatureYesNo(
        _ label: String,
        defaultValue: Bool
    ) -> Bool? {
        let suffix = defaultValue ? "Y/n" : "y/N"
        while true {
            guard let line = interactiveReader.readLine(prompt: "\(label) [\(suffix)]: ") else {
                return nil
            }
            switch line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "":
                return defaultValue
            case "y", "yes", "true", "1", "s", "si", "sì":
                return true
            case "n", "no", "false", "0":
                return false
            default:
                writeFailureMessage("mlx-coder: answer yes or no.\n")
            }
        }
    }

    public static func renderFeatureCommandUsage() -> String {
        "Usage: /feature [list|reload|enable <id|name|#>|disable <id|name|#>|delete <id|name|#>|build <id|name|#>|validate <id|name|#>]\n"
    }

    public static func renderFeatureBuilderInactiveWarning() -> String {
        renderFeatureCommandUnavailableForAgent()
    }

    public static func renderFeatureCommandUnavailableForAgent() -> String {
        "mlx-coder: /feature is only available with the Builder agent. Switch with /agents Builder.\n"
    }

    public static func renderFeatureWizardCompletion(
        id: String,
        built: Bool,
        enabled: Bool,
        selected: Bool
    ) -> String {
        var actions = ["created", "validated"]
        if built {
            actions.append("built")
        }
        if enabled {
            actions.append("enabled")
        }
        if selected {
            actions.append("selected")
        }

        var lines = ["Feature '\(id)' \(actions.joined(separator: ", "))."]
        if !enabled {
            lines.append("It is not active yet. Enable it with /feature enable \(id), then select it from /tools.")
        } else if !selected {
            lines.append("It is enabled. Select it from /tools to expose its tools in this session.")
        } else {
            lines.append("It is active in this session.")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func featureImplementationPrompt(
        id: String,
        displayName: String,
        directoryPath: String,
        manifestPath: String,
        sourcePath: String,
        toolName: String,
        requirements: String?
    ) -> String {
        var sections = [
            """
            Implementa la feature Swift "\(displayName)" (`\(id)`).

            Feature directory:
            \(directoryPath)

            File principali:
            - Manifest: \(manifestPath)
            - Sorgente: \(sourcePath)
            - Tool: \(toolName)

            Lavora sul pacchetto Swift esistente usando i tool file/text disponibili.
            Mantieni Swift tools 6.3, aggiorna descrizione e JSON schema del tool se necessario, poi esegui `feature.validate` e `feature.build` per `\(id)`.
            Se tutto passa, abilita la feature con `feature.enable` e dimmi se devo selezionarla da `/tools` per provarla nella sessione corrente.
            """
        ]

        if let requirements {
            sections.append(
                """

                Goal / requirements:
                \(requirements)
                """
            )
        } else {
            sections.append(
                """

                Goal / requirements:
                """
            )
        }

        return sections.joined()
    }

    public static func renderFeatureManagementToolOutput(
        name: String,
        output: String
    ) -> String {
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutput.isEmpty else {
            return ""
        }

        switch name {
        case "feature.scaffold":
            if let report = decodeFeatureOutput(SwiftFeatureScaffoldReport.self, from: trimmedOutput) {
                return """
                Created Swift feature '\(report.id)'.
                  Source: \(report.directoryPath)
                  Tool: \(report.toolName)

                """
            }
        case "feature.validate":
            if let report = decodeFeatureOutput(SwiftFeatureValidationReport.self, from: trimmedOutput) {
                return renderFeatureValidationReport(report)
            }
        case "feature.build":
            if let report = decodeFeatureOutput(SwiftFeatureBuildReport.self, from: trimmedOutput) {
                return renderFeatureBuildReport(report)
            }
        case "feature.install":
            if let report = decodeFeatureOutput(SwiftFeatureInstallReport.self, from: trimmedOutput) {
                return renderFeatureInstallReport(report)
            }
        case "feature.delete":
            if let report = decodeFeatureOutput(SwiftFeatureDeleteReport.self, from: trimmedOutput) {
                return renderFeatureDeleteReport(report)
            }
        case "feature.list", "feature.reload":
            return renderFeatureListToolOutput(name: name, output: trimmedOutput)
        case "feature.enable", "feature.disable":
            return renderFeatureMutationToolOutput(output: trimmedOutput)
        default:
            break
        }

        return trimmedOutput + "\n"
    }

    public static func featureManagementToolSucceeded(
        name: String,
        output: String
    ) -> Bool {
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "feature.validate":
            return decodeFeatureOutput(SwiftFeatureValidationReport.self, from: trimmedOutput)?.ok ?? true
        case "feature.build":
            return decodeFeatureOutput(SwiftFeatureBuildReport.self, from: trimmedOutput)?.ok ?? true
        case "feature.install":
            return decodeFeatureOutput(SwiftFeatureInstallReport.self, from: trimmedOutput)?.ok ?? true
        case "feature.delete":
            return decodeFeatureOutput(SwiftFeatureDeleteReport.self, from: trimmedOutput)?.ok ?? true
        default:
            return true
        }
    }

    public static func featureCommandRequiresActiveBuilder(rawArguments _: String) -> Bool {
        true
    }

    private static func renderFeatureValidationReport(
        _ report: SwiftFeatureValidationReport
    ) -> String {
        let id = report.id ?? "unknown"
        guard report.ok else {
            var lines = ["Validation failed for Swift feature '\(id)'."]
            lines.append(contentsOf: report.errors.map { "  Error: \($0)" })
            return lines.joined(separator: "\n") + "\n"
        }

        let warnings = report.warnings.filter {
            !$0.hasPrefix("Executable has not been built yet:")
        }
        var lines = ["Validated Swift feature '\(id)'."]
        if !warnings.isEmpty {
            lines.append(contentsOf: warnings.map { "  Warning: \($0)" })
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func renderFeatureBuildReport(
        _ report: SwiftFeatureBuildReport
    ) -> String {
        guard report.ok else {
            var lines = ["Build failed for Swift feature '\(report.id)' (exit code \(report.exitCode))."]
            let error = report.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !error.isEmpty {
                lines.append("  \(truncatedInline(error, limit: 180))")
            }
            return lines.joined(separator: "\n") + "\n"
        }

        return """
        Built Swift feature '\(report.id)'.
          Executable: \(report.executablePath)

        """
    }

    private static func renderFeatureInstallReport(
        _ report: SwiftFeatureInstallReport
    ) -> String {
        guard report.ok else {
            return "Install failed for Swift feature '\(report.id)'.\n"
        }
        var states = ["installed"]
        if report.built {
            states.append("built")
        }
        if report.enabled {
            states.append("enabled")
        }
        return """
        Feature '\(report.id)' \(states.joined(separator: ", ")).
          Destination: \(report.destinationPath)

        """
    }

    private static func renderFeatureDeleteReport(
        _ report: SwiftFeatureDeleteReport
    ) -> String {
        guard report.ok else {
            return "Delete failed for Swift feature '\(report.id)'.\n"
        }
        return """
        Deleted Swift feature '\(report.id)'.
          Removed: \(report.directoryPath)

        """
    }

    private static func renderFeatureListToolOutput(
        name: String,
        output: String
    ) -> String {
        let prefix: String?
        let json: String
        if let jsonStart = output.firstIndex(of: "{") {
            let head = output[..<jsonStart].trimmingCharacters(in: .whitespacesAndNewlines)
            prefix = head.isEmpty ? nil : String(head)
            json = String(output[jsonStart...])
        } else {
            prefix = nil
            json = output
        }

        if let payload = decodeFeatureOutput(TerminalFeatureListPayload.self, from: json) {
            let renderedList = renderFeatureStatusList(payload.features)
            if let prefix {
                return "\(prefix)\n\(renderedList)"
            }
            return renderedList
        }
        return name == "feature.reload"
            ? "Reloaded Swift features.\n"
            : output + "\n"
    }

    private static func renderFeatureMutationToolOutput(output: String) -> String {
        guard let firstLine = output.split(separator: "\n").first.map(String.init)?.nilIfBlank else {
            return output + "\n"
        }
        return "\(firstLine)\n"
    }

    private static func decodeFeatureOutput<T: Decodable>(
        _ type: T.Type,
        from output: String
    ) -> T? {
        guard let data = output.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    public static func renderFeatureStatusList(
        _ statuses: [SwiftFeatureStatus]
    ) -> String {
        guard !statuses.isEmpty else {
            return "Features: none\n"
        }

        var lines = ["Features:\n"]
        for (offset, status) in statuses.sorted(by: featureStatusSortOrder).enumerated() {
            let availability = status.available ? "" : ", unavailable"
            let state = status.enabled ? "enabled" : "disabled"
            let source = status.source == .bundled ? "bundled" : "generated"
            let tools = featureStatusToolsSummary(status)
            lines.append(
                "  \(offset + 1). \(featureDisplayName(status)) [\(status.id)] - \(state)\(availability), \(source)\(tools)\n"
            )
        }
        lines.append("\nUse /feature enable <id|name|#>, /feature disable <id|name|#>, or /feature delete <id|name|#>.\n")
        return lines.joined()
    }

    public static func resolvedFeatureID(
        _ rawValue: String,
        statuses: [SwiftFeatureStatus]
    ) throws -> String {
        let token = normalizedFeatureLookupKey(rawValue)
        guard !token.isEmpty else {
            throw TerminalFeatureCommandError.unknownFeature(rawValue)
        }
        if let index = Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
           statuses.indices.contains(index - 1) {
            return statuses.sorted(by: featureStatusSortOrder)[index - 1].id
        }

        if let status = statuses.first(where: { status in
            featureLookupKeys(status).contains(token)
        }) {
            return status.id
        }
        throw TerminalFeatureCommandError.unknownFeature(rawValue)
    }

    private static func featureWizardDisplayName(from id: String) -> String {
        id.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { word in word.prefix(1).uppercased() + word.dropFirst() }
            .joined(separator: " ")
    }

    private static func featureWizardPrefix(from id: String) -> String {
        let value = id
            .lowercased()
            .map { character -> Character in
                character.isLetter || character.isNumber ? character : "_"
            }
        let prefix = String(value)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return "\(prefix.nilIfBlank ?? "feature")."
    }

    private static func featureWizardArguments(_ rawValue: String) -> [String] {
        rawValue
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func featureWizardEnvironment(_ rawValue: String) -> [String: String] {
        var environment: [String: String] = [:]
        for entry in rawValue.split(separator: " ").map(String.init) {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  !parts[0].isEmpty else {
                continue
            }
            environment[parts[0]] = parts[1]
        }
        return environment
    }

    private static func featureDisplayName(_ status: SwiftFeatureStatus) -> String {
        if let displayName = status.displayName?.nilIfBlank {
            return displayName
        }
        switch status.id {
        case "mlx-search-tools":
            return "Search"
        case "mlx-web-tools":
            return "Web"
        case "mlx-git-tools":
            return "Git"
        case "mlx-xcode-tools":
            return "Xcode"
        case "mlx-figma-tools":
            return "Figma"
        default:
            return featureWizardDisplayName(from: status.id)
        }
    }

    private static func featureLookupKeys(_ status: SwiftFeatureStatus) -> Set<String> {
        var keys: Set<String> = [
            normalizedFeatureLookupKey(status.id),
            normalizedFeatureLookupKey(featureDisplayName(status))
        ]
        if status.id.hasPrefix("mlx-"), status.id.hasSuffix("-tools") {
            let shortID = status.id
                .dropFirst("mlx-".count)
                .dropLast("-tools".count)
            keys.insert(normalizedFeatureLookupKey(String(shortID)))
        }
        return keys.filter { !$0.isEmpty }
    }

    private static func normalizedFeatureLookupKey(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        .unicodeScalars
        .map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        .reduce(into: "") { $0.append($1) }
        .replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func featureStatusSortOrder(
        lhs: SwiftFeatureStatus,
        rhs: SwiftFeatureStatus
    ) -> Bool {
        featureDisplayName(lhs).localizedStandardCompare(featureDisplayName(rhs)) == .orderedAscending
    }

    private static func featureStatusToolsSummary(_ status: SwiftFeatureStatus) -> String {
        if !status.tools.isEmpty {
            let sample = status.tools.prefix(3).joined(separator: ", ")
            let suffix = status.tools.count > 3 ? ", ..." : ""
            let toolLabel = status.tools.count == 1 ? "tool" : "tools"
            return ", \(status.tools.count) \(toolLabel): \(sample)\(suffix)"
        }
        if status.discoversToolsAtRuntime {
            return ", discovers tools at runtime"
        }
        return ""
    }
}

private struct TerminalFeatureListPayload: Decodable {
    let features: [SwiftFeatureStatus]
}

private enum FeatureWizardTemplate: Hashable {
    case mcpBridge
    case basic

    func defaultDescription(displayName: String) -> String {
        switch self {
        case .mcpBridge:
            return "MCP bridge feature for \(displayName)."
        case .basic:
            return "Swift feature generated for mlx-coder."
        }
    }
}

private enum FeatureWizardTransport: Hashable {
    case http
    case stdio
}

public enum TerminalFeatureCommandError: LocalizedError {
    case unknownFeature(String)

    public var errorDescription: String? {
        switch self {
        case let .unknownFeature(value):
            return "Unknown feature '\(value)'. Use /feature list to see available feature ids."
        }
    }
}
