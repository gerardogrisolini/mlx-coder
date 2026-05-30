//
//  TerminalChat+Features.swift
//  mlx-coder
//

import Foundation

extension TerminalChat {
    public func handleFeatureCommand(_ command: String) async {
        let rawArguments = String(command.dropFirst("/feature".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if rawArguments.isEmpty {
            guard stdinIsTerminal else {
                await runFeatureManagementTool(
                    name: "feature.list",
                    arguments: ["includeTools": true]
                )
                writeSystemMessage(Self.renderFeatureCommandUsage())
                return
            }
            await runFeatureWizard()
            return
        }

        var tokens = rawArguments.split(separator: " ").map(String.init)
        let action = tokens.removeFirst().lowercased()
        switch action {
        case "list", "ls", "status":
            await printFeatureList()
        case "reload":
            await runFeatureManagementTool(
                name: "feature.reload",
                arguments: ["includeTools": true]
            )
            await updateCurrentSessionToolOptions(discoverExternalTools: false)
            await printFeatureList()
        case "enable", "disable", "build", "validate":
            guard let rawID = tokens.first?.nilIfBlank else {
                writeFailureMessage("mlx-coder: /feature \(action) requires a feature id, name, or list number.\n")
                writeSystemMessage(Self.renderFeatureCommandUsage())
                return
            }
            let id: String
            do {
                id = try await resolvedFeatureID(rawID)
            } catch {
                writeFailureMessage("mlx-coder: \(error.localizedDescription)\n")
                return
            }
            let toolName = "feature.\(action)"
            await runFeatureManagementTool(
                name: toolName,
                arguments: ["id": id]
            )
            if action == "enable" || action == "disable" || action == "build" {
                await updateCurrentSessionToolOptions(discoverExternalTools: false)
                await printFeatureList()
            }
        default:
            writeFailureMessage("mlx-coder: unknown /feature command '\(action)'.\n")
            writeSystemMessage(Self.renderFeatureCommandUsage())
        }
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

    private func runFeatureWizard() async {
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
            return
        }

        guard let id = promptFeatureLine("Feature id", required: true) else {
            writeSystemMessage("Feature creation cancelled.\n")
            return
        }
        let defaultDisplayName = Self.featureWizardDisplayName(from: id)
        guard let displayName = promptFeatureLine(
            "Display name",
            defaultValue: defaultDisplayName
        ) else {
            writeSystemMessage("Feature creation cancelled.\n")
            return
        }
        let description = promptFeatureLine(
            "Description",
            defaultValue: template.defaultDescription(displayName: displayName)
        )
        guard let description else {
            writeSystemMessage("Feature creation cancelled.\n")
            return
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
                return
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
                return
            }
            arguments["serviceName"] = serviceName

            guard let toolPrefix = promptFeatureLine(
                "Tool prefix",
                defaultValue: Self.featureWizardPrefix(from: id)
            ) else {
                writeSystemMessage("Feature creation cancelled.\n")
                return
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
                return
            }

            switch transport {
            case .http:
                guard let endpointURL = promptFeatureLine("MCP endpoint URL", required: true) else {
                    writeSystemMessage("Feature creation cancelled.\n")
                    return
                }
                arguments["endpointURL"] = endpointURL
            case .stdio:
                guard let executablePath = promptFeatureLine("MCP executable path", required: true) else {
                    writeSystemMessage("Feature creation cancelled.\n")
                    return
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

        let shouldBuild = promptFeatureYesNo(
            "Build feature now?",
            defaultValue: template == .mcpBridge
        ) ?? false
        let shouldEnable = shouldBuild
            ? (promptFeatureYesNo("Enable feature after build?", defaultValue: true) ?? false)
            : false
        let shouldSelect = shouldEnable
            ? (promptFeatureYesNo("Select feature for this session?", defaultValue: true) ?? false)
            : false

        await createFeatureFromWizard(
            id: id,
            arguments: arguments,
            shouldBuild: shouldBuild,
            shouldEnable: shouldEnable,
            shouldSelect: shouldSelect
        )
    }

    private func createFeatureFromWizard(
        id: String,
        arguments: [String: Any],
        shouldBuild: Bool,
        shouldEnable: Bool,
        shouldSelect: Bool
    ) async {
        guard await runFeatureManagementTool(
            name: "feature.scaffold",
            arguments: arguments
        ) else {
            return
        }

        guard await runFeatureManagementTool(
            name: "feature.validate",
            arguments: ["id": id]
        ) else {
            return
        }

        if shouldBuild {
            guard await runFeatureManagementTool(
                name: "feature.build",
                arguments: ["id": id]
            ) else {
                return
            }
        }

        if shouldEnable {
            guard await runFeatureManagementTool(
                name: "feature.enable",
                arguments: ["id": id]
            ) else {
                return
            }
            await updateCurrentSessionToolOptions(discoverExternalTools: false)
        }

        if shouldSelect {
            var nextSelection = selectedToolKeys
            nextSelection.insert(TerminalToolSelectionCatalog.featurePackageKey(id: id))
            await applyToolSelection(nextSelection)
        }
    }

    @discardableResult
    private func runFeatureManagementTool(
        name: String,
        arguments: [String: Any]
    ) async -> Bool {
        do {
            let output = try await SwiftFeatureRuntime().executeManagementTool(
                toolCall: DirectAgentToolCall(
                    id: "terminal-\(name)-\(UUID().uuidString)",
                    name: name,
                    argumentsObject: arguments,
                    argumentsJSON: jsonString(from: arguments)
                )
            )
            writeSystemMessage("\(output.trimmingCharacters(in: .whitespacesAndNewlines))\n")
            return true
        } catch {
            writeFailureMessage("mlx-coder: \(error.localizedDescription)\n")
            return false
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
        "Usage: /feature [list|reload|enable <id|name|#>|disable <id|name|#>|build <id|name|#>|validate <id|name|#>]\n"
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
        lines.append("\nUse /feature enable <id|name|#> or /feature disable <id|name|#>.\n")
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
