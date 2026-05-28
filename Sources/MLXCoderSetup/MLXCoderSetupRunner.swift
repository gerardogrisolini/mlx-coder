//
//  MLXCoderSetupRunner.swift
//  mlx-coder
//
//  Created by Codex on 23/05/26.
//

import Foundation
import MLXCoderCore

public enum MLXCoderSetupRunner {
    public static let option = "--setup"

    public static func shouldRunSetup(arguments: [String]) -> Bool {
        arguments.dropFirst().contains(option)
    }

    public static func run(arguments: [String]) async throws {
        _ = arguments
        guard TerminalRawInput.supportsInteractiveInput() else {
            throw MLXCoderSetupError.nonInteractiveTerminal
        }

        AgentOutput.standardError.writeString(
            """
            mlx-coder setup
            Configuring support files at:
            \(MLXCoderSupportFileService.supportDirectoryURL().path)

            """
        )

        let settingsURL = AgentSettingsManifestStore.settingsURL()
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            do {
                _ = try AgentSettingsManifestStore.loadRequired(from: settingsURL)
                let shouldReconfigure = try promptYesNo(
                    "settings.json already exists. Reconfigure providers and models?",
                    defaultValue: false
                )
                if !shouldReconfigure {
                    let result = try MLXCoderSupportFileService.ensureBaseFiles()
                    printResult(result, settingsWasWritten: false)
                    printCompletion()
                    return
                }
            } catch {
                let shouldOverwrite = try promptYesNo(
                    "settings.json exists but is invalid. Rewrite it?",
                    defaultValue: true
                )
                guard shouldOverwrite else {
                    throw error
                }
            }
        }

        let manifest = try await buildSettingsManifest()
        let result = try MLXCoderSupportFileService.ensureRequiredFiles(
            settingsManifest: manifest,
            overwriteSettings: true
        )
        printResult(result, settingsWasWritten: true)
        printCompletion()
    }

    private static func printCompletion() {
        AgentOutput.standardError.writeString("\nSetup completed.\n\n")
    }

    private static func buildSettingsManifest() async throws -> AgentSettingsManifest {
        var providerInputs: [SetupProviderInput] = []
        repeat {
            providerInputs.append(try await readProvider())
        } while try promptYesNo("Add another provider?", defaultValue: false)

        let providers = providerInputs.map { input in
            AgentSettingsProviderManifest(
                id: input.id,
                name: input.name,
                baseURL: input.baseURL,
                chatEndpoint: input.chatEndpoint
            )
        }
        let models = providerInputs.flatMap(\.models)
        guard !models.isEmpty else {
            throw MLXCoderSetupError.noModelsConfigured
        }

        let selectedModelID: String
        if models.count == 1 {
            selectedModelID = models[0].id
        } else {
            selectedModelID = try selectDefaultModel(from: models)
        }

        let selectedThinkingSelection = models
            .first { $0.matches(selectedModelID) }?
            .resolvedDefaultThinkingSelection
        let apiKeysByProviderID: [String: String] = Dictionary(
            uniqueKeysWithValues: providerInputs.compactMap { input -> (String, String)? in
                guard let apiKey = input.apiKey else {
                    return nil
                }
                return (input.id.uuidString.lowercased(), apiKey)
            }
        )

        return AgentSettingsManifest(
            providers: providers,
            models: models,
            selectedModelID: selectedModelID,
            selectedThinkingSelection: selectedThinkingSelection,
            remoteAPIKeysByProviderID: apiKeysByProviderID
        )
    }

    private static func readProvider() async throws -> SetupProviderInput {
        switch try promptProviderKind() {
        case .remoteAPI:
            return try await readRemoteAPIProvider()
        case .chatGPTSubscription:
            return try await readChatGPTSubscriptionProvider()
        }
    }

    private static func readRemoteAPIProvider() async throws -> SetupProviderInput {
        AgentOutput.standardError.writeString("\nProvider OpenAI-compatible\n")
        let id = UUID()
        let name = try promptString(
            "Provider name",
            defaultValue: AgentRemoteProvider.defaultOpenRouterName,
            allowEmpty: false
        )
        let baseURL = try promptString(
            "Base URL",
            defaultValue: AgentRemoteProvider.defaultOpenRouterBaseURL,
            allowEmpty: false
        )
        let chatEndpoint = try promptEndpoint()
        let apiKey = try promptString(
            "API key (optional)",
            defaultValue: nil,
            allowEmpty: true
        )

        let models = try await readModels(
            providerID: id,
            providerName: name,
            baseURL: baseURL,
            chatEndpoint: chatEndpoint,
            apiKey: apiKey.nilIfBlank
        )

        guard !models.isEmpty else {
            throw MLXCoderSetupError.noModelsConfigured
        }

        return SetupProviderInput(
            id: id,
            name: name,
            baseURL: baseURL,
            chatEndpoint: chatEndpoint,
            apiKey: apiKey.nilIfBlank,
            models: models
        )
    }

    private static func readChatGPTSubscriptionProvider() async throws -> SetupProviderInput {
        AgentOutput.standardError.writeString("\nChatGPT Subscription\n")
        try await ensureChatGPTSubscriptionCredentials()

        let id = AgentRemoteProvider.chatGPTSubscriptionProviderID
        let name = CodexAgentModel.displayTitle
        let baseURL = AgentRemoteProvider.chatGPTSubscriptionBaseURL
        let chatEndpoint = AgentRemoteChatEndpoint.responses
        let models = try selectChatGPTSubscriptionModels().map { option in
            chatGPTSubscriptionModelManifest(
                option: option,
                providerID: id,
                providerName: name,
                baseURL: baseURL,
                chatEndpoint: chatEndpoint
            )
        }

        guard !models.isEmpty else {
            throw MLXCoderSetupError.noModelsConfigured
        }

        return SetupProviderInput(
            id: id,
            name: name,
            baseURL: baseURL,
            chatEndpoint: chatEndpoint,
            apiKey: nil,
            models: models
        )
    }

    private static func ensureChatGPTSubscriptionCredentials() async throws {
#if os(macOS)
        do {
            _ = try await CodexAgentModel.loadValidCredentials()
            return
        } catch {
            AgentOutput.standardError.writeString(
                "ChatGPT Subscription is not connected. Opening Codex login in the browser.\n"
            )
        }

        let session = try await ChatGPTSubscriptionAuthService.startSignIn()
        let didOpen = await ChatGPTSubscriptionAuthService.openAuthorizationURL(
            session.authorizationURL
        )
        guard didOpen else {
            throw ChatGPTSubscriptionAuthError.browserOpenFailed
        }

        AgentOutput.standardError.writeString(
            """
            Complete login in the browser.
            If the local callback does not return automatically, paste the callback URL or code here.
            Otherwise press Return when the browser shows completion.

            """
        )
        let callbackInput = try promptString(
            "Callback URL/code (optional)",
            defaultValue: nil,
            allowEmpty: true
        )
        if let callbackInput = callbackInput.nilIfBlank {
            try session.submitAuthorizationInput(callbackInput)
        }

        _ = try await session.waitForCredentials()
        AgentOutput.standardError.writeString("ChatGPT Subscription connected.\n")
#else
        throw MLXCoderSetupError.chatGPTSubscriptionUnsupported
#endif
    }

    private static func readModels(
        providerID: UUID,
        providerName: String,
        baseURL: String,
        chatEndpoint: AgentRemoteChatEndpoint,
        apiKey: String?
    ) async throws -> [AgentSettingsModelManifest] {
        if try promptYesNo("Load the model list from the server /models endpoint?", defaultValue: true) {
            do {
                let catalogModels = try await RemoteModelCatalogClient()
                    .fetchModels(baseURL: baseURL, apiKey: apiKey)
                    .sorted(by: remoteModelSort)
                guard !catalogModels.isEmpty else {
                    throw MLXCoderSetupError.noRemoteModelsReturned
                }

                let selectedModels = try selectRemoteModels(from: catalogModels)
                return selectedModels.map {
                    remoteModelManifest(
                        from: $0,
                        providerID: providerID,
                        providerName: providerName,
                        baseURL: baseURL,
                        chatEndpoint: chatEndpoint
                    )
                }
            } catch {
                AgentOutput.standardError.writeString(
                    "Unable to load /models: \(error.localizedDescription)\n"
                )
                guard try promptYesNo("Enter models manually?", defaultValue: true) else {
                    throw error
                }
            }
        }

        var models: [AgentSettingsModelManifest] = []
        repeat {
            models.append(
                try readModel(
                    providerID: providerID,
                    providerName: providerName,
                    baseURL: baseURL,
                    chatEndpoint: chatEndpoint,
                    modelIndex: models.count
                )
            )
        } while try promptYesNo("Add another model for \(providerName)?", defaultValue: false)

        return models
    }

    private static func selectRemoteModels(
        from models: [OpenRouterModelInfo]
    ) throws -> [OpenRouterModelInfo] {
        AgentOutput.standardError.writeString("\nModels available from /models:\n")
        for (index, model) in models.enumerated() {
            AgentOutput.standardError.writeString(
                "  \(index + 1). \(remoteModelListTitle(model))\n"
            )
        }

        let value = try promptString(
            "Model selection (number, list like 1,3, or all)",
            defaultValue: "1",
            allowEmpty: false
        )
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedValue == "all" {
            return models
        }

        let tokens = normalizedValue
            .split { $0 == "," || $0 == " " || $0 == ";" }
            .map(String.init)
        guard !tokens.isEmpty else {
            throw MLXCoderSetupError.invalidChoice(value)
        }

        var selected: [OpenRouterModelInfo] = []
        var seenIndexes = Set<Int>()
        for token in tokens {
            guard let index = Int(token),
                  models.indices.contains(index - 1),
                  seenIndexes.insert(index - 1).inserted else {
                throw MLXCoderSetupError.invalidChoice(value)
            }
            selected.append(models[index - 1])
        }
        return selected
    }

    private static func selectChatGPTSubscriptionModels() throws -> [CodexAgentModel.ModelOption] {
        let models = CodexAgentModel.availableModels
        AgentOutput.standardError.writeString("\nChatGPT Subscription models:\n")
        for (index, model) in models.enumerated() {
            let context = model.contextWindowTokenLimit.map { "ctx \($0)" } ?? "ctx default"
            AgentOutput.standardError.writeString(
                "  \(index + 1). \(model.title) (\(model.modelID)) [\(context), thinking]\n"
            )
        }

        let value = try promptString(
            "Model selection (number, list like 1,3, or all)",
            defaultValue: "1",
            allowEmpty: false
        )
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedValue == "all" {
            return models
        }

        let tokens = normalizedValue
            .split { $0 == "," || $0 == " " || $0 == ";" }
            .map(String.init)
        guard !tokens.isEmpty else {
            throw MLXCoderSetupError.invalidChoice(value)
        }

        var selected: [CodexAgentModel.ModelOption] = []
        var seenIndexes = Set<Int>()
        for token in tokens {
            guard let index = Int(token),
                  models.indices.contains(index - 1),
                  seenIndexes.insert(index - 1).inserted else {
                throw MLXCoderSetupError.invalidChoice(value)
            }
            selected.append(models[index - 1])
        }
        return selected
    }

    private static func remoteModelManifest(
        from model: OpenRouterModelInfo,
        providerID: UUID,
        providerName: String,
        baseURL: String,
        chatEndpoint: AgentRemoteChatEndpoint
    ) -> AgentSettingsModelManifest {
        AgentSettingsModelManifestFactory.remoteAPIModel(
            title: model.name == model.id ? nil : model.name,
            modelID: model.id,
            providerID: providerID,
            providerName: providerName,
            baseURL: baseURL,
            chatEndpoint: chatEndpoint,
            configuredContextWindowLimit: model.contextLength,
            generationParameterOverrides: model.generationParameterOverrides,
            thinkingSupport: model.thinkingSupport
        )
    }

    private static func chatGPTSubscriptionModelManifest(
        option: CodexAgentModel.ModelOption,
        providerID: UUID,
        providerName: String,
        baseURL: String,
        chatEndpoint: AgentRemoteChatEndpoint
    ) -> AgentSettingsModelManifest {
        let manifestID = CodexAgentModel.selectionID(forModelID: option.modelID)
        return AgentSettingsModelManifestFactory.remoteAPIModel(
            manifestID: manifestID,
            title: option.title,
            modelID: option.modelID,
            providerID: providerID,
            providerName: providerName,
            baseURL: baseURL,
            chatEndpoint: chatEndpoint,
            configuredContextWindowLimit: option.contextWindowTokenLimit,
            generationParameterOverrides: nil,
            thinkingSupport: CodexAgentModel.thinkingSupport
        )
    }

    private static func remoteModelListTitle(
        _ model: OpenRouterModelInfo
    ) -> String {
        var details: [String] = []
        if let contextLength = model.contextLength {
            details.append("ctx \(contextLength)")
        }
        if model.thinkingSupport?.supportsThinking == true {
            details.append("thinking")
        }
        if model.generationParameterOverrides != nil {
            details.append("params")
        }
        if let status = remoteModelStatus(model) {
            details.append(status)
        }

        let suffix = details.isEmpty ? "" : " [\(details.joined(separator: ", "))]"
        return "\(model.name) (\(model.id))\(suffix)"
    }

    private static func remoteModelStatus(
        _ model: OpenRouterModelInfo
    ) -> String? {
        if model.serverLoaded == true || model.loaded == true {
            return "loaded"
        }
        if model.installed == true {
            return "installed"
        }
        if model.installed == false {
            return "non installato"
        }
        return nil
    }

    private static func remoteModelSort(
        lhs: OpenRouterModelInfo,
        rhs: OpenRouterModelInfo
    ) -> Bool {
        let lhsRank = remoteModelRank(lhs)
        let rhsRank = remoteModelRank(rhs)
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }

        let nameComparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }
        return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
    }

    private static func remoteModelRank(
        _ model: OpenRouterModelInfo
    ) -> Int {
        if model.serverLoaded == true || model.loaded == true {
            return 0
        }
        if model.installed == true {
            return 1
        }
        if model.installed == false {
            return 3
        }
        return 2
    }

    private static func readModel(
        providerID: UUID,
        providerName: String,
        baseURL: String,
        chatEndpoint: AgentRemoteChatEndpoint,
        modelIndex: Int
    ) throws -> AgentSettingsModelManifest {
        AgentOutput.standardError.writeString("\nModel\n")
        let defaultModelID = modelIndex == 0 ? AgentRemoteProvider.defaultOpenRouterModelID : nil
        let modelID = try promptString(
            "Model ID",
            defaultValue: defaultModelID,
            allowEmpty: false
        )
        let title = try promptString(
            "Display title (optional)",
            defaultValue: nil,
            allowEmpty: true
        )
        let contextLimit = try promptPositiveInt(
            "Context window token limit (optional)",
            defaultValue: nil
        )
        let maxTokens = try promptPositiveInt(
            "Max output tokens per request (optional)",
            defaultValue: nil
        )
        let thinking = try promptThinking()
        let provider = AgentRemoteProvider(
            id: providerID,
            name: providerName,
            baseURL: baseURL,
            modelID: modelID,
            chatEndpoint: chatEndpoint
        )
        let manifestID = "remoteapi:\(providerID.uuidString.lowercased()):\(modelID)"
        return AgentSettingsModelManifest(
            id: manifestID,
            kind: .remoteAPI,
            title: title.nilIfBlank,
            llmID: manifestID,
            modelID: modelID,
            providerID: providerID,
            provider: provider,
            configuredContextWindowLimit: contextLimit,
            generationParameterOverrides: AgentGenerationParameterOverrides(
                maxTokens: maxTokens
            ),
            thinkingOptions: thinking.options,
            defaultThinkingSelection: thinking.defaultSelection
        )
    }

    private static func promptEndpoint() throws -> AgentRemoteChatEndpoint {
        AgentOutput.standardError.writeString(
            """
            Endpoint:
              1. chat/completions
              2. responses
            """ + "\n"
        )
        let value = try promptString("Choice", defaultValue: "1", allowEmpty: false)
        switch value.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1", "chat", "chat_completions", "chat/completions":
            return .chatCompletions
        case "2", "responses":
            return .responses
        default:
            throw MLXCoderSetupError.invalidChoice(value)
        }
    }

    private static func promptProviderKind() throws -> SetupProviderKind {
        AgentOutput.standardError.writeString(
            """
            Provider:
              1. OpenAI-compatible / MLX server
              2. ChatGPT Subscription
            """ + "\n"
        )
        let value = try promptString("Choice", defaultValue: "1", allowEmpty: false)
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "remote", "remoteapi", "openai", "mlx", "server":
            return .remoteAPI
        case "2", "chatgpt", "subscription", "chatgpt subscription", "codex":
            return .chatGPTSubscription
        default:
            throw MLXCoderSetupError.invalidChoice(value)
        }
    }

    private static func promptThinking() throws -> SetupThinkingInput {
        guard try promptYesNo("Does the model support thinking/reasoning?", defaultValue: false) else {
            return SetupThinkingInput(options: nil, defaultSelection: nil)
        }

        AgentOutput.standardError.writeString(
            """
            Thinking type:
              1. on/off
              2. effort levels (minimal, low, medium, high, xhigh)
            """
        )
        let value = try promptString("Choice", defaultValue: "2", allowEmpty: false)
        let options: [AgentThinkingSelection]
        let defaultSelection: AgentThinkingSelection
        switch value.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1", "on", "enabled":
            options = [.off, .enabled]
            defaultSelection = .enabled
        case "2", "effort", "levels":
            options = [.off, .minimal, .low, .medium, .high, .xhigh]
            defaultSelection = .medium
        default:
            throw MLXCoderSetupError.invalidChoice(value)
        }
        return SetupThinkingInput(options: options, defaultSelection: defaultSelection)
    }

    private static func selectDefaultModel(
        from models: [AgentSettingsModelManifest]
    ) throws -> String {
        AgentOutput.standardError.writeString("\nDefault model:\n")
        for (index, model) in models.enumerated() {
            AgentOutput.standardError.writeString("  \(index + 1). \(model.displayTitle)\n")
        }
        let value = try promptString("Choice", defaultValue: "1", allowEmpty: false)
        guard let index = Int(value),
              models.indices.contains(index - 1) else {
            throw MLXCoderSetupError.invalidChoice(value)
        }
        return models[index - 1].id
    }

    private static func promptString(
        _ label: String,
        defaultValue: String?,
        allowEmpty: Bool
    ) throws -> String {
        let suffix = defaultValue.map { " [\($0)]" } ?? ""
        AgentOutput.standardError.writeString("\(label)\(suffix): ")
        guard let rawValue = readLine() else {
            throw MLXCoderSetupError.cancelled
        }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty, let defaultValue {
            return defaultValue
        }
        if value.isEmpty, !allowEmpty {
            throw MLXCoderSetupError.emptyRequiredValue(label)
        }
        return value
    }

    private static func promptYesNo(
        _ label: String,
        defaultValue: Bool
    ) throws -> Bool {
        let suffix = defaultValue ? " [Y/n]" : " [y/N]"
        let value = try promptString(label + suffix, defaultValue: nil, allowEmpty: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if value.isEmpty {
            return defaultValue
        }
        switch value {
        case "y", "yes":
            return true
        case "n", "no":
            return false
        default:
            throw MLXCoderSetupError.invalidChoice(value)
        }
    }

    private static func promptPositiveInt(
        _ label: String,
        defaultValue: Int?
    ) throws -> Int? {
        let defaultText = defaultValue.map { String($0) }
        let value = try promptString(label, defaultValue: defaultText, allowEmpty: true)
        guard !value.isEmpty else {
            return defaultValue
        }
        guard let intValue = Int(value), intValue > 0 else {
            throw MLXCoderSetupError.invalidChoice(value)
        }
        return intValue
    }

    private static func printResult(
        _ result: MLXCoderSupportFileResult,
        settingsWasWritten: Bool
    ) {
        if !result.createdFilenames.isEmpty {
            AgentOutput.standardError.writeString(
                "Created: \(result.createdFilenames.joined(separator: ", "))\n"
            )
        }
        if !result.preservedFilenames.isEmpty {
            AgentOutput.standardError.writeString(
                "Preserved: \(result.preservedFilenames.joined(separator: ", "))\n"
            )
        }
        if settingsWasWritten && !result.createdFilenames.contains(AgentSettingsManifestStore.settingsFilename) {
            AgentOutput.standardError.writeString("Updated: settings.json\n")
        }
    }
}

private struct SetupProviderInput {
    let id: UUID
    let name: String
    let baseURL: String
    let chatEndpoint: AgentRemoteChatEndpoint
    let apiKey: String?
    let models: [AgentSettingsModelManifest]
}

private struct SetupThinkingInput {
    let options: [AgentThinkingSelection]?
    let defaultSelection: AgentThinkingSelection?
}

private enum SetupProviderKind {
    case remoteAPI
    case chatGPTSubscription
}

private enum MLXCoderSetupError: LocalizedError {
    case nonInteractiveTerminal
    case cancelled
    case emptyRequiredValue(String)
    case invalidChoice(String)
    case noModelsConfigured
    case noRemoteModelsReturned
    case chatGPTSubscriptionUnsupported

    var errorDescription: String? {
        switch self {
        case .nonInteractiveTerminal:
            return "Setup requires an interactive terminal."
        case .cancelled:
            return "Setup cancelled."
        case let .emptyRequiredValue(label):
            return "\(label) is required."
        case let .invalidChoice(value):
            return "Invalid setup choice: \(value)"
        case .noModelsConfigured:
            return "At least one provider model is required."
        case .noRemoteModelsReturned:
            return "The server did not return any models from /models."
        case .chatGPTSubscriptionUnsupported:
            return "ChatGPT Subscription setup is available on macOS."
        }
    }
}
