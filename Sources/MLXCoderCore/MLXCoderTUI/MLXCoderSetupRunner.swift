//
//  MLXCoderSetupRunner.swift
//  mlx-coder
//
//  Created by Codex on 23/05/26.
//

import Foundation

public enum MLXCoderSetupRunner {
    public static let option = "--setup"

    public static func shouldRunSetup(arguments: [String]) -> Bool {
        arguments.dropFirst().contains(option)
    }

    public static func argumentsAfterRemovingSetup(arguments: [String]) -> [String] {
        arguments.filter { $0 != option }
    }

    public static func run(arguments: [String]) throws {
        _ = arguments
        guard TerminalRawInput.supportsInteractiveInput() else {
            throw MLXCoderSetupError.nonInteractiveTerminal
        }

        AgentOutput.standardError.writeString(
            """
            mlx-coder setup
            Configuro i file di supporto in:
            \(MLXCoderSupportFileService.supportDirectoryURL().path)

            """
        )

        let settingsURL = AgentSettingsManifestStore.settingsURL()
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            do {
                _ = try AgentSettingsManifestStore.loadRequired(from: settingsURL)
                let shouldReconfigure = try promptYesNo(
                    "settings.json esiste gia. Vuoi riconfigurare providers e modelli?",
                    defaultValue: false
                )
                if !shouldReconfigure {
                    let result = try MLXCoderSupportFileService.ensureBaseFiles()
                    printResult(result, settingsWasWritten: false)
                    AgentOutput.standardError.writeString("\nSetup completato. Avvio mlx-coder.\n\n")
                    return
                }
            } catch {
                let shouldOverwrite = try promptYesNo(
                    "settings.json esiste ma non e valido. Vuoi riscriverlo?",
                    defaultValue: true
                )
                guard shouldOverwrite else {
                    throw error
                }
            }
        }

        let manifest = try buildSettingsManifest()
        let result = try MLXCoderSupportFileService.ensureRequiredFiles(
            settingsManifest: manifest,
            overwriteSettings: true
        )
        printResult(result, settingsWasWritten: true)
        AgentOutput.standardError.writeString("\nSetup completato. Avvio mlx-coder.\n\n")
    }

    private static func buildSettingsManifest() throws -> AgentSettingsManifest {
        var providerInputs: [SetupProviderInput] = []
        repeat {
            providerInputs.append(try readProvider())
        } while try promptYesNo("Aggiungere un altro provider?", defaultValue: false)

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
        let apiKeysByProviderID = Dictionary(
            uniqueKeysWithValues: providerInputs.compactMap { input in
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

    private static func readProvider() throws -> SetupProviderInput {
        AgentOutput.standardError.writeString("\nProvider remoto\n")
        let id = UUID()
        let name = try promptString(
            "Nome provider",
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
            "API key (opzionale)",
            defaultValue: nil,
            allowEmpty: true
        )

        var models: [AgentSettingsModelManifest] = []
        repeat {
            models.append(
                try readModel(
                    providerID: id,
                    providerName: name,
                    baseURL: baseURL,
                    chatEndpoint: chatEndpoint,
                    modelIndex: models.count
                )
            )
        } while try promptYesNo("Aggiungere un altro modello per \(name)?", defaultValue: false)

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

    private static func readModel(
        providerID: UUID,
        providerName: String,
        baseURL: String,
        chatEndpoint: AgentRemoteChatEndpoint,
        modelIndex: Int
    ) throws -> AgentSettingsModelManifest {
        AgentOutput.standardError.writeString("\nModello\n")
        let defaultModelID = modelIndex == 0 ? AgentRemoteProvider.defaultOpenRouterModelID : nil
        let modelID = try promptString(
            "Model ID",
            defaultValue: defaultModelID,
            allowEmpty: false
        )
        let title = try promptString(
            "Titolo visualizzato (opzionale)",
            defaultValue: nil,
            allowEmpty: true
        )
        let contextLimit = try promptPositiveInt(
            "Context window token limit (opzionale)",
            defaultValue: nil
        )
        let maxTokens = try promptPositiveInt(
            "Max output tokens per richiesta (opzionale)",
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
            """
        )
        let value = try promptString("Scelta", defaultValue: "1", allowEmpty: false)
        switch value.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1", "chat", "chat_completions", "chat/completions":
            return .chatCompletions
        case "2", "responses":
            return .responses
        default:
            throw MLXCoderSetupError.invalidChoice(value)
        }
    }

    private static func promptThinking() throws -> SetupThinkingInput {
        guard try promptYesNo("Il modello supporta thinking/reasoning?", defaultValue: false) else {
            return SetupThinkingInput(options: nil, defaultSelection: nil)
        }

        AgentOutput.standardError.writeString(
            """
            Tipo thinking:
              1. on/off
              2. effort levels (minimal, low, medium, high, xhigh)
            """
        )
        let value = try promptString("Scelta", defaultValue: "2", allowEmpty: false)
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
        AgentOutput.standardError.writeString("\nModello di default:\n")
        for (index, model) in models.enumerated() {
            AgentOutput.standardError.writeString("  \(index + 1). \(model.displayTitle)\n")
        }
        let value = try promptString("Scelta", defaultValue: "1", allowEmpty: false)
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
        case "y", "yes", "s", "si":
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
                "Creati: \(result.createdFilenames.joined(separator: ", "))\n"
            )
        }
        if !result.preservedFilenames.isEmpty {
            AgentOutput.standardError.writeString(
                "Conservati: \(result.preservedFilenames.joined(separator: ", "))\n"
            )
        }
        if settingsWasWritten && !result.createdFilenames.contains(AgentSettingsManifestStore.settingsFilename) {
            AgentOutput.standardError.writeString("Aggiornato: settings.json\n")
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

private enum MLXCoderSetupError: LocalizedError {
    case nonInteractiveTerminal
    case cancelled
    case emptyRequiredValue(String)
    case invalidChoice(String)
    case noModelsConfigured

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
        }
    }
}
