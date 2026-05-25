//
//  MLXServerAgentIntegrations.swift
//  mlx-server
//

import Foundation

public enum MLXServerCodexConfigurationTarget: Sendable, Equatable {
    case desktop
    case xcode
}

public struct MLXServerAgentIntegrationConfiguration: Sendable, Equatable {
    public var baseURL: String
    public var modelID: String
    public var contextWindow: Int?

    public init(
        baseURL: String,
        modelID: String,
        contextWindow: Int? = nil
    ) {
        self.baseURL = baseURL
        self.modelID = modelID
        self.contextWindow = contextWindow
    }
}

public struct MLXServerAgentIntegrationStatus: Sendable, Equatable {
    public var codexCLIEnabled: Bool
    public var codexAppEnabled: Bool
    public var codexXcodeAppEnabled: Bool
    public var xcodeClaudeCodeEnabled: Bool

    public init(
        codexCLIEnabled: Bool,
        codexAppEnabled: Bool,
        codexXcodeAppEnabled: Bool,
        xcodeClaudeCodeEnabled: Bool
    ) {
        self.codexCLIEnabled = codexCLIEnabled
        self.codexAppEnabled = codexAppEnabled
        self.codexXcodeAppEnabled = codexXcodeAppEnabled
        self.xcodeClaudeCodeEnabled = xcodeClaudeCodeEnabled
    }
}

public enum MLXServerAgentIntegrationService {
    public static let codexProviderID = "mlx-server"
    public static let codexCLIProfileName = "mlx-server"
    public static let codexAppProfileName = "mlx-server-codex-app"
    public static let codexModelCatalogFilename = "mlx-server-codex-models.json"

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
                "ANTHROPIC_AUTH_TOKEN": "",
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
        codexProfileUsesMLXServer(
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
}

private extension MLXServerAgentIntegrationService {
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

        updatedText.append(
            """
            [model_providers.\(tomlQuotedKey(codexProviderID))]
            name = "mlx-server"
            base_url = "\(tomlEscapedString(providerBaseURL))"
            wire_api = "responses"

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

    static func tomlEscapedString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

public enum MLXServerAgentIntegrationError: LocalizedError, Sendable, Equatable {
    case emptyRequiredValue(String)

    public var errorDescription: String? {
        switch self {
        case .emptyRequiredValue(let fieldName):
            return "\(fieldName) can not be empty."
        }
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
}
