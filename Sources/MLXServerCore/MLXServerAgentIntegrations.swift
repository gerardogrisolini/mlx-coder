//
//  MLXServerAgentIntegrations.swift
//  mlx-server
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum MLXServerCodexConfigurationTarget: Sendable, Equatable {
    case desktop
    case xcode
}

public struct MLXServerAgentIntegrationConfiguration: Sendable, Equatable {
    public var baseURL: String
    public var modelID: String
    public var contextWindow: Int?
    public var apiKey: String?

    public init(
        baseURL: String,
        modelID: String,
        contextWindow: Int? = nil,
        apiKey: String? = nil
    ) {
        self.baseURL = baseURL
        self.modelID = modelID
        self.contextWindow = contextWindow
        self.apiKey = apiKey
    }
}

public struct MLXServerAgentIntegrationStatus: Sendable, Equatable {
    public var codexCLIEnabled: Bool
    public var codexAppEnabled: Bool
    public var codexXcodeAppEnabled: Bool
    public var xcodeClaudeCodeEnabled: Bool
    public var aionUIACPAgentsEnabled: Bool

    public init(
        codexCLIEnabled: Bool,
        codexAppEnabled: Bool,
        codexXcodeAppEnabled: Bool,
        xcodeClaudeCodeEnabled: Bool,
        aionUIACPAgentsEnabled: Bool = false
    ) {
        self.codexCLIEnabled = codexCLIEnabled
        self.codexAppEnabled = codexAppEnabled
        self.codexXcodeAppEnabled = codexXcodeAppEnabled
        self.xcodeClaudeCodeEnabled = xcodeClaudeCodeEnabled
        self.aionUIACPAgentsEnabled = aionUIACPAgentsEnabled
    }
}

public struct MLXServerAionUIAgentIntegrationResult: Sendable, Equatable {
    public var registeredCustomAgents: [String]
    public var updatedCustomAgents: [String]
    public var removedDuplicateCustomAgents: [String]
    public var skippedCustomAgents: [String]
    public var updatedChannelAgents: [String]
    public var preparedChannelSessions: [String]
    public var installedExtension: Bool
    public var requiresAionUIRestart: Bool

    public init(
        registeredCustomAgents: [String] = [],
        updatedCustomAgents: [String] = [],
        removedDuplicateCustomAgents: [String] = [],
        skippedCustomAgents: [String] = [],
        updatedChannelAgents: [String] = [],
        preparedChannelSessions: [String] = [],
        installedExtension: Bool = false,
        requiresAionUIRestart: Bool = false
    ) {
        self.registeredCustomAgents = registeredCustomAgents
        self.updatedCustomAgents = updatedCustomAgents
        self.removedDuplicateCustomAgents = removedDuplicateCustomAgents
        self.skippedCustomAgents = skippedCustomAgents
        self.updatedChannelAgents = updatedChannelAgents
        self.preparedChannelSessions = preparedChannelSessions
        self.installedExtension = installedExtension
        self.requiresAionUIRestart = requiresAionUIRestart
    }
}

public enum MLXServerAgentIntegrationService {
    public static let codexProviderID = "mlx-server"
    public static let codexCLIProfileName = "mlx-server"
    public static let codexAppProfileName = "mlx-server-codex-app"
    public static let codexModelCatalogFilename = "mlx-server-codex-models.json"
    static let aionUIHealthCheckTimeout: TimeInterval = 2
    static let aionUIAPIRequestTimeout: TimeInterval = 30

    public static func status(
        homeDirectory: URL = defaultHomeDirectory(),
        fileManager: FileManager = .default
    ) -> MLXServerAgentIntegrationStatus {
        MLXServerAgentIntegrationStatus(
            codexCLIEnabled: codexCLIProfileUsesMLXServer(
                homeDirectory: homeDirectory
            ),
            codexAppEnabled: codexAppProfileUsesMLXServer(
                target: .desktop,
                homeDirectory: homeDirectory
            ),
            codexXcodeAppEnabled: codexAppProfileUsesMLXServer(
                target: .xcode,
                homeDirectory: homeDirectory
            ),
            xcodeClaudeCodeEnabled: fileManager.fileExists(
                atPath: xcodeClaudeCodeSettingsURL(homeDirectory: homeDirectory).path
            ),
            aionUIACPAgentsEnabled: aionUIACPAgentsEnabled(
                homeDirectory: homeDirectory,
                fileManager: fileManager
            )
        )
    }

    public static func configureCodexCLIProfile(
        configuration: MLXServerAgentIntegrationConfiguration,
        homeDirectory: URL = defaultHomeDirectory()
    ) throws {
        try configureCodexProfile(
            profileName: codexCLIProfileName,
            target: .desktop,
            configuration: configuration,
            includeForcedLoginMethod: true,
            homeDirectory: homeDirectory
        )
    }

    public static func removeCodexCLIProfile(
        homeDirectory: URL = defaultHomeDirectory()
    ) throws {
        try removeCodexProfile(
            profileName: codexCLIProfileName,
            target: .desktop,
            homeDirectory: homeDirectory
        )
    }

    public static func configureCodexAppProfile(
        target: MLXServerCodexConfigurationTarget,
        configuration: MLXServerAgentIntegrationConfiguration,
        homeDirectory: URL = defaultHomeDirectory()
    ) throws {
        if target == .xcode {
            try configureXcodeCodexCLIProfile(
                configuration: configuration,
                homeDirectory: homeDirectory
            )
            return
        }

        try configureCodexProfile(
            profileName: codexAppProfileName,
            target: target,
            configuration: configuration,
            includeForcedLoginMethod: false,
            homeDirectory: homeDirectory
        )
    }

    public static func removeCodexAppProfile(
        target: MLXServerCodexConfigurationTarget,
        homeDirectory: URL = defaultHomeDirectory()
    ) throws {
        if target == .xcode {
            try removeXcodeCodexCLIProfile(homeDirectory: homeDirectory)
            return
        }

        try removeCodexProfile(
            profileName: codexAppProfileName,
            target: target,
            homeDirectory: homeDirectory
        )
    }

    public static func configureXcodeClaudeCode(
        configuration: MLXServerAgentIntegrationConfiguration,
        homeDirectory: URL = defaultHomeDirectory()
    ) throws {
        let normalizedBaseURL = normalizedServerBaseURL(configuration.baseURL)
        let normalizedModelID = try normalizedRequired(
            configuration.modelID,
            fieldName: "modelID"
        )
        let settings = XcodeClaudeCodeSettings(
            env: [
                "ANTHROPIC_BASE_URL": normalizedBaseURL,
                "ANTHROPIC_AUTH_TOKEN": configuration.apiKey?.trimmedNonEmpty ?? "",
                "API_TIMEOUT_MS": "3000000",
                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
                "ANTHROPIC_MODEL": normalizedModelID,
                "DISABLE_AUTOUPDATER": "1"
            ]
        )
        try writeJSON(
            settings,
            to: xcodeClaudeCodeSettingsURL(homeDirectory: homeDirectory)
        )
    }

    public static func removeXcodeClaudeCode(
        homeDirectory: URL = defaultHomeDirectory(),
        fileManager: FileManager = .default
    ) throws {
        let url = xcodeClaudeCodeSettingsURL(homeDirectory: homeDirectory)
        do {
            try fileManager.removeItem(at: url)
        } catch {
            if (error as NSError).code != NSFileNoSuchFileError {
                throw error
            }
        }
    }

    @discardableResult
    public static func configureAionUIACPAgents(
        homeDirectory: URL = defaultHomeDirectory(),
        serverExecutableURL: URL? = Bundle.main.executableURL,
        coderExecutableURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> MLXServerAionUIAgentIntegrationResult {
        guard aionUIApplicationInstalled(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        ) else {
            throw MLXServerAgentIntegrationError.aionUINotInstalled
        }

        let resolvedServerCommand = aionUIExecutableCommand(
            named: "mlx-server",
            preferredURL: serverExecutableURL,
            relativeTo: serverExecutableURL?.deletingLastPathComponent(),
            fileManager: fileManager
        )
        let resolvedCoderCommand = aionUIExecutableCommand(
            named: "mlx-coder",
            preferredURL: coderExecutableURL,
            relativeTo: resolvedServerCommand?.resolvedURL.deletingLastPathComponent()
                ?? serverExecutableURL?.deletingLastPathComponent(),
            fileManager: fileManager
        )
        var customAgents: [AionUICustomAgentDefinition] = []
        var extensionAdapters: [AionUIACPAdapterDefinition] = []
        var skippedCustomAgents: [String] = []
        let coderModelIDs = aionUICoderModelIDs(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        let coderThinking = aionUICoderThinkingMetadata(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        let serverCoderModelIDs = aionUIServerCoderModelIDs(fileManager: fileManager)
        let serverCoderThinking = aionUIServerCoderThinkingMetadata(fileManager: fileManager)

        if let resolvedCoderCommand {
            let args = resolvedCoderCommand.argsPrefix + ["--acp"]
            customAgents.append(
                AionUICustomAgentDefinition(
                    name: "mlx-coder",
                    command: resolvedCoderCommand.command,
                    args: args,
                    models: coderModelIDs,
                    thinkingOptions: coderThinking.options,
                    defaultThinking: coderThinking.defaultSelection
                )
            )
            extensionAdapters.append(
                AionUIACPAdapterDefinition(
                    id: "mlx-coder",
                    name: "mlx-coder",
                    description: "mlx-coder ACP adapter.",
                    command: resolvedCoderCommand.command,
                    args: args,
                    models: coderModelIDs,
                    thinkingOptions: coderThinking.options,
                    defaultThinking: coderThinking.defaultSelection
                )
            )
        } else {
            skippedCustomAgents.append("mlx-coder (mlx-coder executable not found)")
        }

        if let resolvedServerCommand {
            let args = resolvedServerCommand.argsPrefix + ["--coder", "--acp"]
            customAgents.append(
                AionUICustomAgentDefinition(
                    name: "mlx-server-coder",
                    command: resolvedServerCommand.command,
                    args: args,
                    models: serverCoderModelIDs,
                    thinkingOptions: serverCoderThinking.options,
                    defaultThinking: serverCoderThinking.defaultSelection
                )
            )
            extensionAdapters.append(
                AionUIACPAdapterDefinition(
                    id: "mlx-server-coder",
                    name: "mlx-server-coder",
                    description: "mlx-server-coder ACP adapter.",
                    command: resolvedServerCommand.command,
                    args: args,
                    models: serverCoderModelIDs,
                    thinkingOptions: serverCoderThinking.options,
                    defaultThinking: serverCoderThinking.defaultSelection
                )
            )
        } else {
            skippedCustomAgents.append("mlx-server-coder (mlx-server executable not found)")
        }

        guard !customAgents.isEmpty else {
            throw MLXServerAgentIntegrationError.aionUIACPExecutablesNotFound
        }

        guard let baseURL = aionUIBackendBaseURL(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        ) else {
            throw MLXServerAgentIntegrationError.aionUINotRunning
        }

        let customAgentRegistration = try registerAionUICustomAgents(
            customAgents: customAgents,
            baseURL: baseURL,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        let extensionInstallation = try installAionUIACPAdapterExtension(
            adapters: extensionAdapters,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        let channelConfiguration = try configureAionUIEnabledChannelAgents(
            preferredAgentName: "mlx-coder",
            extensionAdapters: extensionAdapters,
            baseURL: baseURL,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )

        return MLXServerAionUIAgentIntegrationResult(
            registeredCustomAgents: customAgentRegistration.registeredAgents,
            updatedCustomAgents: customAgentRegistration.updatedAgents,
            removedDuplicateCustomAgents: customAgentRegistration.removedDuplicateAgents,
            skippedCustomAgents: skippedCustomAgents,
            updatedChannelAgents: channelConfiguration.updatedChannelAgents,
            preparedChannelSessions: channelConfiguration.preparedChannelSessions,
            installedExtension: extensionInstallation.installed,
            requiresAionUIRestart: extensionInstallation.requiresRestart
        )
    }

    public static func aionUIACPAgentsEnabled(
        homeDirectory: URL = defaultHomeDirectory(),
        fileManager: FileManager = .default
    ) -> Bool {
        guard let baseURL = aionUIBackendBaseURL(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        ),
        let agents = try? aionUIAgents(baseURL: baseURL) else {
            return false
        }
        return aionUICustomAgentsAreRegistered(in: agents)
    }

    public static func codexCLIProfileUsesMLXServer(
        homeDirectory: URL = defaultHomeDirectory()
    ) -> Bool {
        codexProfileUsesMLXServer(
            profileName: codexCLIProfileName,
            target: .desktop,
            homeDirectory: homeDirectory
        )
    }

    public static func codexAppProfileUsesMLXServer(
        target: MLXServerCodexConfigurationTarget,
        homeDirectory: URL = defaultHomeDirectory()
    ) -> Bool {
        if target == .xcode {
            return codexTopLevelProfileUsesMLXServer(
                target: target,
                homeDirectory: homeDirectory
            )
        }

        return codexProfileUsesMLXServer(
            profileName: codexAppProfileName,
            target: target,
            homeDirectory: homeDirectory
        )
    }

    public static func codexConfigURL(
        target: MLXServerCodexConfigurationTarget,
        homeDirectory: URL = defaultHomeDirectory()
    ) -> URL {
        switch target {
        case .desktop:
            return homeDirectory
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("config.toml")
                .standardizedFileURL
        case .xcode:
            return homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Developer", isDirectory: true)
                .appendingPathComponent("Xcode", isDirectory: true)
                .appendingPathComponent("CodingAssistant", isDirectory: true)
                .appendingPathComponent("codex", isDirectory: true)
                .appendingPathComponent("config.toml")
                .standardizedFileURL
        }
    }

    public static func xcodeClaudeCodeSettingsURL(
        homeDirectory: URL = defaultHomeDirectory()
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Developer", isDirectory: true)
            .appendingPathComponent("Xcode", isDirectory: true)
            .appendingPathComponent("CodingAssistant", isDirectory: true)
            .appendingPathComponent("ClaudeAgentConfig", isDirectory: true)
            .appendingPathComponent("settings.json")
            .standardizedFileURL
    }

    public static func defaultHomeDirectory() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .standardizedFileURL
    }

    public static func defaultServerBaseURL() -> String {
        let settings = (try? MLXServerSettingsStore.loadRequired()) ?? MLXServerSettings()
        let scheme = settings.tlsCertificatePath == nil ? "http" : "https"
        return "\(scheme)://\(settings.host):\(settings.port)"
    }
}

private extension MLXServerAgentIntegrationService {
    static func configureXcodeCodexCLIProfile(
        configuration: MLXServerAgentIntegrationConfiguration,
        homeDirectory: URL
    ) throws {
        let normalizedModelID = try normalizedRequired(
            configuration.modelID,
            fieldName: "modelID"
        )
        let providerBaseURL = normalizedProviderBaseURL(configuration.baseURL)
        let configURL = codexConfigURL(target: .xcode, homeDirectory: homeDirectory)
        var updatedText = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        updatedText = removingTopLevelTOMLAssignments(
            from: updatedText,
            keys: ["model", "model_provider", "forced_login_method"]
        )
        updatedText = removingTOMLSection(
            from: updatedText,
            matchingHeaders: tomlHeaderVariants(prefix: "model_providers", key: codexProviderID)
        )
        updatedText = updatedText.trimmingCharacters(in: .whitespacesAndNewlines)

        var providerLines = [
            "[model_providers.\(tomlQuotedKey(codexProviderID))]",
            "name = \"mlx-server\"",
            "base_url = \"\(tomlEscapedString(providerBaseURL))\"",
            "wire_api = \"responses\""
        ]
        if let authorizationLine = codexProviderAuthorizationLine(apiKey: configuration.apiKey) {
            providerLines.append(authorizationLine)
        }

        let mlxServerBlock = """
        model = "\(tomlEscapedString(normalizedModelID))"
        model_provider = "\(tomlEscapedString(codexProviderID))"
        forced_login_method = "api"

        \(providerLines.joined(separator: "\n"))
        """

        let finalText = updatedText.isEmpty
            ? "\(mlxServerBlock)\n"
            : "\(mlxServerBlock)\n\n\(updatedText)\n"
        try writeCodexConfig(finalText, to: configURL)
        try removeCodexModelCatalogIfUnused(target: .xcode, homeDirectory: homeDirectory)
    }

    static func removeXcodeCodexCLIProfile(homeDirectory: URL) throws {
        let configURL = codexConfigURL(target: .xcode, homeDirectory: homeDirectory)
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return
        }

        var updatedText = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        if topLevelTOMLStringValue(updatedText, key: "model_provider") == codexProviderID {
            updatedText = removingTopLevelTOMLAssignments(
                from: updatedText,
                keys: ["model", "model_provider", "forced_login_method"]
            )
        }
        if !containsModelProviderReference(in: updatedText, providerID: codexProviderID) {
            updatedText = removingTOMLSection(
                from: updatedText,
                matchingHeaders: tomlHeaderVariants(prefix: "model_providers", key: codexProviderID)
            )
        }
        try writeCodexConfig(
            updatedText.trimmingCharacters(in: .whitespacesAndNewlines) + "\n",
            to: configURL
        )
        try removeCodexModelCatalogIfUnused(target: .xcode, homeDirectory: homeDirectory)
    }

    static func configureCodexProfile(
        profileName: String,
        target: MLXServerCodexConfigurationTarget,
        configuration: MLXServerAgentIntegrationConfiguration,
        includeForcedLoginMethod: Bool,
        homeDirectory: URL
    ) throws {
        let normalizedModelID = try normalizedRequired(
            configuration.modelID,
            fieldName: "modelID"
        )
        let providerBaseURL = normalizedProviderBaseURL(configuration.baseURL)
        let configURL = codexConfigURL(target: target, homeDirectory: homeDirectory)
        let catalogURL = codexModelCatalogURL(target: target, homeDirectory: homeDirectory)
        try writeCodexModelCatalog(
            to: catalogURL,
            modelID: normalizedModelID,
            contextWindow: configuration.contextWindow,
            target: target
        )

        let originalText = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        var updatedText = originalText
        updatedText = removingTOMLSection(
            from: updatedText,
            matchingHeaders: tomlHeaderVariants(prefix: "profiles", key: profileName)
        )
        updatedText = removingTOMLSection(
            from: updatedText,
            matchingHeaders: tomlHeaderVariants(prefix: "model_providers", key: codexProviderID)
        )
        updatedText = updatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !updatedText.isEmpty {
            updatedText.append("\n\n")
        }

        var providerLines = [
            "[model_providers.\(tomlQuotedKey(codexProviderID))]",
            "name = \"mlx-server\"",
            "base_url = \"\(tomlEscapedString(providerBaseURL))\"",
            "wire_api = \"responses\""
        ]
        if let authorizationLine = codexProviderAuthorizationLine(apiKey: configuration.apiKey) {
            providerLines.append(authorizationLine)
        }

        updatedText.append(providerLines.joined(separator: "\n"))
        updatedText.append(
            """

            [profiles.\(tomlQuotedKey(profileName))]
            model = "\(tomlEscapedString(normalizedModelID))"
            openai_base_url = "\(tomlEscapedString(providerBaseURL))"
            model_provider = "\(tomlEscapedString(codexProviderID))"
            model_catalog_json = "\(tomlEscapedString(catalogURL.path))"
            """
        )
        if includeForcedLoginMethod {
            updatedText.append("\nforced_login_method = \"api\"")
        }
        updatedText.append("\n")

        try writeCodexConfig(updatedText, to: configURL)
    }

    static func removeCodexProfile(
        profileName: String,
        target: MLXServerCodexConfigurationTarget,
        homeDirectory: URL
    ) throws {
        let configURL = codexConfigURL(target: target, homeDirectory: homeDirectory)
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            try removeCodexModelCatalogIfUnused(target: target, homeDirectory: homeDirectory)
            return
        }
        let originalText = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        var updatedText = removingTOMLSection(
            from: originalText,
            matchingHeaders: tomlHeaderVariants(prefix: "profiles", key: profileName)
        )

        if !containsModelProviderReference(in: updatedText, providerID: codexProviderID) {
            updatedText = removingTOMLSection(
                from: updatedText,
                matchingHeaders: tomlHeaderVariants(prefix: "model_providers", key: codexProviderID)
            )
        }

        try writeCodexConfig(
            updatedText.trimmingCharacters(in: .whitespacesAndNewlines) + "\n",
            to: configURL
        )
        try removeCodexModelCatalogIfUnused(target: target, homeDirectory: homeDirectory)
    }

    static func codexProfileUsesMLXServer(
        profileName: String,
        target: MLXServerCodexConfigurationTarget,
        homeDirectory: URL
    ) -> Bool {
        let configURL = codexConfigURL(target: target, homeDirectory: homeDirectory)
        let text = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        return containsTOMLSection(
            in: text,
            matchingHeaders: tomlHeaderVariants(prefix: "profiles", key: profileName)
        )
    }

    static func codexTopLevelProfileUsesMLXServer(
        target: MLXServerCodexConfigurationTarget,
        homeDirectory: URL
    ) -> Bool {
        let configURL = codexConfigURL(target: target, homeDirectory: homeDirectory)
        let text = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        return topLevelTOMLStringValue(text, key: "model_provider") == codexProviderID
    }

    static func codexModelCatalogURL(
        target: MLXServerCodexConfigurationTarget,
        homeDirectory: URL
    ) -> URL {
        codexConfigURL(target: target, homeDirectory: homeDirectory)
            .deletingLastPathComponent()
            .appendingPathComponent(codexModelCatalogFilename)
            .standardizedFileURL
    }

    static func writeCodexModelCatalog(
        to catalogURL: URL,
        modelID: String,
        contextWindow: Int?,
        target: MLXServerCodexConfigurationTarget
    ) throws {
        let window = max(contextWindow ?? 128_000, 1)
        let catalog = CodexModelCatalog(
            models: [
                CodexModelCatalogEntry(
                    slug: modelID,
                    displayName: modelID,
                    baseInstructions: codexAppBaseInstructions(target: target),
                    contextWindow: window
                )
            ]
        )
        try writeJSON(catalog, to: catalogURL)
    }

    static func codexAppBaseInstructions(
        target: MLXServerCodexConfigurationTarget
    ) -> String {
        _ = target
        return "You are Codex, a coding agent. You and the user share the same workspace and collaborate to achieve the user's goals."
    }

    static func removeCodexModelCatalogIfUnused(
        target: MLXServerCodexConfigurationTarget,
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        let catalogURL = codexModelCatalogURL(target: target, homeDirectory: homeDirectory)
        let configText = (try? String(
            contentsOf: codexConfigURL(target: target, homeDirectory: homeDirectory),
            encoding: .utf8
        )) ?? ""
        if configText.contains(catalogURL.path) {
            return
        }
        do {
            try fileManager.removeItem(at: catalogURL)
        } catch {
            if (error as NSError).code != NSFileNoSuchFileError {
                throw error
            }
        }
    }

    static func writeCodexConfig(_ text: String, to configURL: URL) throws {
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: configURL, options: [.atomic])
    }

    static func writeJSON(_ value: some Encodable, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        try data.write(to: url, options: [.atomic])
    }

    static func aionUICoderModelIDs(
        homeDirectory: URL,
        fileManager: FileManager
    ) -> [String] {
        let settingsURL = mlxCoderSettingsURL(homeDirectory: homeDirectory)
        guard fileManager.fileExists(atPath: settingsURL.path),
              let data = try? Data(contentsOf: settingsURL),
              let manifest = try? JSONDecoder().decode(
                  AionUICoderSettingsManifest.self,
                  from: data
              ) else {
            return []
        }
        return uniqueAionUIModelIDs(manifest.models.map(\.selectionID))
    }

    static func aionUIServerCoderModelIDs(fileManager: FileManager) -> [String] {
        guard let manifest = try? MLXServerModelsManifestStore.loadRequired(
            fileManager: fileManager
        ),
        let catalog = try? MLXServerModelCatalog(manifest: manifest) else {
            return []
        }
        return uniqueAionUIModelIDs(catalog.models.map { Optional($0.id) })
    }

    static func aionUICoderThinkingMetadata(
        homeDirectory: URL,
        fileManager: FileManager
    ) -> AionUIThinkingMetadata {
        let settingsURL = mlxCoderSettingsURL(homeDirectory: homeDirectory)
        guard fileManager.fileExists(atPath: settingsURL.path),
              let data = try? Data(contentsOf: settingsURL),
              let manifest = try? JSONDecoder().decode(
                  AionUICoderSettingsManifest.self,
                  from: data
              ) else {
            return AionUIThinkingMetadata()
        }
        return AionUIThinkingMetadata(
            options: uniqueAionUIModelIDs(manifest.models.flatMap { model in
                model.thinking?.options ?? []
            }),
            defaultSelection: manifest.models.compactMap { model in
                model.thinking?.defaultSelection?.trimmedNonEmpty
            }.first
        )
    }

    static func aionUIServerCoderThinkingMetadata(
        fileManager: FileManager
    ) -> AionUIThinkingMetadata {
        guard let manifest = try? MLXServerModelsManifestStore.loadRequired(
            fileManager: fileManager
        ),
        let catalog = try? MLXServerModelCatalog(manifest: manifest) else {
            return AionUIThinkingMetadata()
        }
        let thinkingModels = catalog.models.map(\.thinking).map { $0.validated() }
        return AionUIThinkingMetadata(
            options: uniqueAionUIModelIDs(thinkingModels.flatMap { thinking in
                thinking.supportsThinking ? thinking.availableSelections.map(\.rawValue) : []
            }),
            defaultSelection: thinkingModels.first(where: \.supportsThinking)?
                .defaultSelection.rawValue
        )
    }

    static func mlxCoderSettingsURL(homeDirectory: URL) -> URL {
        if let rawSupportDirectory = ProcessInfo
            .processInfo
            .environment["MLX_CODER_SUPPORT_DIRECTORY"]?
            .trimmedNonEmpty {
            return URL(fileURLWithPath: rawSupportDirectory, isDirectory: true)
                .standardizedFileURL
                .appendingPathComponent("settings.json")
        }
        return homeDirectory
            .appendingPathComponent(".mlx-coder", isDirectory: true)
            .appendingPathComponent("settings.json")
            .standardizedFileURL
    }

    static func uniqueAionUIModelIDs(_ values: [String?]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for value in values {
            guard let modelID = value?.trimmedNonEmpty else {
                continue
            }
            let key = modelID.lowercased()
            guard seen.insert(key).inserted else {
                continue
            }
            output.append(modelID)
        }
        return output
    }

    static func installAionUIACPAdapterExtension(
        adapters: [AionUIACPAdapterDefinition],
        homeDirectory: URL,
        fileManager: FileManager
    ) throws -> AionUIExtensionInstallationResult {
        guard !adapters.isEmpty else {
            return AionUIExtensionInstallationResult()
        }

        let extensionDirectoryURL = aionUIExtensionDirectoryURL(
            homeDirectory: homeDirectory
        )
        let manifestURL = extensionDirectoryURL.appendingPathComponent(
            "aion-extension.json",
            isDirectory: false
        )
        let manifest = AionUIExtensionManifest(
            name: "aionext-mlx-server",
            displayName: "MLX Server",
            version: MLXServerCore.version,
            description: "Integrates mlx-coder and mlx-server-coder as ACP adapters in Aion UI.",
            author: "MLX Server",
            engine: AionUIExtensionEngine(aionui: "^2.0.0"),
            contributes: AionUIExtensionContributes(
                acpAdapters: adapters.map { adapter in
                    AionUIExtensionACPAdapter(
                        id: adapter.id,
                        name: adapter.name,
                        description: adapter.description,
                        connectionType: "stdio",
                        cliCommand: adapter.command,
                        acpArgs: adapter.args,
                        defaultCliPath: adapter.command,
                        authRequired: false,
                        supportsStreaming: true,
                        models: adapter.models
                    )
                }
            )
        )
        try writeJSON(manifest, to: manifestURL)
        try updateAionUIExtensionState(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        return AionUIExtensionInstallationResult(
            installed: true,
            requiresRestart: true
        )
    }

    static func updateAionUIExtensionState(
        homeDirectory: URL,
        fileManager: FileManager
    ) throws {
        let stateURL = aionUIDataDirectoryURL(homeDirectory: homeDirectory)
            .appendingPathComponent("extension-states.json", isDirectory: false)
        let states: AionUIExtensionStates
        if fileManager.fileExists(atPath: stateURL.path),
           let data = try? Data(contentsOf: stateURL),
           let decoded = try? JSONDecoder().decode(AionUIExtensionStates.self, from: data) {
            states = decoded
        } else {
            states = AionUIExtensionStates()
        }
        var updatedStates = states
        updatedStates.extensions["aionext-mlx-server"] = AionUIExtensionState(
            installed: true,
            enabled: true,
            lastVersion: MLXServerCore.version
        )
        try writeJSON(updatedStates, to: stateURL)
    }

    static func aionUIDataDirectoryURL(homeDirectory: URL) -> URL {
        let applicationSupportURL = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("AionUi", isDirectory: true)
            .appendingPathComponent("aionui", isDirectory: true)
            .standardizedFileURL
        if FileManager.default.fileExists(atPath: applicationSupportURL.path) {
            return applicationSupportURL
        }
        return homeDirectory
            .appendingPathComponent(".aionui", isDirectory: true)
            .standardizedFileURL
    }

    static func aionUIExtensionDirectoryURL(homeDirectory: URL) -> URL {
        aionUIDataDirectoryURL(homeDirectory: homeDirectory)
            .appendingPathComponent("extensions", isDirectory: true)
            .appendingPathComponent("aionext-mlx-server", isDirectory: true)
    }

    static func aionUIDatabaseURL(homeDirectory: URL) -> URL {
        aionUIDataDirectoryURL(homeDirectory: homeDirectory)
            .appendingPathComponent("aionui-backend.db", isDirectory: false)
            .standardizedFileURL
    }

    static func registerAionUICustomAgents(
        customAgents: [AionUICustomAgentDefinition],
        baseURL: URL,
        homeDirectory: URL,
        fileManager: FileManager
    ) throws -> AionUICustomAgentRegistrationResult {
        let existingAgents = try aionUIAgents(baseURL: baseURL)
        var registeredAgents: [String] = []
        var updatedAgents: [String] = []
        var removedDuplicateAgents: [String] = []
        var retainedAgentIDs = Set<String>()
        let desiredAgentNames = Set(customAgents.map(\.name))

        for customAgent in customAgents {
            let matches = existingAgents.filter { agent in
                aionUIAgent(agent, matches: customAgent)
            }
            let request = aionUICustomAgentRequest(for: customAgent)

            if let existingAgent = matches.first {
                let updatedAgent = try updateAionUICustomAgent(
                    id: existingAgent.id,
                    request: request,
                    baseURL: baseURL
                )
                retainedAgentIDs.insert(updatedAgent.id)
                try persistAionUICustomAgentModelMetadata(
                    agentID: updatedAgent.id,
                    models: customAgent.models,
                    thinkingOptions: customAgent.thinkingOptions,
                    defaultThinking: customAgent.defaultThinking,
                    homeDirectory: homeDirectory,
                    fileManager: fileManager
                )
                updatedAgents.append(customAgent.name)
            } else {
                let createdAgent = try createAionUICustomAgent(
                    request: request,
                    baseURL: baseURL
                )
                retainedAgentIDs.insert(createdAgent.id)
                try persistAionUICustomAgentModelMetadata(
                    agentID: createdAgent.id,
                    models: customAgent.models,
                    thinkingOptions: customAgent.thinkingOptions,
                    defaultThinking: customAgent.defaultThinking,
                    homeDirectory: homeDirectory,
                    fileManager: fileManager
                )
                registeredAgents.append(customAgent.name)
            }

            for duplicateAgent in matches.dropFirst() {
                try deleteAionUICustomAgent(id: duplicateAgent.id, baseURL: baseURL)
                removedDuplicateAgents.append(duplicateAgent.name)
            }
        }

        for staleAgent in existingAgents where staleAgent.agentSource == "custom"
            && !retainedAgentIDs.contains(staleAgent.id)
            && !desiredAgentNames.contains(staleAgent.name)
            && (
                staleAgent.name == "MLX Coder"
                    || staleAgent.name == "MLX Server Coder"
                    || staleAgent.name.hasPrefix("MLX Coder - ")
                    || staleAgent.name.hasPrefix("MLX Server Coder - ")
                    || staleAgent.name.hasPrefix("mlx-coder - ")
                    || staleAgent.name.hasPrefix("mlx-server-coder - ")
            ) {
            try deleteAionUICustomAgent(id: staleAgent.id, baseURL: baseURL)
            removedDuplicateAgents.append(staleAgent.name)
        }

        return AionUICustomAgentRegistrationResult(
            registeredAgents: registeredAgents,
            updatedAgents: updatedAgents,
            removedDuplicateAgents: removedDuplicateAgents
        )
    }

    static func aionUICustomAgentRequest(
        for customAgent: AionUICustomAgentDefinition
    ) -> AionUICustomAgentRequest {
        AionUICustomAgentRequest(
            name: customAgent.name,
            command: customAgent.command,
            icon: "✴️",
            args: customAgent.args,
            enabled: true,
            env: [],
            advanced: AionUICustomAgentAdvanced(),
            backend: aionUICustomAgentBackend(for: customAgent)
        )
    }

    static func persistAionUICustomAgentModelMetadata(
        agentID: String,
        models: [String],
        thinkingOptions: [String],
        defaultThinking: String?,
        homeDirectory: URL,
        fileManager: FileManager
    ) throws {
        let databaseURL = aionUIDatabaseURL(homeDirectory: homeDirectory)
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            return
        }
        let configOptions = AionUIAgentConfigOptions(
            configOptions: aionUIModelConfigOptions(
                models: models,
                thinkingOptions: thinkingOptions,
                defaultThinking: defaultThinking
            )
        )
        let configOptionsJSON = try compactJSONString(configOptions)
        let availableModelsJSON = try compactJSONString(
            aionUIAvailableModels(models: models)
        )
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        _ = try runSQLite(
            databaseURL: databaseURL,
            sql: """
            UPDATE agent_metadata
               SET config_options = \(sqliteQuotedString(configOptionsJSON)),
                   available_models = \(sqliteQuotedString(availableModelsJSON)),
                   updated_at = \(timestamp)
             WHERE id = \(sqliteQuotedString(agentID));
            """,
            fileManager: fileManager
        )
    }

    static func aionUIModelConfigOptions(
        models: [String],
        thinkingOptions: [String] = [],
        defaultThinking: String? = nil
    ) -> [AionUIAgentConfigOption] {
        guard let currentValue = models.first else {
            return []
        }
        var options = [
            AionUIAgentConfigOption(
                id: "model",
                name: "Model",
                category: "model",
                type: "select",
                currentValue: currentValue,
                options: models.map { modelID in
                    AionUIAgentConfigOptionValue(
                        value: modelID,
                        name: aionUIModelDisplayName(modelID),
                        description: modelID
                    )
                }
            )
        ]
        if !thinkingOptions.isEmpty {
            options.append(
                AionUIAgentConfigOption(
                    id: "thinking",
                    name: "Thinking",
                    category: "model",
                    type: "select",
                    currentValue: defaultThinking ?? thinkingOptions.first ?? "",
                    options: thinkingOptions.map { thinking in
                        AionUIAgentConfigOptionValue(
                            value: thinking,
                            name: aionUIThinkingDisplayName(thinking),
                            description: "Thinking: \(aionUIThinkingDisplayName(thinking))"
                        )
                    }
                )
            )
        }
        return options
    }

    static func aionUIAvailableModels(models: [String]) -> AionUIAgentAvailableModels {
        let currentModelID = models.first ?? ""
        return AionUIAgentAvailableModels(
            currentModelID: currentModelID,
            currentModelLabel: currentModelID.trimmedNonEmpty.map(aionUIModelDisplayName),
            availableModels: models.map { modelID in
                AionUIAgentAvailableModel(
                    id: modelID,
                    label: aionUIModelDisplayName(modelID)
                )
            }
        )
    }

    static func aionUIModelDisplayName(_ modelID: String) -> String {
        let trimmed = modelID.trimmedNonEmpty ?? modelID
        if trimmed.hasPrefix("chatgpt:") {
            return String(trimmed.dropFirst("chatgpt:".count))
        }
        if trimmed.hasPrefix("remoteapi:"),
           let suffix = trimmed.split(separator: ":", maxSplits: 2).last {
            return aionUIModelDisplayName(String(suffix))
        }
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    static func aionUIThinkingDisplayName(_ selection: String) -> String {
        switch selection.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "off": "Off"
        case "enabled": "On"
        case "minimal": "Minimal"
        case "low": "Low"
        case "medium": "Medium"
        case "high": "High"
        case "xhigh": "XHigh"
        default: selection
        }
    }

    static func compactJSONString(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func configureAionUIEnabledChannelAgents(
        preferredAgentName: String,
        extensionAdapters: [AionUIACPAdapterDefinition],
        baseURL: URL,
        homeDirectory: URL,
        fileManager: FileManager
    ) throws -> AionUIChannelConfigurationResult {
        let agents = try aionUIAgents(baseURL: baseURL)
        let managedAgents = agents.filter { agent in
            agent.agentSource == "custom" && aionUIAgentIsManagedByMLXServer(agent)
        }
        guard let fallbackAgent = managedAgents.first(where: { $0.name == preferredAgentName })
            ?? managedAgents.first else {
            return AionUIChannelConfigurationResult()
        }
        let channelPreferences = (try? aionUIClientSettings(baseURL: baseURL)
            .channelAgentPreferences) ?? [:]

        let plugins = try aionUIChannelPlugins(baseURL: baseURL)
        let enabledPlatforms = plugins
            .filter(\.enabled)
            .map(\.type)
            .filter { !$0.isEmpty }

        var updatedPlatforms: [String] = []
        var preparedSessions: [String] = []
        for platform in enabledPlatforms {
            let customAgent = aionUIChannelCustomAgent(
                platform: platform,
                managedAgents: managedAgents,
                extensionAdapters: extensionAdapters,
                channelPreferences: channelPreferences,
                fallbackAgent: fallbackAgent
            )
            try updateAionUIChannelAgent(
                platform: platform,
                customAgent: customAgent,
                baseURL: baseURL
            )
            try persistAionUIChannelAgentPreference(
                platform: platform,
                customAgent: customAgent,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            )
            try syncAionUIChannelSettings(platform: platform, baseURL: baseURL)
            updatedPlatforms.append(platform)
            preparedSessions.append(
                contentsOf: try prepareAionUIChannelSessions(
                    platform: platform,
                    customAgent: customAgent,
                    homeDirectory: homeDirectory,
                    fileManager: fileManager
                )
            )
        }
        return AionUIChannelConfigurationResult(
            updatedChannelAgents: updatedPlatforms,
            preparedChannelSessions: preparedSessions
        )
    }

    static func aionUIChannelCustomAgent(
        platform: String,
        managedAgents: [AionUIAgent],
        extensionAdapters: [AionUIACPAdapterDefinition],
        channelPreferences: [String: AionUIChannelAgentSavedPreference],
        fallbackAgent: AionUIAgent
    ) -> AionUIAgent {
        guard let preference = channelPreferences[platform] else {
            return fallbackAgent
        }
        let referencedIDs = preference.referencedAgentIDs
        if let agent = managedAgents.first(where: { referencedIDs.contains($0.id) }),
           !agent.id.isEmpty {
            return agent
        }
        if let adapter = extensionAdapters.first(where: { referencedIDs.contains($0.id) }),
           let agent = managedAgents.first(where: { $0.name == adapter.name }) {
            return agent
        }
        if let name = preference.name,
           let agent = managedAgents.first(where: { $0.name == name }) {
            return agent
        }
        return fallbackAgent
    }

    static func aionUICustomAgentBackend(for customAgent: AionUICustomAgentDefinition) -> String {
        customAgent.name.trimmedNonEmpty ?? customAgent.command
    }

    static func aionUIAgentBackend(for agent: AionUIAgent) -> String {
        if let backend = agent.backend?.trimmedNonEmpty,
           backend.lowercased() != "custom" {
            return backend
        }
        return agent.name.trimmedNonEmpty ?? agent.id
    }

    static func aionUIChannelAgentPreference(
        for customAgent: AionUIAgent
    ) -> AionUIChannelAgentPreference {
        AionUIChannelAgentPreference(
            agentType: "acp",
            backend: aionUIAgentBackend(for: customAgent),
            agentID: customAgent.id,
            customAgentID: customAgent.id,
            id: customAgent.id,
            name: customAgent.name
        )
    }

    static func aionUIClientSettings(baseURL: URL) throws -> AionUIClientSettings {
        let response: AionUIAPIEnvelope<AionUIClientSettings> = try sendAionUIAPIRequest(
            method: "GET",
            pathComponents: ["api", "settings", "client"],
            body: Optional<AionUIEmptyRequest>.none,
            baseURL: baseURL
        )
        guard response.success, let data = response.data else {
            throw MLXServerAgentIntegrationError.aionUIAPIRequestFailed(
                response.error ?? "Aion UI did not return client settings."
            )
        }
        return data
    }

    static func aionUIChannelPlugins(baseURL: URL) throws -> [AionUIChannelPlugin] {
        let response: AionUIAPIEnvelope<[AionUIChannelPlugin]> = try sendAionUIAPIRequest(
            method: "GET",
            pathComponents: ["api", "channel", "plugins"],
            body: Optional<AionUIEmptyRequest>.none,
            baseURL: baseURL
        )
        guard response.success, let data = response.data else {
            throw MLXServerAgentIntegrationError.aionUIAPIRequestFailed(
                response.error ?? "Aion UI did not return channel plugins."
            )
        }
        return data
    }

    static func updateAionUIChannelAgent(
        platform: String,
        customAgent: AionUIAgent,
        baseURL: URL
    ) throws {
        let response: AionUIAPIEnvelope<AionUIEmptyResponse> = try sendAionUIAPIRequest(
            method: "PUT",
            pathComponents: ["api", "settings", "client"],
            body: AionUIChannelAgentPreferenceUpdate(
                platform: platform,
                preference: aionUIChannelAgentPreference(for: customAgent)
            ),
            baseURL: baseURL
        )
        guard response.success else {
            throw MLXServerAgentIntegrationError.aionUIAPIRequestFailed(
                response.error ?? "Aion UI did not update the channel agent preference."
            )
        }
    }

    static func persistAionUIChannelAgentPreference(
        platform: String,
        customAgent: AionUIAgent,
        homeDirectory: URL,
        fileManager: FileManager
    ) throws {
        let databaseURL = aionUIDatabaseURL(homeDirectory: homeDirectory)
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            return
        }

        let preference = aionUIChannelAgentPreference(for: customAgent)
        let preferenceData = try JSONEncoder().encode(preference)
        guard let preferenceJSON = String(data: preferenceData, encoding: .utf8) else {
            throw MLXServerAgentIntegrationError.aionUIAPIRequestFailed(
                "Could not encode Aion UI channel agent preference."
            )
        }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let sql = """
        INSERT INTO client_preferences (
          key,
          value,
          updated_at
        )
        VALUES (
          \(sqliteQuotedString("assistant.\(platform).agent")),
          \(sqliteQuotedString(preferenceJSON)),
          \(now)
        )
        ON CONFLICT(key) DO UPDATE SET
          value = excluded.value,
          updated_at = excluded.updated_at;
        """
        _ = try runSQLite(
            databaseURL: databaseURL,
            sql: sql,
            fileManager: fileManager
        )
    }

    static func syncAionUIChannelSettings(platform: String, baseURL: URL) throws {
        let response: AionUIAPIEnvelope<AionUIChannelSettingsSyncResponse> =
            try sendAionUIAPIRequest(
                method: "POST",
                pathComponents: ["api", "channel", "settings", "sync"],
                body: AionUIChannelSettingsSyncRequest(platform: platform),
                baseURL: baseURL
            )
        guard response.success else {
            throw MLXServerAgentIntegrationError.aionUIAPIRequestFailed(
                response.error ?? "Aion UI did not sync channel settings."
            )
        }
    }

    static func prepareAionUIChannelSessions(
        platform: String,
        customAgent: AionUIAgent,
        homeDirectory: URL,
        fileManager: FileManager
    ) throws -> [String] {
        guard platform == "telegram" else {
            return []
        }
        let databaseURL = aionUIDatabaseURL(homeDirectory: homeDirectory)
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            return []
        }

        let users = try aionUIAssistantUsers(
            platform: platform,
            databaseURL: databaseURL,
            fileManager: fileManager
        )
        guard !users.isEmpty else {
            return []
        }

        var preparedSessions: [String] = []
        for user in users {
            let existingConversationIDs = try aionUIChannelConversationIDs(
                platform: platform,
                platformUserID: user.platformUserID,
                databaseURL: databaseURL,
                fileManager: fileManager
            )
            let conversationID = existingConversationIDs.first ?? stableAionUIID(
                seed: "mlx-server:\(platform):\(user.platformUserID):acp",
                length: 8
            )
            let sessionID = stableAionUIUUID(
                seed: "mlx-server-session:\(platform):\(user.id):\(customAgent.id)"
            )
            let workspaceURL = homeDirectory.standardizedFileURL
            try fileManager.createDirectory(
                at: workspaceURL,
                withIntermediateDirectories: true,
                attributes: nil
            )

            let agentBackend = aionUIAgentBackend(for: customAgent)
            let extra = AionUIChannelConversationExtra(
                backend: agentBackend,
                workspace: workspaceURL.path,
                agentID: customAgent.id,
                customAgentID: customAgent.id,
                agentName: customAgent.name
            )
            let extraData = try JSONEncoder().encode(extra)
            guard let extraJSON = String(data: extraData, encoding: .utf8) else {
                throw MLXServerAgentIntegrationError.aionUIAPIRequestFailed(
                    "Could not encode Aion UI channel conversation metadata."
                )
            }

            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let conversationName = aionUIChannelConversationName(
                platform: platform,
                platformUserID: user.platformUserID
            )
            let configuredConversationIDs = uniqueAionUIIDs(
                [conversationID] + existingConversationIDs
            )
            let acpSessionSQL = configuredConversationIDs.map { configuredConversationID in
                """
                INSERT INTO acp_session (
                  conversation_id,
                  agent_backend,
                  agent_source,
                  agent_id,
                  session_id,
                  session_status,
                  session_config,
                  last_active_at
                )
                VALUES (
                  \(sqliteQuotedString(configuredConversationID)),
                  \(sqliteQuotedString(agentBackend)),
                  'builtin',
                  \(sqliteQuotedString(customAgent.id)),
                  NULL,
                  'idle',
                  '{}',
                  \(now)
                )
                ON CONFLICT(conversation_id) DO UPDATE SET
                  agent_backend = excluded.agent_backend,
                  agent_source = excluded.agent_source,
                  agent_id = excluded.agent_id,
                  session_status = excluded.session_status,
                  session_config = CASE
                    WHEN acp_session.session_config = '' THEN '{}'
                    ELSE acp_session.session_config
                  END,
                  last_active_at = excluded.last_active_at;
                """
            }.joined(separator: "\n\n")
            let sql = """
            INSERT INTO conversations (
              id,
              user_id,
              name,
              type,
              extra,
              model,
              status,
              source,
              channel_chat_id,
              pinned,
              created_at,
              updated_at
            )
            VALUES (
              \(sqliteQuotedString(conversationID)),
              'system_default_user',
              \(sqliteQuotedString(conversationName)),
              'acp',
              \(sqliteQuotedString(extraJSON)),
              NULL,
              'pending',
              \(sqliteQuotedString(platform)),
              \(sqliteQuotedString(user.platformUserID)),
              0,
              \(now),
              \(now)
            )
            ON CONFLICT(id) DO UPDATE SET
              name = excluded.name,
              type = excluded.type,
              extra = excluded.extra,
              source = excluded.source,
              channel_chat_id = excluded.channel_chat_id,
              updated_at = excluded.updated_at;

            UPDATE conversations
            SET
              name = \(sqliteQuotedString(conversationName)),
              extra = json_set(
                CASE WHEN json_valid(extra) THEN extra ELSE '{}' END,
                '$.backend',
                \(sqliteQuotedString(agentBackend)),
                '$.agent_id',
                \(sqliteQuotedString(customAgent.id)),
                '$.custom_agent_id',
                \(sqliteQuotedString(customAgent.id)),
                '$.agent_name',
                \(sqliteQuotedString(customAgent.name)),
                '$.workspace',
                \(sqliteQuotedString(workspaceURL.path))
              ),
              updated_at = \(now)
            WHERE source = \(sqliteQuotedString(platform))
              AND channel_chat_id = \(sqliteQuotedString(user.platformUserID))
              AND type = 'acp';

            INSERT INTO assistant_sessions (
              id,
              user_id,
              agent_type,
              conversation_id,
              workspace,
              chat_id,
              created_at,
              last_activity
            )
            VALUES (
              \(sqliteQuotedString(sessionID)),
              \(sqliteQuotedString(user.id)),
              'acp',
              \(sqliteQuotedString(conversationID)),
              \(sqliteQuotedString(workspaceURL.path)),
              \(sqliteQuotedString(user.platformUserID)),
              \(now),
              \(now)
            )
            ON CONFLICT(id) DO UPDATE SET
              agent_type = excluded.agent_type,
              conversation_id = excluded.conversation_id,
              workspace = excluded.workspace,
              chat_id = excluded.chat_id,
              last_activity = excluded.last_activity;

            UPDATE assistant_sessions
            SET
              agent_type = 'acp',
              conversation_id = \(sqliteQuotedString(conversationID)),
              workspace = \(sqliteQuotedString(workspaceURL.path)),
              last_activity = \(now)
            WHERE user_id = \(sqliteQuotedString(user.id))
              AND chat_id = \(sqliteQuotedString(user.platformUserID));

            \(acpSessionSQL)

            UPDATE assistant_users
            SET session_id = \(sqliteQuotedString(sessionID))
            WHERE id = \(sqliteQuotedString(user.id));
            """
            _ = try runSQLite(
                databaseURL: databaseURL,
                sql: sql,
                fileManager: fileManager
            )
            preparedSessions.append("\(platform): \(user.displayName ?? user.platformUserID)")
        }
        return preparedSessions
    }

    static func aionUIChannelConversationIDs(
        platform: String,
        platformUserID: String,
        databaseURL: URL,
        fileManager: FileManager
    ) throws -> [String] {
        let sql = """
        SELECT id
        FROM conversations
        WHERE source = \(sqliteQuotedString(platform))
          AND channel_chat_id = \(sqliteQuotedString(platformUserID))
          AND type = 'acp'
        ORDER BY updated_at DESC;
        """
        let output = try runSQLite(
            databaseURL: databaseURL,
            sql: sql,
            arguments: ["-json"],
            fileManager: fileManager
        )
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }
        return try JSONDecoder()
            .decode([AionUIChannelConversationRow].self, from: Data(trimmed.utf8))
            .map(\.id)
    }

    static func uniqueAionUIIDs(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var output: [String] = []
        for value in values where !value.isEmpty && seen.insert(value).inserted {
            output.append(value)
        }
        return output
    }

    static func aionUIAssistantUsers(
        platform: String,
        databaseURL: URL,
        fileManager: FileManager
    ) throws -> [AionUIAssistantUser] {
        let sql = """
        SELECT
          id,
          platform_user_id,
          platform_type,
          display_name
        FROM assistant_users
        WHERE platform_type = \(sqliteQuotedString(platform))
        ORDER BY authorized_at DESC;
        """
        let output = try runSQLite(
            databaseURL: databaseURL,
            sql: sql,
            arguments: ["-json"],
            fileManager: fileManager
        )
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }
        return try JSONDecoder().decode([AionUIAssistantUser].self, from: Data(trimmed.utf8))
    }

    static func aionUICustomAgentsAreRegistered(in agents: [AionUIAgent]) -> Bool {
        let customAgents = agents.filter { $0.agentSource == "custom" }
        let hasCoder = customAgents.contains { agent in
            aionUIAgent(agent, matches: AionUICustomAgentDefinition(
                name: "mlx-coder",
                command: "mlx-coder",
                args: ["--acp"]
            ))
        }
        let hasServerCoder = customAgents.contains { agent in
            aionUIAgent(agent, matches: AionUICustomAgentDefinition(
                name: "mlx-server-coder",
                command: "mlx-server",
                args: ["--coder", "--acp"]
            ))
        }
        return hasCoder && hasServerCoder
    }

    static func aionUIAgentIsManagedByMLXServer(_ agent: AionUIAgent) -> Bool {
        let isManagedName = agent.name == "mlx-coder"
            || agent.name == "mlx-server-coder"
            || agent.name == "MLX Coder"
            || agent.name == "MLX Server Coder"
        let args = agent.args ?? []
        let isManagedCoderCommand = (
            agent.command?.hasSuffix("/mlx-coder") == true
                || agent.command == "mlx-coder"
        ) && args == ["--acp"]
        let isManagedServerCommand = (
            agent.command?.hasSuffix("/mlx-server") == true
                || agent.command == "mlx-server"
        ) && args == ["--coder", "--acp"]
        return isManagedName
            || isManagedCoderCommand
            || isManagedServerCommand
    }

    static func aionUIAgent(
        _ agent: AionUIAgent,
        matches customAgent: AionUICustomAgentDefinition
    ) -> Bool {
        agent.agentSource == "custom"
            && (
                agent.name == customAgent.name
                    || (
                        command(agent.command, matches: customAgent.command)
                            && (agent.args ?? []) == customAgent.args
                    )
            )
    }

    static func command(_ command: String?, matches expectedCommand: String) -> Bool {
        guard let command else {
            return false
        }
        return command == expectedCommand || command.hasSuffix("/\(expectedCommand)")
    }

    static func aionUIBackendBaseURL(
        homeDirectory: URL,
        fileManager: FileManager
    ) -> URL? {
        for port in aionUIBackendPortCandidates(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        ) {
            guard let baseURL = URL(string: "http://127.0.0.1:\(port)") else {
                continue
            }
            if aionUIHealthCheck(baseURL: baseURL) {
                return baseURL
            }
        }
        return nil
    }

    static func runSQLite(
        databaseURL: URL,
        sql: String,
        arguments: [String] = [],
        fileManager: FileManager
    ) throws -> String {
        let executableURL = executableURLFromPath(
            named: "sqlite3",
            fileManager: fileManager
        ) ?? URL(fileURLWithPath: "/usr/bin/sqlite3", isDirectory: false)
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw MLXServerAgentIntegrationError.aionUIAPIRequestFailed(
                "Could not find sqlite3 to configure Aion UI channel sessions."
            )
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments + [databaseURL.path, sql]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()

        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: stdout, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let errorOutput = String(data: stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw MLXServerAgentIntegrationError.aionUIAPIRequestFailed(
                errorOutput ?? "sqlite3 failed while configuring Aion UI."
            )
        }
        return output
    }

    static func sqliteQuotedString(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    static func aionUIChannelConversationName(
        platform: String,
        platformUserID: String
    ) -> String {
        let prefix = platform == "telegram" ? "tg" : platform
        let userPrefix = String(platformUserID.prefix(8))
        return "\(prefix)-acp-\(userPrefix)"
    }

    static func stableAionUIID(seed: String, length: Int) -> String {
        var output = ""
        var salt: UInt64 = 0
        while output.count < length {
            var hash: UInt64 = 14_695_981_039_346_656_037 ^ salt
            for byte in seed.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            output += String(format: "%016llx", hash)
            salt &+= 1
        }
        return String(output.prefix(length))
    }

    static func stableAionUIUUID(seed: String) -> String {
        let hex = stableAionUIID(seed: seed, length: 32)
        return [
            hex.prefix(8),
            hex.dropFirst(8).prefix(4),
            hex.dropFirst(12).prefix(4),
            hex.dropFirst(16).prefix(4),
            hex.dropFirst(20).prefix(12)
        ].map(String.init).joined(separator: "-")
    }

    static func aionUIBackendPortCandidates(
        homeDirectory: URL,
        fileManager: FileManager
    ) -> [Int] {
        let logDirectoryURL = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("AionUi", isDirectory: true)
            .standardizedFileURL
        let logURLs = ((try? fileManager.contentsOfDirectory(
            at: logDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? [])
            .filter { $0.pathExtension == "log" }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return lhsDate > rhsDate
            }

        var ports: [Int] = []
        var seen: Set<Int> = []
        for logURL in logURLs.prefix(4) {
            guard let text = try? String(contentsOf: logURL, encoding: .utf8) else {
                continue
            }
            for port in aionUIBackendPorts(in: text).reversed() {
                guard !seen.contains(port) else {
                    continue
                }
                seen.insert(port)
                ports.append(port)
            }
        }
        return ports
    }

    static func aionUIBackendPorts(in text: String) -> [Int] {
        let markers = [
            "backendManager.start ready (port=",
            "selected backend port ",
            "Server listening on 127.0.0.1:"
        ]
        var ports: [Int] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            for marker in markers {
                guard let markerRange = line.range(of: marker) else {
                    continue
                }
                let suffix = line[markerRange.upperBound...]
                let digits = suffix.prefix { character in
                    character >= "0" && character <= "9"
                }
                guard let port = Int(digits), port > 0 else {
                    continue
                }
                ports.append(port)
            }
        }
        return ports
    }

    static func aionUIHealthCheck(baseURL: URL) -> Bool {
        var url = baseURL
        url.appendPathComponent("health")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = aionUIHealthCheckTimeout
        switch performAionUIRequest(request) {
        case .success(let value):
            return (200..<300).contains(value.response.statusCode)
        case .failure:
            return false
        }
    }

    static func aionUIAgents(baseURL: URL) throws -> [AionUIAgent] {
        let response: AionUIAPIEnvelope<[AionUIAgent]> = try sendAionUIAPIRequest(
            method: "GET",
            pathComponents: ["api", "agents"],
            body: Optional<AionUIEmptyRequest>.none,
            baseURL: baseURL
        )
        guard response.success, let data = response.data else {
            throw MLXServerAgentIntegrationError.aionUIAPIRequestFailed(
                response.error ?? "Aion UI did not return an agent list."
            )
        }
        return data
    }

    static func createAionUICustomAgent(
        request: AionUICustomAgentRequest,
        baseURL: URL
    ) throws -> AionUIAgent {
        let response: AionUIAPIEnvelope<AionUIAgent> = try sendAionUIAPIRequest(
            method: "POST",
            pathComponents: ["api", "agents", "custom"],
            body: request,
            baseURL: baseURL
        )
        guard response.success, let data = response.data else {
            throw MLXServerAgentIntegrationError.aionUIAPIRequestFailed(
                response.error ?? "Aion UI did not create the custom agent."
            )
        }
        return data
    }

    static func updateAionUICustomAgent(
        id: String,
        request: AionUICustomAgentRequest,
        baseURL: URL
    ) throws -> AionUIAgent {
        let response: AionUIAPIEnvelope<AionUIAgent> = try sendAionUIAPIRequest(
            method: "PUT",
            pathComponents: ["api", "agents", "custom", id],
            body: request,
            baseURL: baseURL
        )
        guard response.success, let data = response.data else {
            throw MLXServerAgentIntegrationError.aionUIAPIRequestFailed(
                response.error ?? "Aion UI did not update the custom agent."
            )
        }
        return data
    }

    static func deleteAionUICustomAgent(id: String, baseURL: URL) throws {
        let response: AionUIAPIEnvelope<AionUIEmptyResponse> = try sendAionUIAPIRequest(
            method: "DELETE",
            pathComponents: ["api", "agents", "custom", id],
            body: Optional<AionUIEmptyRequest>.none,
            baseURL: baseURL
        )
        guard response.success else {
            throw MLXServerAgentIntegrationError.aionUIAPIRequestFailed(
                response.error ?? "Aion UI did not delete the duplicate custom agent."
            )
        }
    }

    static func sendAionUIAPIRequest<RequestBody: Encodable, ResponseBody: Decodable>(
        method: String,
        pathComponents: [String],
        body: RequestBody?,
        baseURL: URL
    ) throws -> AionUIAPIEnvelope<ResponseBody> {
        var url = baseURL
        for component in pathComponents {
            url.appendPathComponent(component)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = aionUIAPIRequestTimeout
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let result = performAionUIRequest(request)
        let data: Data
        let response: HTTPURLResponse
        switch result {
        case .success(let value):
            data = value.data
            response = value.response
        case .failure(let error):
            throw error
        }

        guard (200..<300).contains(response.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(response.statusCode)"
            throw MLXServerAgentIntegrationError.aionUIAPIRequestFailed(message)
        }
        return try JSONDecoder().decode(AionUIAPIEnvelope<ResponseBody>.self, from: data)
    }

    static func performAionUIRequest(
        _ request: URLRequest
    ) -> Result<(data: Data, response: HTTPURLResponse), Error> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = AionUIHTTPResponseBox()
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                box.result = .failure(error)
            } else if let data, let response = response as? HTTPURLResponse {
                box.result = .success((data, response))
            } else {
                box.result = .failure(
                    MLXServerAgentIntegrationError.aionUIAPIRequestFailed(
                        "Aion UI returned an invalid HTTP response."
                    )
                )
            }
            semaphore.signal()
        }
        task.resume()
        let timeout = max(request.timeoutInterval, aionUIHealthCheckTimeout)
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            return .failure(
                MLXServerAgentIntegrationError.aionUIAPIRequestFailed(
                    "Timed out while contacting Aion UI."
                )
            )
        }
        return box.result ?? .failure(
            MLXServerAgentIntegrationError.aionUIAPIRequestFailed(
                "Aion UI request did not complete."
            )
        )
    }

    static func aionUIApplicationInstalled(
        homeDirectory: URL,
        fileManager: FileManager
    ) -> Bool {
        aionUIApplicationURLs(homeDirectory: homeDirectory).contains { url in
            fileManager.fileExists(atPath: url.path)
        }
    }

    static func aionUIApplicationURLs(homeDirectory: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications/AionUi.app", isDirectory: true),
            homeDirectory
                .appendingPathComponent("Applications", isDirectory: true)
                .appendingPathComponent("AionUi.app", isDirectory: true)
        ].map(\.standardizedFileURL)
    }

    static func removeItemIfPresent(at url: URL, fileManager: FileManager) throws {
        do {
            try fileManager.removeItem(at: url)
        } catch {
            if (error as NSError).code != NSFileNoSuchFileError {
                throw error
            }
        }
    }

    static func normalizedProviderBaseURL(_ baseURL: String) -> String {
        let withoutTrailingSlash = baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .dropTrailingSlash
        return withoutTrailingSlash.hasSuffix("/v1")
            ? withoutTrailingSlash
            : "\(withoutTrailingSlash)/v1"
    }

    static func normalizedServerBaseURL(_ baseURL: String) -> String {
        let withoutTrailingSlash = baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .dropTrailingSlash
        if withoutTrailingSlash.hasSuffix("/v1") {
            return String(withoutTrailingSlash.dropLast(3))
        }
        return withoutTrailingSlash
    }

    static func normalizedRequired(_ value: String, fieldName: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MLXServerAgentIntegrationError.emptyRequiredValue(fieldName)
        }
        return trimmed
    }

    static func removingTOMLSection(
        from text: String,
        matchingHeaders headers: Set<String>
    ) -> String {
        var retainedLines: [String] = []
        var isSkipping = false
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.hasPrefix("["),
               trimmedLine.hasSuffix("]") {
                isSkipping = headers.contains(trimmedLine)
                if isSkipping {
                    continue
                }
            }

            if !isSkipping {
                retainedLines.append(String(line))
            }
        }
        return retainedLines.joined(separator: "\n")
    }

    static func removingTopLevelTOMLAssignments(
        from text: String,
        keys: Set<String>
    ) -> String {
        var retainedLines: [String] = []
        var reachedTable = false
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.hasPrefix("["),
               trimmedLine.hasSuffix("]") {
                reachedTable = true
            }

            if !reachedTable,
               let key = topLevelTOMLAssignmentKey(String(line)),
               keys.contains(key) {
                continue
            }
            retainedLines.append(String(line))
        }
        return retainedLines.joined(separator: "\n")
    }

    static func containsTOMLSection(
        in text: String,
        matchingHeaders headers: Set<String>
    ) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains { line in
                line.hasPrefix("[")
                    && line.hasSuffix("]")
                    && headers.contains(line)
            }
    }

    static func containsModelProviderReference(
        in text: String,
        providerID: String
    ) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .contains { line in
                guard topLevelTOMLAssignmentKey(line) == "model_provider",
                      let equalsIndex = line.firstIndex(of: "=") else {
                    return false
                }
                let rawValue = String(line[line.index(after: equalsIndex)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return tomlStringValue(rawValue) == providerID
            }
    }

    static func topLevelTOMLStringValue(_ text: String, key: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let rawLine = String(line)
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.hasPrefix("["),
               trimmedLine.hasSuffix("]") {
                return nil
            }
            guard topLevelTOMLAssignmentKey(rawLine) == key,
                  let equalsIndex = rawLine.firstIndex(of: "=") else {
                continue
            }
            let rawValue = String(rawLine[rawLine.index(after: equalsIndex)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return tomlStringValue(rawValue)
        }
        return nil
    }

    static func tomlHeaderVariants(prefix: String, key: String) -> Set<String> {
        [
            "[\(prefix).\(key)]",
            "[\(prefix).\(tomlQuotedKey(key))]"
        ]
    }

    static func topLevelTOMLAssignmentKey(_ line: String) -> String? {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty,
              !trimmedLine.hasPrefix("#"),
              let equalsIndex = trimmedLine.firstIndex(of: "=") else {
            return nil
        }
        return String(trimmedLine[..<equalsIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func tomlStringValue(_ rawValue: String) -> String? {
        guard rawValue.hasPrefix("\"") else {
            return rawValue.split(separator: "#", maxSplits: 1)
                .first
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        }

        var result = ""
        var isEscaped = false
        for character in rawValue.dropFirst() {
            if isEscaped {
                switch character {
                case "n":
                    result.append("\n")
                case "\"", "\\":
                    result.append(character)
                default:
                    result.append(character)
                }
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                return result
            } else {
                result.append(character)
            }
        }
        return nil
    }

    static func tomlQuotedKey(_ value: String) -> String {
        "\"\(tomlEscapedString(value))\""
    }

    static func codexProviderAuthorizationLine(apiKey: String?) -> String? {
        guard let apiKey = apiKey?.trimmedNonEmpty else {
            return nil
        }
        return "http_headers = { Authorization = \"Bearer \(tomlEscapedString(apiKey))\" }"
    }

    static func tomlEscapedString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

public enum MLXServerAgentIntegrationError: LocalizedError, Sendable, Equatable {
    case emptyRequiredValue(String)
    case aionUINotInstalled
    case aionUINotRunning
    case aionUIACPExecutablesNotFound
    case aionUIAPIRequestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyRequiredValue(let fieldName):
            return "\(fieldName) can not be empty."
        case .aionUINotInstalled:
            return "Aion UI is not installed."
        case .aionUINotRunning:
            return "Aion UI is installed, but it is not running."
        case .aionUIACPExecutablesNotFound:
            return "Could not find mlx-coder or mlx-server executables for the Aion UI integration."
        case .aionUIAPIRequestFailed(let message):
            return message
        }
    }
}

extension MLXServerAgentIntegrationService {
    static func executableURL(
        named name: String,
        preferredURL: URL?,
        relativeTo directoryURL: URL?,
        fileManager: FileManager
    ) -> URL? {
        let preferredExecutableURL = preferredURL?.lastPathComponent == name
            ? preferredURL
            : nil
        let candidates = [
            preferredExecutableURL,
            directoryURL?.appendingPathComponent(name)
        ]
        for candidate in candidates.compactMap({ $0?.standardizedFileURL }) {
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return executableURLFromPath(named: name, fileManager: fileManager)
    }

    static func aionUIExecutableCommand(
        named name: String,
        preferredURL: URL?,
        relativeTo directoryURL: URL?,
        fileManager: FileManager
    ) -> AionUIExecutableCommand? {
        guard let resolvedURL = executableURL(
            named: name,
            preferredURL: preferredURL,
            relativeTo: directoryURL,
            fileManager: fileManager
        ) else {
            return nil
        }

        return AionUIExecutableCommand(
            command: stableExecutablePath(
                named: name,
                resolvedURL: resolvedURL,
                fileManager: fileManager
            ),
            argsPrefix: [],
            resolvedURL: resolvedURL
        )
    }

    static func stableExecutablePath(
        named name: String,
        resolvedURL: URL,
        fileManager: FileManager
    ) -> String {
        for directoryPath in ["/opt/homebrew/bin", "/usr/local/bin"] {
            let candidateURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
                .appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidateURL.path),
               sameExecutable(candidateURL, resolvedURL) {
                return candidateURL.path
            }
        }
        return resolvedURL.path
    }

    static func sameExecutable(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.path
            == rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func executableURLFromPath(
        named name: String,
        fileManager: FileManager
    ) -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":").map(String.init) {
            guard !directory.isEmpty else {
                continue
            }
            let url = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(name)
                .standardizedFileURL
            if fileManager.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}

struct AionUIExecutableCommand: Sendable, Equatable {
    var command: String
    var argsPrefix: [String]
    var resolvedURL: URL
}

private struct AionUICustomAgentRegistrationResult: Sendable, Equatable {
    var registeredAgents: [String] = []
    var updatedAgents: [String] = []
    var removedDuplicateAgents: [String] = []
}

private struct AionUIChannelConfigurationResult: Sendable, Equatable {
    var updatedChannelAgents: [String] = []
    var preparedChannelSessions: [String] = []
}

private struct AionUIThinkingMetadata: Sendable, Equatable {
    var options: [String] = []
    var defaultSelection: String? = nil
}

private struct AionUICustomAgentDefinition: Sendable, Equatable {
    var name: String
    var command: String
    var args: [String]
    var models: [String] = []
    var thinkingOptions: [String] = []
    var defaultThinking: String?
}

private struct AionUIACPAdapterDefinition: Sendable, Equatable {
    var id: String
    var name: String
    var description: String
    var command: String
    var args: [String]
    var models: [String] = []
    var thinkingOptions: [String] = []
    var defaultThinking: String?
}

private struct AionUIAgentConfigOptions: Encodable {
    var configOptions: [AionUIAgentConfigOption]

    enum CodingKeys: String, CodingKey {
        case configOptions = "config_options"
    }
}

private struct AionUIAgentConfigOption: Encodable {
    var id: String
    var name: String
    var category: String
    var type: String
    var currentValue: String
    var options: [AionUIAgentConfigOptionValue]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case category
        case type
        case currentValue = "current_value"
        case options
    }
}

private struct AionUIAgentConfigOptionValue: Encodable {
    var value: String
    var name: String
    var description: String
}

private struct AionUIAgentAvailableModels: Encodable {
    var currentModelID: String
    var currentModelLabel: String?
    var availableModels: [AionUIAgentAvailableModel]

    enum CodingKeys: String, CodingKey {
        case currentModelID = "current_model_id"
        case currentModelLabel = "current_model_label"
        case availableModels = "available_models"
    }
}

private struct AionUIAgentAvailableModel: Encodable {
    var id: String
    var label: String
}

private struct AionUICoderSettingsManifest: Decodable {
    var models: [AionUICoderSettingsModel]

    enum CodingKeys: String, CodingKey {
        case models
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        models = try container.decodeIfPresent(
            [AionUICoderSettingsModel].self,
            forKey: .models
        ) ?? []
    }
}

private struct AionUICoderSettingsModel: Decodable {
    var id: String?
    var llmID: String?
    var modelID: String?
    var thinking: AionUICoderSettingsThinking?

    enum CodingKeys: String, CodingKey {
        case id
        case llmID
        case modelID
        case thinking
    }

    var selectionID: String? {
        id?.trimmedNonEmpty
            ?? llmID?.trimmedNonEmpty
            ?? modelID?.trimmedNonEmpty
    }
}

private struct AionUICoderSettingsThinking: Decodable {
    var options: [String]
    var defaultSelection: String?

    enum CodingKeys: String, CodingKey {
        case options
        case defaultSelection = "default"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        options = try container.decodeIfPresent([String].self, forKey: .options) ?? []
        defaultSelection = try container.decodeIfPresent(String.self, forKey: .defaultSelection)
    }
}

private struct AionUIExtensionInstallationResult: Sendable, Equatable {
    var installed: Bool = false
    var requiresRestart: Bool = false
}

private struct AionUIAPIEnvelope<Value: Decodable>: Decodable {
    var success: Bool
    var data: Value?
    var error: String?
}

private struct AionUIAgent: Decodable {
    var id: String
    var name: String
    var backend: String?
    var agentSource: String?
    var command: String?
    var args: [String]?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case backend
        case agentSource = "agent_source"
        case command
        case args
    }
}

private struct AionUIClientSettings: Decodable {
    var channelAgentPreferences: [String: AionUIChannelAgentSavedPreference]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var preferences: [String: AionUIChannelAgentSavedPreference] = [:]
        for key in container.allKeys {
            let prefix = "assistant."
            let suffix = ".agent"
            guard key.stringValue.hasPrefix(prefix),
                  key.stringValue.hasSuffix(suffix) else {
                continue
            }
            let platformStart = key.stringValue.index(
                key.stringValue.startIndex,
                offsetBy: prefix.count
            )
            let platformEnd = key.stringValue.index(
                key.stringValue.endIndex,
                offsetBy: -suffix.count
            )
            let platform = String(key.stringValue[platformStart..<platformEnd])
            guard let preference = try? container.decode(
                AionUIChannelAgentSavedPreference.self,
                forKey: key
            ) else {
                continue
            }
            preferences[platform] = preference
        }
        channelAgentPreferences = preferences
    }
}

private struct AionUIChannelAgentSavedPreference: Decodable {
    var backend: String?
    var agentID: String?
    var customAgentID: String?
    var id: String?
    var name: String?

    var referencedAgentIDs: [String] {
        [agentID, id, customAgentID, backend]
            .compactMap { value in
                guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty else {
                    return nil
                }
                return value
            }
    }

    enum CodingKeys: String, CodingKey {
        case backend
        case agentID = "agent_id"
        case customAgentID = "custom_agent_id"
        case id
        case name
    }
}

private struct AionUIChannelPlugin: Decodable {
    var type: String
    var enabled: Bool
}

private struct AionUIAssistantUser: Decodable {
    var id: String
    var platformUserID: String
    var platformType: String
    var displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case platformUserID = "platform_user_id"
        case platformType = "platform_type"
        case displayName = "display_name"
    }
}

private struct AionUIChannelConversationRow: Decodable {
    var id: String
}

private struct AionUIChannelConversationExtra: Encodable {
    var backend: String = "custom"
    var mcpServerIDs: [String] = []
    var mcpServers: [String] = []
    var mcpStatuses: [String] = []
    var sessionMode: String = "default"
    var skills: [String] = [
        "aionui-skills",
        "cron",
        "officecli",
        "skill-creator"
    ]
    var workspace: String
    var agentID: String
    var customAgentID: String
    var agentName: String

    enum CodingKeys: String, CodingKey {
        case backend
        case mcpServerIDs = "mcp_server_ids"
        case mcpServers = "mcp_servers"
        case mcpStatuses = "mcp_statuses"
        case sessionMode = "session_mode"
        case skills
        case workspace
        case agentID = "agent_id"
        case customAgentID = "custom_agent_id"
        case agentName = "agent_name"
    }
}

private struct AionUIChannelAgentPreferenceUpdate: Encodable {
    var platform: String
    var preference: AionUIChannelAgentPreference

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encode(
            preference,
            forKey: DynamicCodingKey("assistant.\(platform).agent")
        )
    }
}

private struct AionUIChannelAgentPreference: Encodable {
    var agentType: String
    var backend: String
    var agentID: String
    var customAgentID: String
    var id: String
    var name: String

    enum CodingKeys: String, CodingKey {
        case agentType = "agent_type"
        case backend
        case agentID = "agent_id"
        case customAgentID = "custom_agent_id"
        case id
        case name
    }
}

private struct AionUIExtensionManifest: Encodable {
    var schema: String = "https://raw.githubusercontent.com/iOfficeAI/AionHub/spec/v0/extension-manifest.schema.json"
    var name: String
    var displayName: String
    var version: String
    var description: String
    var author: String
    var engine: AionUIExtensionEngine
    var contributes: AionUIExtensionContributes

    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case name
        case displayName
        case version
        case description
        case author
        case engine
        case contributes
    }
}

private struct AionUIExtensionEngine: Encodable {
    var aionui: String
}

private struct AionUIExtensionContributes: Encodable {
    var acpAdapters: [AionUIExtensionACPAdapter]
}

private struct AionUIExtensionACPAdapter: Encodable {
    var id: String
    var name: String
    var description: String
    var connectionType: String
    var cliCommand: String
    var acpArgs: [String]
    var defaultCliPath: String
    var authRequired: Bool
    var supportsStreaming: Bool
    var models: [String]
}

private struct AionUIExtensionStates: Codable {
    var version: Int
    var extensions: [String: AionUIExtensionState]

    init(
        version: Int = 1,
        extensions: [String: AionUIExtensionState] = [:]
    ) {
        self.version = version
        self.extensions = extensions
    }
}

private struct AionUIExtensionState: Codable {
    var installed: Bool
    var enabled: Bool
    var lastVersion: String

    init(
        installed: Bool = true,
        enabled: Bool = true,
        lastVersion: String
    ) {
        self.installed = installed
        self.enabled = enabled
        self.lastVersion = lastVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        installed = (try? container.decode(Bool.self, forKey: .installed)) ?? true
        enabled = (try? container.decode(Bool.self, forKey: .enabled)) ?? true
        lastVersion = (try? container.decode(String.self, forKey: .lastVersion)) ?? MLXServerCore.version
    }

    enum CodingKeys: String, CodingKey {
        case installed
        case enabled
        case lastVersion
    }
}

private struct AionUIChannelSettingsSyncRequest: Encodable {
    var platform: String
}

private struct AionUIChannelSettingsSyncResponse: Decodable {
    var success: Bool?
    var message: String?
}

private struct AionUICustomAgentRequest: Encodable {
    var name: String
    var command: String
    var icon: String
    var args: [String]
    var enabled: Bool
    var env: [AionUICustomAgentEnvironmentVariable]
    var advanced: AionUICustomAgentAdvanced
    var backend: String
    var agentType: String = "acp"

    enum CodingKeys: String, CodingKey {
        case name
        case command
        case icon
        case args
        case enabled
        case env
        case advanced
        case backend
        case agentType = "agent_type"
    }
}

private struct AionUICustomAgentEnvironmentVariable: Encodable {
    var name: String
    var value: String
}

private struct AionUICustomAgentAdvanced: Encodable {}

private struct AionUIEmptyRequest: Encodable {}

private struct AionUIEmptyResponse: Decodable {}

private final class AionUIHTTPResponseBox: @unchecked Sendable {
    var result: Result<(data: Data, response: HTTPURLResponse), Error>?
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

private struct XcodeClaudeCodeSettings: Encodable {
    var env: [String: String]
}

private struct CodexModelCatalog: Encodable {
    var models: [CodexModelCatalogEntry]
}

private struct CodexModelCatalogEntry: Encodable {
    var slug: String
    var displayName: String
    var baseInstructions: String
    var contextWindow: Int

    enum CodingKeys: String, CodingKey {
        case slug
        case displayName = "display_name"
        case description
        case defaultReasoningLevel = "default_reasoning_level"
        case supportedReasoningLevels = "supported_reasoning_levels"
        case shellType = "shell_type"
        case visibility
        case supportedInAPI = "supported_in_api"
        case priority
        case additionalSpeedTiers = "additional_speed_tiers"
        case availabilityNUX = "availability_nux"
        case upgrade
        case baseInstructions = "base_instructions"
        case modelMessages = "model_messages"
        case supportsReasoningSummaries = "supports_reasoning_summaries"
        case defaultReasoningSummary = "default_reasoning_summary"
        case supportVerbosity = "support_verbosity"
        case defaultVerbosity = "default_verbosity"
        case applyPatchToolType = "apply_patch_tool_type"
        case webSearchToolType = "web_search_tool_type"
        case truncationPolicy = "truncation_policy"
        case supportsParallelToolCalls = "supports_parallel_tool_calls"
        case supportsImageDetailOriginal = "supports_image_detail_original"
        case contextWindow = "context_window"
        case maxContextWindow = "max_context_window"
        case autoCompactTokenLimit = "auto_compact_token_limit"
        case effectiveContextWindowPercent = "effective_context_window_percent"
        case experimentalSupportedTools = "experimental_supported_tools"
        case inputModalities = "input_modalities"
        case supportsSearchTool = "supports_search_tool"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(slug, forKey: .slug)
        try container.encode(displayName, forKey: .displayName)
        try container.encode("mlx-server local model", forKey: .description)
        try container.encodeNil(forKey: .defaultReasoningLevel)
        try container.encode([String](), forKey: .supportedReasoningLevels)
        try container.encode("default", forKey: .shellType)
        try container.encode("list", forKey: .visibility)
        try container.encode(true, forKey: .supportedInAPI)
        try container.encode(0, forKey: .priority)
        try container.encode([String](), forKey: .additionalSpeedTiers)
        try container.encodeNil(forKey: .availabilityNUX)
        try container.encodeNil(forKey: .upgrade)
        try container.encode(baseInstructions, forKey: .baseInstructions)
        try container.encodeNil(forKey: .modelMessages)
        try container.encode(false, forKey: .supportsReasoningSummaries)
        try container.encode("auto", forKey: .defaultReasoningSummary)
        try container.encode(false, forKey: .supportVerbosity)
        try container.encodeNil(forKey: .defaultVerbosity)
        try container.encodeNil(forKey: .applyPatchToolType)
        try container.encode("text", forKey: .webSearchToolType)
        try container.encode(
            CodexTruncationPolicy(mode: "bytes", limit: 10_000),
            forKey: .truncationPolicy
        )
        try container.encode(false, forKey: .supportsParallelToolCalls)
        try container.encode(false, forKey: .supportsImageDetailOriginal)
        try container.encode(contextWindow, forKey: .contextWindow)
        try container.encode(contextWindow, forKey: .maxContextWindow)
        try container.encodeNil(forKey: .autoCompactTokenLimit)
        try container.encode(95, forKey: .effectiveContextWindowPercent)
        try container.encode([String](), forKey: .experimentalSupportedTools)
        try container.encode(["text"], forKey: .inputModalities)
        try container.encode(false, forKey: .supportsSearchTool)
    }
}

private struct CodexTruncationPolicy: Encodable {
    var mode: String
    var limit: Int
}

private extension String {
    var dropTrailingSlash: String {
        hasSuffix("/") ? String(dropLast()) : self
    }

    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension MLXServerAgentIntegrationService {
    static func aionUIModelConfigOptionsJSON(
        models: [String],
        thinkingOptions: [String] = [],
        defaultThinking: String? = nil
    ) throws -> String {
        try compactJSONString(
            AionUIAgentConfigOptions(
                configOptions: aionUIModelConfigOptions(
                    models: models,
                    thinkingOptions: thinkingOptions,
                    defaultThinking: defaultThinking
                )
            )
        )
    }

    static func aionUICoderThinkingOptions(
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) -> (options: [String], defaultSelection: String?) {
        let metadata = aionUICoderThinkingMetadata(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        return (metadata.options, metadata.defaultSelection)
    }

    static func aionUICustomAgentRequestJSONForTesting(
        name: String,
        command: String,
        args: [String]
    ) throws -> String {
        try compactJSONString(
            aionUICustomAgentRequest(
                for: AionUICustomAgentDefinition(
                    name: name,
                    command: command,
                    args: args,
                    defaultThinking: nil
                )
            )
        )
    }

    static func aionUIChannelAgentPreferenceJSONForTesting(
        id: String,
        name: String,
        backend: String?
    ) throws -> String {
        try compactJSONString(
            aionUIChannelAgentPreference(
                for: AionUIAgent(
                    id: id,
                    name: name,
                    backend: backend,
                    agentSource: "custom",
                    command: nil,
                    args: nil
                )
            )
        )
    }
}
