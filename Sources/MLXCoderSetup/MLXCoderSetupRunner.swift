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
    private static let interactiveLineReader = TerminalInteractiveLineReader()

    public static func shouldRunSetup(arguments: [String]) -> Bool {
        arguments.dropFirst().contains(option)
    }

    public static func argumentsAfterRemovingSetup(arguments: [String]) -> [String] {
        arguments.filter { $0 != option }
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
        var existingManifest: AgentSettingsManifest?
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            do {
                existingManifest = try AgentSettingsManifestStore.loadRequired(from: settingsURL)
                let shouldReconfigure = try promptYesNo(
                    "settings.json already exists. Reconfigure providers and models?",
                    defaultValue: false
                )
                if !shouldReconfigure {
                    guard existingManifest != nil else {
                        throw MLXCoderSetupError.noModelsConfigured
                    }
                    let existingManifest = try requireExistingManifest(existingManifest)
                    let manifest = try await configureOptionalIntegrations(in: existingManifest)
                    let shouldWriteSettings = manifest != existingManifest
                    let result = try MLXCoderSupportFileService.ensureRequiredFiles(
                        settingsManifest: manifest,
                        overwriteSettings: shouldWriteSettings
                    )
                    printResult(result, settingsWasWritten: shouldWriteSettings)
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

        let manifest = try await buildSettingsManifest(existingManifest: existingManifest)
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

    private static func buildSettingsManifest(
        existingManifest: AgentSettingsManifest? = nil
    ) async throws -> AgentSettingsManifest {
        var providerInputs = try await reconfigureExistingProviders(
            existingManifest
        )
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

        let selectedModelID: String
        if models.count == 1 {
            selectedModelID = models[0].id
        } else {
            selectedModelID = try selectDefaultModel(
                from: models,
                defaultModelID: existingManifest?.selectedModelID
            )
        }

        let selectedThinkingSelection = models
            .first { $0.matches(selectedModelID) }?
            .resolvedDefaultThinkingSelection
        let telegram = try await promptTelegramSettings(existingSettings: existingManifest?.telegram)
        let voice = try promptVoiceSettings(existingSettings: existingManifest?.voice)
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
            telegram: telegram,
            voice: voice,
            remoteAPIKeysByProviderID: apiKeysByProviderID
        )
    }

    private static func configureOptionalIntegrations(
        in manifest: AgentSettingsManifest
    ) async throws -> AgentSettingsManifest {
        let telegram = try await promptTelegramSettings(existingSettings: manifest.telegram)
        let voice = try promptVoiceSettings(existingSettings: manifest.voice)
        return AgentSettingsManifest(
            version: manifest.version,
            providers: manifest.providers,
            models: manifest.models,
            selectedModelID: manifest.selectedModelID,
            selectedThinkingSelection: manifest.selectedThinkingSelection,
            telegram: telegram,
            voice: voice,
            remoteAPIKeysByProviderID: manifest.remoteAPIKeysByProviderID
        )
    }

    private static func requireExistingManifest(
        _ manifest: AgentSettingsManifest?
    ) throws -> AgentSettingsManifest {
        guard let manifest else {
            throw MLXCoderSetupError.noModelsConfigured
        }
        return manifest
    }

    private static func promptTelegramSettings(
        existingSettings: AgentTelegramSettingsManifest?
    ) async throws -> AgentTelegramSettingsManifest? {
        let shouldEnableTelegram = try promptYesNo(
            "Enable Telegram remote control?",
            defaultValue: existingSettings?.isConfigured == true
        )
        guard shouldEnableTelegram else {
            return nil
        }

        let existingToken = existingSettings?.botToken?.nilIfBlank
        if existingSettings?.isEnabled == true {
            let shouldReplacePairing = try promptYesNo(
                "Replace stored Telegram bot token and pairing?",
                defaultValue: false
            )
            if !shouldReplacePairing {
                return existingSettings
            }
        }

        let token: String
        if let existingToken,
           try promptYesNo("Use stored Telegram bot token for pairing?", defaultValue: true) {
            token = existingToken
        } else {
            printTelegramBotTokenGuide()
            token = try promptString(
                "Telegram bot token",
                defaultValue: nil,
                allowEmpty: false
            )
        }

        return try await pairTelegram(botToken: token)
    }

    private static func printTelegramBotTokenGuide() {
        AgentOutput.standardError.writeString(
            """
            \nTelegram bot setup:
              1. Open Telegram and start a chat with @BotFather.
              2. Send /newbot and follow the prompts for bot name and username.
              3. Copy the bot token returned by BotFather and paste it below.
              4. Setup will then show a pairing code to send to your bot.
              Keep the token private; it gives access to your bot.

            """
        )
    }

    private static func pairTelegram(
        botToken: String
    ) async throws -> AgentTelegramSettingsManifest {
        let pairingCode = newTelegramPairingCode()
        let pairingService = TerminalTelegramPairingService(botToken: botToken)
        let bot = try await pairingService.prepare()
        let botLabel = bot.username.map { "@\($0)" } ?? "your Telegram bot"

        AgentOutput.standardError.writeString(
            """
            Telegram pairing:
              Send this code to \(botLabel): \(pairingCode)
              You can send the code alone or /start \(pairingCode).
              Waiting for Telegram...

            """
        )

        let linkedChat = try await pairingService.waitForPairing(code: pairingCode)
        let title = linkedChat.chatTitle?.nilIfBlank ?? "chat \(linkedChat.chatID)"
        AgentOutput.standardError.writeString("Telegram linked: \(title)\n")
        return AgentTelegramSettingsManifest(
            enabled: true,
            botToken: botToken,
            linkedChatID: linkedChat.chatID,
            linkedChatTitle: linkedChat.chatTitle
        )
    }

    private static func newTelegramPairingCode() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).uppercased()
    }

    private static func promptVoiceSettings(
        existingSettings: AgentVoiceSettingsManifest?
    ) throws -> AgentVoiceSettingsManifest? {
        let shouldEnableVoice = try promptYesNo(
            "Enable local voice tools?",
            defaultValue: existingSettings?.isConfigured == true
        )
        guard shouldEnableVoice else {
            return nil
        }

        #if os(macOS)
        print(
            """

            Voice uses a local Swift executable, mlx-voice-transcriber.
            It provides speech-to-text with WhisperKit and text-to-speech with macOS voices.
            No external API key is required.

            """
        )
        #else
        print(
            """

            Voice uses a local Swift executable, mlx-voice-transcriber.
            Audio generation is available only on macOS and will not be enabled on this platform.
            No external API key is required.

            """
        )
        #endif

        let executablePath = try resolvedVoiceExecutableURL(existingSettings: existingSettings).path
        AgentOutput.standardError.writeString("Voice executable: \(executablePath)\n")

        let modelID = try selectVoiceSetupOption(
            title: "Voice transcription model",
            options: voiceTranscriptionModelOptions,
            defaultValue: existingSettings?.modelID.nilIfBlank
                ?? AgentVoiceSettingsManifest.defaultModelID
        )
        let language = try selectVoiceSetupOption(
            title: "Voice language",
            options: voiceLanguageOptions,
            defaultValue: existingSettings?.language?.nilIfBlank
                ?? AgentVoiceSettingsManifest.defaultLanguage
        )
        #if os(macOS)
        let speaker: String? = try selectVoiceSetupOption(
            title: "macOS synthesis voice",
            options: voiceSpeakerOptions,
            defaultValue: existingSettings?.speaker?.nilIfBlank
                ?? AgentVoiceSettingsManifest.defaultSpeaker
        )
        #else
        let speaker: String? = nil
        #endif

        return AgentVoiceSettingsManifest(
            enabled: true,
            modelID: modelID,
            executablePath: executablePath,
            language: language,
            speaker: speaker
        )
    }

    private static let voiceTranscriptionModelOptions: [VoiceSetupOption] = [
        VoiceSetupOption(
            value: "tiny",
            title: "Whisper tiny",
            detail: "fastest startup and short prompts"
        ),
        VoiceSetupOption(
            value: "large-v3-v20240930_626MB",
            title: "Whisper large-v3",
            detail: "best multilingual accuracy, slower first run"
        )
    ]

    private static let voiceLanguageOptions: [VoiceSetupOption] = [
        VoiceSetupOption(value: "it", title: "Italiano", aliases: ["italian"]),
        VoiceSetupOption(value: "en", title: "English", aliases: ["english"]),
        VoiceSetupOption(value: "es", title: "Spanish", aliases: ["spanish"]),
        VoiceSetupOption(value: "fr", title: "French", aliases: ["french"]),
        VoiceSetupOption(value: "de", title: "Deutsch", aliases: ["german"]),
        VoiceSetupOption(value: "pt", title: "Portuguese", aliases: ["portuguese"]),
        VoiceSetupOption(value: "ja", title: "Japanese", aliases: ["japanese"]),
        VoiceSetupOption(value: "ko", title: "Korean", aliases: ["korean"]),
        VoiceSetupOption(value: "zh", title: "Chinese", aliases: ["chinese"]),
        VoiceSetupOption(value: "ru", title: "Russian", aliases: ["russian"])
    ]

    private static let voiceSpeakerOptions: [VoiceSetupOption] = [
        VoiceSetupOption(value: "Alice", title: "Alice", detail: "Italiano"),
        VoiceSetupOption(value: "Samantha", title: "Samantha", detail: "English US"),
        VoiceSetupOption(value: "Daniel", title: "Daniel", detail: "English UK"),
        VoiceSetupOption(value: "Paulina", title: "Paulina", detail: "Spanish"),
        VoiceSetupOption(value: "Thomas", title: "Thomas", detail: "French"),
        VoiceSetupOption(value: "Anna", title: "Anna", detail: "German"),
        VoiceSetupOption(value: "Joana", title: "Joana", detail: "Portuguese"),
        VoiceSetupOption(value: "Kyoko", title: "Kyoko", detail: "Japanese"),
        VoiceSetupOption(value: "Yuna", title: "Yuna", detail: "Korean"),
        VoiceSetupOption(value: "Tingting", title: "Tingting", detail: "Chinese"),
        VoiceSetupOption(value: "Milena", title: "Milena", detail: "Russian")
    ]

    private static func selectVoiceSetupOption(
        title: String,
        options: [VoiceSetupOption],
        defaultValue: String
    ) throws -> String {
        AgentOutput.standardError.writeString("\n\(title):\n")
        let defaultIndex = options.firstIndex { $0.matches(defaultValue) } ?? 0
        for (index, option) in options.enumerated() {
            let marker = index == defaultIndex ? " *" : ""
            let detail = option.detail.map { " - \($0)" } ?? ""
            AgentOutput.standardError.writeString(
                "  \(index + 1). \(option.title) [\(option.value)]\(detail)\(marker)\n"
            )
        }

        let value = try promptString(
            "Choice",
            defaultValue: String(defaultIndex + 1),
            allowEmpty: false
        )
        if let index = Int(value),
           options.indices.contains(index - 1) {
            return options[index - 1].value
        }
        if let option = options.first(where: { $0.matches(value) }) {
            return option.value
        }
        throw MLXCoderSetupError.invalidChoice(value)
    }

    private static func resolvedVoiceExecutableURL(
        existingSettings: AgentVoiceSettingsManifest?
    ) throws -> URL {
        if let installedURL = installedVoiceExecutableURL(existingSettings: existingSettings) {
            return installedURL
        }
        if let packageRoot = detectedPackageRootURL() {
            return try buildLocalVoiceExecutable(packageRoot: packageRoot)
        }
        throw MLXCoderSetupError.voiceToolExecutableNotFound
    }

    private static func installedVoiceExecutableURL(
        existingSettings: AgentVoiceSettingsManifest?
    ) -> URL? {
        for url in installedVoiceExecutableCandidates(existingSettings: existingSettings) {
            if isExecutableFile(url) {
                return url
            }
        }
        return nil
    }

    private static func installedVoiceExecutableCandidates(
        existingSettings: AgentVoiceSettingsManifest?
    ) -> [URL] {
        var candidates: [URL] = []
        if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(
                executableDirectory.appendingPathComponent(
                    AgentVoiceSettingsManifest.defaultExecutablePath
                )
            )
        }
        if let pathURL = executableURLFromPATH(named: AgentVoiceSettingsManifest.defaultExecutablePath) {
            candidates.append(pathURL)
        }
        if let existingPath = existingSettings?.executablePath.nilIfBlank,
           existingPath.contains("/") {
            candidates.append(URL(fileURLWithPath: existingPath))
        }
        return uniqueURLs(candidates)
    }

    private static func buildLocalVoiceExecutable(packageRoot: URL) throws -> URL {
        let voicePackageURL = packageRoot.appendingPathComponent(
            "Tools/MLXVoiceTranscriber",
            isDirectory: true
        )
        let executableURL = voicePackageURL
            .appendingPathComponent(".build/release")
            .appendingPathComponent(AgentVoiceSettingsManifest.defaultExecutablePath)

        AgentOutput.standardError.writeString(
            """
            Building local voice executable...
              cd \(voicePackageURL.path)
              swift build -c release

            """
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "build", "-c", "release"]
        process.currentDirectoryURL = voicePackageURL
        process.standardOutput = FileHandle.standardError
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw MLXCoderSetupError.voiceToolBuildFailed(process.terminationStatus)
        }
        guard isExecutableFile(executableURL) else {
            throw MLXCoderSetupError.voiceToolExecutableMissing(executableURL.path)
        }
        return executableURL
    }

    private static func detectedPackageRootURL() -> URL? {
        var candidates: [URL] = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        ]
        if let executableURL = Bundle.main.executableURL {
            candidates.append(executableURL.deletingLastPathComponent())
        }

        for candidate in candidates {
            var current = candidate.standardizedFileURL
            while current.path != "/" {
                let packageManifest = current.appendingPathComponent("Package.swift")
                let voicePackage = current.appendingPathComponent("Tools/MLXVoiceTranscriber/Package.swift")
                if FileManager.default.fileExists(atPath: packageManifest.path),
                   FileManager.default.fileExists(atPath: voicePackage.path) {
                    return current
                }
                current.deleteLastPathComponent()
            }
        }
        return nil
    }

    private static func executableURLFromPATH(named executableName: String) -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":").map(String.init) {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(executableName)
            if isExecutableFile(url) {
                return url
            }
        }
        return nil
    }

    private static func isExecutableFile(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            seen.insert(url.standardizedFileURL.path).inserted
        }
    }

    private static func reconfigureExistingProviders(
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

    private static func printProviders(
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

    private static func promptProviderIndexes(
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

    private static func models(
        for provider: AgentSettingsProviderManifest,
        in models: [AgentSettingsModelManifest]
    ) -> [AgentSettingsModelManifest] {
        models.filter { model in
            (model.providerID ?? model.provider?.id) == provider.id
        }
    }

    private static func preserveProviderInput(
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

    private static func readProvider() async throws -> SetupProviderInput {
        switch try promptProviderKind() {
        case .remoteAPI:
            return try await readRemoteAPIProvider()
        case .chatGPTSubscription:
            return try await readChatGPTSubscriptionProvider()
        }
    }

    private static func readRemoteAPIProvider(
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

    private static func readChatGPTSubscriptionProvider(
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

    private static func promptAPIKey(
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

    private static func reconfigureModels(
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

    private static func promptModelIndexes(
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

    private static func readAdditionalModelsFromCatalog(
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

    private static func normalizedRemoteModelID(_ modelID: String) -> String {
        AgentRemoteProvider.normalizedModelID(modelID).lowercased()
    }

    private static func modelWithProvider(
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

    private static func isChatGPTSubscriptionProvider(
        _ provider: AgentSettingsProviderManifest
    ) -> Bool {
        provider.id == AgentRemoteProvider.chatGPTSubscriptionProviderID
            || provider.baseURL == AgentRemoteProvider.chatGPTSubscriptionBaseURL
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

    private static func selectChatGPTSubscriptionModels(
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

    private static func chatGPTSubscriptionModelSelectionDefault(
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

    private static func promptEndpoint(
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

    private static func selectDefaultModel(
        from models: [AgentSettingsModelManifest],
        defaultModelID: String? = nil
    ) throws -> String {
        AgentOutput.standardError.writeString("\nDefault model:\n")
        let defaultIndex = defaultModelID
            .flatMap { selectedID in models.firstIndex { $0.matches(selectedID) } }
            ?? 0
        for (index, model) in models.enumerated() {
            let marker = index == defaultIndex ? " *" : ""
            AgentOutput.standardError.writeString("  \(index + 1). \(model.displayTitle)\(marker)\n")
        }
        let value = try promptString(
            "Choice",
            defaultValue: String(defaultIndex + 1),
            allowEmpty: false
        )
        if let index = Int(value),
           models.indices.contains(index - 1) {
            return models[index - 1].id
        }
        if let model = models.first(where: { $0.matches(value) }) {
            return model.id
        }
        throw MLXCoderSetupError.invalidChoice(value)
    }

    private static func promptString(
        _ label: String,
        defaultValue: String?,
        allowEmpty: Bool
    ) throws -> String {
        let suffix = defaultValue.map { " [\($0)]" } ?? ""
        guard let rawValue = interactiveLineReader.readLine(prompt: "\(label)\(suffix): ") else {
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

private struct VoiceSetupOption {
    let value: String
    let title: String
    let detail: String?
    let aliases: [String]

    init(
        value: String,
        title: String,
        detail: String? = nil,
        aliases: [String] = []
    ) {
        self.value = value
        self.title = title
        self.detail = detail
        self.aliases = aliases
    }

    func matches(_ rawValue: String?) -> Bool {
        guard let value = rawValue?.nilIfBlank?.lowercased() else {
            return false
        }
        return self.value.lowercased() == value
            || title.lowercased() == value
            || aliases.contains { $0.lowercased() == value }
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
    case voiceToolExecutableNotFound
    case voiceToolBuildFailed(Int32)
    case voiceToolExecutableMissing(String)

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
        case .voiceToolExecutableNotFound:
            return "Local voice executable was not found. Install or update mlx-coder so mlx-voice-transcriber is available next to mlx-coder or in PATH."
        case let .voiceToolBuildFailed(exitCode):
            return "Local voice tool build failed with exit code \(exitCode)."
        case let .voiceToolExecutableMissing(path):
            return "Local voice tool build completed, but the executable was not found: \(path)"
        }
    }
}
