//
//  MLXCoderSetupRunner+ProvidersAndModels.swift
//  mlx-coder
//

import Foundation
import MLXCoderCore

extension MLXCoderSetupRunner {
    static func configureProvidersAndModels(
        existingManifest: AgentSettingsManifest?
    ) async throws -> AgentSettingsManifest {
        var providerInputs = try await reconfigureExistingProviders(existingManifest)
        if providerInputs.isEmpty {
            repeat {
                providerInputs.append(try await readProvider())
            } while try promptYesNo("Add another provider?", defaultValue: false)
        } else {
            while try promptYesNo("Add another provider?", defaultValue: false) {
                providerInputs.append(try await readProvider())
            }
        }

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

        let selectedModelID = preservedOrFirstSelectedModelID(
            from: models,
            existingSelectedModelID: existingManifest?.selectedModelID
        )
        let selectedThinkingSelection = setupDefaultThinkingSelection(
            for: models.first { $0.matches(selectedModelID) },
            existingSelection: existingManifest?.selectedThinkingSelection
        )
        let apiKeysByProviderID: [String: String] = Dictionary(
            uniqueKeysWithValues: providerInputs.compactMap { input -> (String, String)? in
                guard let apiKey = input.apiKey else {
                    return nil
                }
                return (input.id.uuidString.lowercased(), apiKey)
            }
        )
        let subscriptionCredentials = latestSubscriptionCredentials(fallback: existingManifest)

        return AgentSettingsManifest(
            version: existingManifest?.version ?? AgentSettingsManifest.currentVersion,
            providers: providers,
            models: models,
            selectedModelID: selectedModelID,
            selectedThinkingSelection: selectedThinkingSelection,
            telegram: existingManifest?.telegram,
            voice: existingManifest?.voice,
            remoteAPIKeysByProviderID: apiKeysByProviderID,
            localExecAllowedCommands: existingManifest?.localExecAllowedCommands ?? [],
            chatGPTSubscriptionCredentials: subscriptionCredentials.chatGPT,
            anthropicSubscriptionCredentials: subscriptionCredentials.anthropic
        )
    }

    static func latestSubscriptionCredentials(
        fallback manifest: AgentSettingsManifest?
    ) -> (
        chatGPT: CodexAgentCredentials?,
        anthropic: AnthropicSubscriptionCredentials?
    ) {
        let latestManifest = AgentSettingsManifestStore.load()
        return (
            latestManifest?.chatGPTSubscriptionCredentials ?? manifest?.chatGPTSubscriptionCredentials,
            latestManifest?.anthropicSubscriptionCredentials ?? manifest?.anthropicSubscriptionCredentials
        )
    }

    static func preservedOrFirstSelectedModelID(
        from models: [AgentSettingsModelManifest],
        existingSelectedModelID: String?
    ) -> String {
        if let existingSelectedModelID,
           let model = models.first(where: { $0.matches(existingSelectedModelID) }) {
            return model.id
        }
        return models[0].id
    }

    static func reconfigureExistingProviders(
        _ manifest: AgentSettingsManifest?
    ) async throws -> [SetupProviderInput] {
        guard let manifest,
              !manifest.providers.isEmpty else {
            return []
        }

        printProviders(
            title: "Configured providers",
            providers: manifest.providers,
            allModels: manifest.models
        )

        let deletedProviderIndexes = try promptProviderIndexes(
            "Provider to delete (number, list like 1,3, all, or none)",
            providerCount: manifest.providers.count
        )
        let remainingProviders = manifest.providers.enumerated()
            .filter { !deletedProviderIndexes.contains($0.offset) }
            .map(\.element)

        guard !remainingProviders.isEmpty else {
            return []
        }

        if !deletedProviderIndexes.isEmpty {
            printProviders(
                title: "Remaining providers",
                providers: remainingProviders,
                allModels: manifest.models
            )
        }

        let selectedProviderIndexes = try promptProviderIndexes(
            "Provider to reconfigure (number, list like 1,3, all, or none)",
            providerCount: remainingProviders.count
        )
        var providerInputs: [SetupProviderInput] = []
        for (index, provider) in remainingProviders.enumerated() {
            let existingModels = models(for: provider, in: manifest.models)
            let existingAPIKey = manifest.remoteAPIKeysByProviderID[
                provider.id.uuidString.lowercased()
            ]
            if selectedProviderIndexes.contains(index) {
                if isChatGPTSubscriptionProvider(provider) {
                    providerInputs.append(
                        try await readChatGPTSubscriptionProvider(
                            existingModels: existingModels
                        )
                    )
                } else if isAnthropicSubscriptionProvider(provider) {
                    providerInputs.append(
                        try await readAnthropicSubscriptionProvider(
                            existingModels: existingModels
                        )
                    )
                } else {
                    providerInputs.append(
                        try await readRemoteAPIProvider(
                            existingProvider: provider,
                            existingModels: existingModels,
                            existingAPIKey: existingAPIKey
                        )
                    )
                }
            } else {
                providerInputs.append(
                    preserveProviderInput(
                        provider: provider,
                        models: existingModels,
                        apiKey: existingAPIKey
                    )
                )
            }
        }
        return providerInputs
    }

    static func printProviders(
        title: String,
        providers: [AgentSettingsProviderManifest],
        allModels: [AgentSettingsModelManifest]
    ) {
        AgentOutput.standardError.writeString("\(title):\n")
        for (index, provider) in providers.enumerated() {
            let providerModels = models(for: provider, in: allModels)
            AgentOutput.standardError.writeString(
                "  \(index + 1). \(provider.displayTitle) (\(providerModels.count) models)\n"
            )
        }
        AgentOutput.standardError.writeString("\n")
    }

    static func promptProviderIndexes(
        _ prompt: String,
        providerCount: Int
    ) throws -> Set<Int> {
        let value = try promptString(
            prompt,
            defaultValue: "none",
            allowEmpty: false
        )
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["none", "no", "n", "skip"].contains(normalizedValue) {
            return []
        }
        if normalizedValue == "all" {
            return Set(0..<providerCount)
        }

        let tokens = normalizedValue
            .split { $0 == "," || $0 == " " || $0 == ";" }
            .map(String.init)
        guard !tokens.isEmpty else {
            throw MLXCoderSetupError.invalidChoice(value)
        }

        var selectedIndexes = Set<Int>()
        for token in tokens {
            guard let index = Int(token),
                  (1...providerCount).contains(index) else {
                throw MLXCoderSetupError.invalidChoice(value)
            }
            selectedIndexes.insert(index - 1)
        }
        return selectedIndexes
    }

    static func models(
        for provider: AgentSettingsProviderManifest,
        in models: [AgentSettingsModelManifest]
    ) -> [AgentSettingsModelManifest] {
        models.filter { model in
            (model.providerID ?? model.provider?.id) == provider.id
        }
    }

    static func preserveProviderInput(
        provider: AgentSettingsProviderManifest,
        models: [AgentSettingsModelManifest],
        apiKey: String?
    ) -> SetupProviderInput {
        SetupProviderInput(
            id: provider.id,
            name: provider.name,
            baseURL: provider.baseURL,
            chatEndpoint: provider.chatEndpoint,
            apiKey: apiKey,
            models: models
        )
    }

    static func readProvider() async throws -> SetupProviderInput {
        switch try promptProviderKind() {
        case .remoteAPI:
            return try await readRemoteAPIProvider()
        case .chatGPTSubscription:
            return try await readChatGPTSubscriptionProvider()
        case .anthropicSubscription:
            return try await readAnthropicSubscriptionProvider()
        }
    }

    static func readRemoteAPIProvider(
        existingProvider: AgentSettingsProviderManifest? = nil,
        existingModels: [AgentSettingsModelManifest] = [],
        existingAPIKey: String? = nil
    ) async throws -> SetupProviderInput {
        AgentOutput.standardError.writeString("\nProvider OpenAI-compatible\n")
        let id = existingProvider?.id ?? UUID()
        let name = try promptString(
            "Provider name",
            defaultValue: existingProvider?.name ?? AgentRemoteProvider.defaultOpenRouterName,
            allowEmpty: false
        )
        let baseURL = try promptString(
            "Base URL",
            defaultValue: existingProvider?.baseURL ?? AgentRemoteProvider.defaultOpenRouterBaseURL,
            allowEmpty: false
        )
        let chatEndpoint = try promptEndpoint(
            defaultValue: existingProvider?.chatEndpoint ?? .chatCompletions
        )
        let apiKey = try promptAPIKey(existingAPIKey: existingAPIKey, providerName: name)

        let models: [AgentSettingsModelManifest]
        if existingModels.isEmpty {
            models = try await readModels(
                providerID: id,
                providerName: name,
                baseURL: baseURL,
                chatEndpoint: chatEndpoint,
                apiKey: apiKey.nilIfBlank
            )
        } else {
            models = try await reconfigureModels(
                providerID: id,
                providerName: name,
                baseURL: baseURL,
                chatEndpoint: chatEndpoint,
                apiKey: apiKey.nilIfBlank,
                existingModels: existingModels
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
            apiKey: apiKey.nilIfBlank,
            models: models
        )
    }

    static func readChatGPTSubscriptionProvider(
        existingModels: [AgentSettingsModelManifest] = []
    ) async throws -> SetupProviderInput {
        AgentOutput.standardError.writeString("\nChatGPT Subscription\n")
        try await ensureChatGPTSubscriptionCredentials()

        let id = AgentRemoteProvider.chatGPTSubscriptionProviderID
        let name = CodexAgentModel.displayTitle
        let baseURL = AgentRemoteProvider.chatGPTSubscriptionBaseURL
        let chatEndpoint = AgentRemoteChatEndpoint.responses
        let models = try selectChatGPTSubscriptionModels(
            defaultModels: existingModels
        ).map { option in
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

    static func readAnthropicSubscriptionProvider(
        existingModels: [AgentSettingsModelManifest] = []
    ) async throws -> SetupProviderInput {
        AgentOutput.standardError.writeString("\nClaude Subscription\n")
        try await ensureAnthropicSubscriptionCredentials()

        let id = AgentRemoteProvider.anthropicSubscriptionProviderID
        let name = AnthropicSubscriptionModel.displayTitle
        let baseURL = AgentRemoteProvider.anthropicSubscriptionBaseURL
        let chatEndpoint = AgentRemoteChatEndpoint.responses
        let models = try selectAnthropicSubscriptionModels(
            defaultModels: existingModels
        ).map { option in
            anthropicSubscriptionModelManifest(
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

    static func promptAPIKey(
        existingAPIKey: String?,
        providerName: String
    ) throws -> String {
        guard existingAPIKey?.nilIfBlank != nil else {
            return try promptString(
                "API key (optional)",
                defaultValue: nil,
                allowEmpty: true
            )
        }

        guard try promptYesNo(
            "Replace stored API key for \(providerName)?",
            defaultValue: false
        ) else {
            return existingAPIKey ?? ""
        }

        return try promptString(
            "New API key (empty clears it)",
            defaultValue: nil,
            allowEmpty: true
        )
    }

    static func reconfigureModels(
        providerID: UUID,
        providerName: String,
        baseURL: String,
        chatEndpoint: AgentRemoteChatEndpoint,
        apiKey: String?,
        existingModels: [AgentSettingsModelManifest]
    ) async throws -> [AgentSettingsModelManifest] {
        AgentOutput.standardError.writeString("\nConfigured models for \(providerName):\n")
        for (index, model) in existingModels.enumerated() {
            AgentOutput.standardError.writeString("  \(index + 1). \(model.displayTitle)\n")
        }
        AgentOutput.standardError.writeString("\n")

        let deletedModelIndexes = try promptModelIndexes(
            modelCount: existingModels.count
        )
        var models: [AgentSettingsModelManifest] = existingModels.enumerated().compactMap { item -> AgentSettingsModelManifest? in
            let index = item.offset
            let model = item.element
            if deletedModelIndexes.contains(index) {
                return nil
            }
            return modelWithProvider(
                model,
                providerID: providerID,
                providerName: providerName,
                baseURL: baseURL,
                chatEndpoint: chatEndpoint
            )
        }

        while try promptYesNo(
            "Add another model for \(providerName)?",
            defaultValue: false
        ) {
            let selectedModels = try await readAdditionalModelsFromCatalog(
                providerID: providerID,
                providerName: providerName,
                baseURL: baseURL,
                chatEndpoint: chatEndpoint,
                apiKey: apiKey,
                existingModels: models
            )
            guard !selectedModels.isEmpty else {
                break
            }
            models.append(contentsOf: selectedModels)
        }

        return models
    }

    static func promptModelIndexes(
        modelCount: Int
    ) throws -> Set<Int> {
        let value = try promptString(
            "Models to delete (number, list like 1,3, all, or none)",
            defaultValue: "none",
            allowEmpty: false
        )
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["none", "no", "n", "skip"].contains(normalizedValue) {
            return []
        }
        if normalizedValue == "all" {
            return Set(0..<modelCount)
        }

        let tokens = normalizedValue
            .split { $0 == "," || $0 == " " || $0 == ";" }
            .map(String.init)
        guard !tokens.isEmpty else {
            throw MLXCoderSetupError.invalidChoice(value)
        }

        var selectedIndexes = Set<Int>()
        for token in tokens {
            guard let index = Int(token),
                  (1...modelCount).contains(index) else {
                throw MLXCoderSetupError.invalidChoice(value)
            }
            selectedIndexes.insert(index - 1)
        }
        return selectedIndexes
    }

    static func readAdditionalModelsFromCatalog(
        providerID: UUID,
        providerName: String,
        baseURL: String,
        chatEndpoint: AgentRemoteChatEndpoint,
        apiKey: String?,
        existingModels: [AgentSettingsModelManifest]
    ) async throws -> [AgentSettingsModelManifest] {
        let existingModelIDs = Set(
            existingModels.map { normalizedRemoteModelID($0.modelID) }
        )
        let catalogModels: [OpenRouterModelInfo]
        do {
            catalogModels = try await RemoteModelCatalogClient()
                .fetchModels(baseURL: baseURL, apiKey: apiKey)
                .sorted(by: remoteModelSort)
                .filter { model in
                    !existingModelIDs.contains(normalizedRemoteModelID(model.id))
                }
        } catch {
            AgentOutput.standardError.writeString(
                "Unable to load /models: \(error.localizedDescription)\n"
            )
            throw error
        }
        guard !catalogModels.isEmpty else {
            AgentOutput.standardError.writeString(
                "No additional models available from /models for \(providerName).\n"
            )
            return []
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
    }

    static func normalizedRemoteModelID(_ modelID: String) -> String {
        AgentRemoteProvider.normalizedModelID(modelID).lowercased()
    }

    static func modelWithProvider(
        _ model: AgentSettingsModelManifest,
        providerID: UUID,
        providerName: String,
        baseURL: String,
        chatEndpoint: AgentRemoteChatEndpoint
    ) -> AgentSettingsModelManifest {
        AgentSettingsModelManifest(
            id: model.id,
            kind: model.kind,
            title: model.title,
            llmID: model.llmID,
            modelID: model.modelID,
            providerID: providerID,
            provider: AgentRemoteProvider(
                id: providerID,
                name: providerName,
                baseURL: baseURL,
                modelID: model.modelID,
                chatEndpoint: chatEndpoint
            ),
            configuredContextWindowLimit: model.configuredContextWindowLimit,
            generationParameterOverrides: model.generationParameterOverrides,
            thinkingOptions: model.thinkingOptions,
            defaultThinkingSelection: model.defaultThinkingSelection
        )
    }

    static func isChatGPTSubscriptionProvider(
        _ provider: AgentSettingsProviderManifest
    ) -> Bool {
        provider.id == AgentRemoteProvider.chatGPTSubscriptionProviderID
            || provider.baseURL == AgentRemoteProvider.chatGPTSubscriptionBaseURL
    }

    static func isAnthropicSubscriptionProvider(
        _ provider: AgentSettingsProviderManifest
    ) -> Bool {
        provider.id == AgentRemoteProvider.anthropicSubscriptionProviderID
            || provider.baseURL == AgentRemoteProvider.anthropicSubscriptionBaseURL
    }

    static func ensureChatGPTSubscriptionCredentials() async throws {
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

    static func ensureAnthropicSubscriptionCredentials() async throws {
#if os(macOS)
        do {
            _ = try await AnthropicSubscriptionAuthService.loadValidCredentials()
            return
        } catch {
            AgentOutput.standardError.writeString(
                "Claude Subscription is not connected. Opening Claude login in the browser.\n"
            )
        }

        let session = try await AnthropicSubscriptionAuthService.startSignIn()
        let didOpen = await AnthropicSubscriptionAuthService.openAuthorizationURL(
            session.authorizationURL
        )
        guard didOpen else {
            throw AnthropicSubscriptionAuthError.browserOpenFailed
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
        AgentOutput.standardError.writeString("Claude Subscription connected.\n")
#else
        throw MLXCoderSetupError.anthropicSubscriptionUnsupported
#endif
    }

    static func readModels(
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

    static func selectRemoteModels(
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

    static func selectChatGPTSubscriptionModels(
        defaultModels: [AgentSettingsModelManifest] = []
    ) throws -> [CodexAgentModel.ModelOption] {
        let models = CodexAgentModel.availableModels
        AgentOutput.standardError.writeString("\nChatGPT Subscription models:\n")
        for (index, model) in models.enumerated() {
            let context = model.contextWindowTokenLimit.map { "ctx \($0)" } ?? "ctx default"
            AgentOutput.standardError.writeString(
                "  \(index + 1). \(model.title) (\(model.modelID)) [\(context), thinking]\n"
            )
        }

        let defaultSelection = chatGPTSubscriptionModelSelectionDefault(
            models: models,
            defaultModels: defaultModels
        )
        let value = try promptString(
            "Model selection (number, list like 1,3, or all)",
            defaultValue: defaultSelection,
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

    static func chatGPTSubscriptionModelSelectionDefault(
        models: [CodexAgentModel.ModelOption],
        defaultModels: [AgentSettingsModelManifest]
    ) -> String {
        guard !defaultModels.isEmpty else {
            return "1"
        }
        let selectedIndexes = defaultModels.compactMap { defaultModel in
            models.firstIndex { option in
                option.modelID == defaultModel.modelID
                    || CodexAgentModel.selectionID(forModelID: option.modelID) == defaultModel.id
            }.map { $0 + 1 }
        }
        guard !selectedIndexes.isEmpty else {
            return "1"
        }
        if selectedIndexes.count == models.count {
            return "all"
        }
        return selectedIndexes.map(String.init).joined(separator: ",")
    }

    static func selectAnthropicSubscriptionModels(
        defaultModels: [AgentSettingsModelManifest] = []
    ) throws -> [AnthropicSubscriptionModel.ModelOption] {
        let models = AnthropicSubscriptionModel.availableModels
        AgentOutput.standardError.writeString("\nClaude Subscription models:\n")
        for (index, model) in models.enumerated() {
            let context = model.contextWindowTokenLimit.map { "ctx \($0)" } ?? "ctx default"
            let thinking = model.thinkingSupport?.supportsThinking == true ? ", thinking" : ""
            AgentOutput.standardError.writeString(
                "  \(index + 1). \(model.title) (\(model.modelID)) [\(context)\(thinking)]\n"
            )
        }

        let defaultSelection = anthropicSubscriptionModelSelectionDefault(
            models: models,
            defaultModels: defaultModels
        )
        let value = try promptString(
            "Model selection (number, list like 1,3, or all)",
            defaultValue: defaultSelection,
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

        var selected: [AnthropicSubscriptionModel.ModelOption] = []
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

    static func anthropicSubscriptionModelSelectionDefault(
        models: [AnthropicSubscriptionModel.ModelOption],
        defaultModels: [AgentSettingsModelManifest]
    ) -> String {
        guard !defaultModels.isEmpty else {
            return "1"
        }
        let selectedIndexes = defaultModels.compactMap { defaultModel in
            models.firstIndex { option in
                option.modelID == defaultModel.modelID
                    || AnthropicSubscriptionModel.selectionID(forModelID: option.modelID) == defaultModel.id
            }.map { $0 + 1 }
        }
        guard !selectedIndexes.isEmpty else {
            return "1"
        }
        if selectedIndexes.count == models.count {
            return "all"
        }
        return selectedIndexes.map(String.init).joined(separator: ",")
    }

    static func remoteModelManifest(
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

    static func chatGPTSubscriptionModelManifest(
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

    static func anthropicSubscriptionModelManifest(
        option: AnthropicSubscriptionModel.ModelOption,
        providerID: UUID,
        providerName: String,
        baseURL: String,
        chatEndpoint: AgentRemoteChatEndpoint
    ) -> AgentSettingsModelManifest {
        let manifestID = AnthropicSubscriptionModel.selectionID(forModelID: option.modelID)
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
            thinkingSupport: option.thinkingSupport
        )
    }

    static func remoteModelListTitle(
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

    static func remoteModelStatus(
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

    static func remoteModelSort(
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

    static func remoteModelRank(
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

    static func readModel(
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
            title: nil,
            llmID: manifestID,
            modelID: modelID,
            providerID: providerID,
            provider: provider,
            configuredContextWindowLimit: nil,
            generationParameterOverrides: nil,
            thinkingOptions: nil,
            defaultThinkingSelection: nil
        )
    }

    static func promptEndpoint(
        defaultValue: AgentRemoteChatEndpoint = .chatCompletions
    ) throws -> AgentRemoteChatEndpoint {
        AgentOutput.standardError.writeString(
            """
            Endpoint:
              1. chat/completions
              2. responses
            """ + "\n"
        )
        let defaultChoice: String
        switch defaultValue {
        case .chatCompletions:
            defaultChoice = "1"
        case .responses:
            defaultChoice = "2"
        }
        let value = try promptString("Choice", defaultValue: defaultChoice, allowEmpty: false)
        switch value.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1", "chat", "chat_completions", "chat/completions":
            return .chatCompletions
        case "2", "responses":
            return .responses
        default:
            throw MLXCoderSetupError.invalidChoice(value)
        }
    }

    static func promptProviderKind() throws -> SetupProviderKind {
        AgentOutput.standardError.writeString(
            """
            Provider:
              1. OpenAI-compatible / MLX server
              2. ChatGPT Subscription
              3. Claude Subscription
            """ + "\n"
        )
        let value = try promptString("Choice", defaultValue: "1", allowEmpty: false)
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "remote", "remoteapi", "openai", "mlx", "server":
            return .remoteAPI
        case "2", "chatgpt", "subscription", "chatgpt subscription", "codex":
            return .chatGPTSubscription
        case "3", "claude", "anthropic", "claude subscription", "anthropic subscription":
            return .anthropicSubscription
        default:
            throw MLXCoderSetupError.invalidChoice(value)
        }
    }

}
