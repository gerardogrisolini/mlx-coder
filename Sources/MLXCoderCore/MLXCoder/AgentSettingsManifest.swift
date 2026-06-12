//
//  AgentSettingsManifest.swift
//  MLXCoder
//
//  Created by Codex on 03/05/26.
//

import Foundation
import os

public struct AgentSettingsManifest: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case version
        case providers
        case models
        case selected
        case telegram
        case voice
        case remoteAPIKeysByProviderID
        case localExecAllowedCommands

    }

    public static let currentVersion = 9
    public static let minimumSupportedVersion = 4

    public let version: Int
    public let providers: [AgentSettingsProviderManifest]
    public let models: [AgentSettingsModelManifest]
    public let selectedModelID: String?
    public let selectedThinkingSelection: AgentThinkingSelection?
    public let telegram: AgentTelegramSettingsManifest?
    public let voice: AgentVoiceSettingsManifest?
    public let remoteAPIKeysByProviderID: [String: String]
    public let localExecAllowedCommands: [String]


    public init(
        version: Int = Self.currentVersion,
        providers: [AgentSettingsProviderManifest] = [],
        models: [AgentSettingsModelManifest],
        selectedModelID: String? = nil,
        selectedThinkingSelection: AgentThinkingSelection? = nil,
        telegram: AgentTelegramSettingsManifest? = nil,
        voice: AgentVoiceSettingsManifest? = nil,
        remoteAPIKeysByProviderID: [String: String] = [:],
        localExecAllowedCommands: [String] = []
    ) {
        let normalizedProviders = Self.normalizedProviders(
            providers,
            models: models
        )
        let providersByID = Dictionary(uniqueKeysWithValues: normalizedProviders.map { ($0.id, $0) })
        let normalizedModels = Self.normalizedModels(models, providersByID: providersByID)

        self.version = version
        self.providers = normalizedProviders
        self.models = normalizedModels
        self.selectedModelID = Self.normalizedSelectedModelID(
            selectedModelID,
            models: normalizedModels
        )
        self.selectedThinkingSelection = Self.normalizedSelectedThinkingSelection(
            selectedThinkingSelection,
            selectedModelID: self.selectedModelID,
            models: normalizedModels
        )
        self.telegram = telegram?.isConfigured == true ? telegram : nil
        self.voice = voice?.isConfigured == true ? voice : nil
        self.remoteAPIKeysByProviderID = Self.normalizedRemoteAPIKeys(
            remoteAPIKeysByProviderID,
            models: normalizedModels
        )
        self.localExecAllowedCommands = Self.normalizedLocalExecAllowedCommands(
            localExecAllowedCommands
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        let selected = try container.decodeIfPresent(
            AgentSettingsSelectionManifest.self,
            forKey: .selected
        )
        let models = try container.decode([AgentSettingsModelManifest].self, forKey: .models)
        self.init(
            version: version,
            providers: try container.decodeIfPresent(
                [AgentSettingsProviderManifest].self,
                forKey: .providers
            ) ?? [],
            models: models,
            selectedModelID: selected?.modelID,
            selectedThinkingSelection: selected?.thinking,
            telegram: try container.decodeIfPresent(
                AgentTelegramSettingsManifest.self,
                forKey: .telegram
            ),
            voice: try container.decodeIfPresent(
                AgentVoiceSettingsManifest.self,
                forKey: .voice
            ),
            remoteAPIKeysByProviderID: try container.decodeIfPresent(
                [String: String].self,
                forKey: .remoteAPIKeysByProviderID
            ) ?? [:],
            localExecAllowedCommands: try container.decodeIfPresent(
                [String].self,
                forKey: .localExecAllowedCommands
            ) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        if !providers.isEmpty {
            try container.encode(providers, forKey: .providers)
        }
        try container.encode(models, forKey: .models)
        let selection = AgentSettingsSelectionManifest(
            modelID: selectedModelID,
            thinking: selectedThinkingSelection
        )
        if !selection.isEmpty {
            try container.encode(selection, forKey: .selected)
        }
        if let telegram, telegram.isConfigured {
            try container.encode(telegram, forKey: .telegram)
        }
        if let voice, voice.isConfigured {
            try container.encode(voice, forKey: .voice)
        }
        if !remoteAPIKeysByProviderID.isEmpty {
            try container.encode(remoteAPIKeysByProviderID, forKey: .remoteAPIKeysByProviderID)
        }
    }

    public var isEmpty: Bool {
        providers.isEmpty
            && models.isEmpty
            && selectedModelID == nil
            && selectedThinkingSelection == nil
            && telegram == nil
            && voice == nil
            && remoteAPIKeysByProviderID.isEmpty
    }

    private static func normalizedLocalExecAllowedCommands(_ commands: [String]) -> [String] {
        var seen = Set<String>()
        return commands.compactMap { command in
            let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                return nil
            }
            let key = normalized.lowercased()
            guard seen.insert(key).inserted else {
                return nil
            }
            return normalized
        }
    }

    private static func normalizedModels(
        _ models: [AgentSettingsModelManifest],
        providersByID: [UUID: AgentSettingsProviderManifest]
    ) -> [AgentSettingsModelManifest] {
        var seen = Set<String>()
        return models.compactMap { model in
            guard let normalizedModel = model.normalized(providersByID: providersByID),
                  seen.insert(normalizedModel.id.lowercased()).inserted else {
                return nil
            }
            return normalizedModel
        }
    }

    private static func normalizedProviders(
        _ providers: [AgentSettingsProviderManifest],
        models: [AgentSettingsModelManifest]
    ) -> [AgentSettingsProviderManifest] {
        var providersByID: [UUID: AgentSettingsProviderManifest] = [:]
        for model in models {
            if let provider = model.provider {
                providersByID[provider.id] = AgentSettingsProviderManifest(provider: provider)
            }
        }
        for provider in providers {
            providersByID[provider.id] = provider
        }
        return providersByID.values.sorted {
            let comparison = $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle)
            if comparison == .orderedSame {
                return $0.id.uuidString < $1.id.uuidString
            }
            return comparison == .orderedAscending
        }
    }

    private static func normalizedSelectedModelID(
        _ selectedModelID: String?,
        models: [AgentSettingsModelManifest]
    ) -> String? {
        guard let selectedModelID = selectedModelID?.nilIfBlank else {
            return nil
        }
        return models.first { $0.matches(selectedModelID) }?.id
    }

    private static func normalizedSelectedThinkingSelection(
        _ selectedThinkingSelection: AgentThinkingSelection?,
        selectedModelID: String?,
        models: [AgentSettingsModelManifest]
    ) -> AgentThinkingSelection? {
        guard let selectedModelID,
              let model = models.first(where: { $0.matches(selectedModelID) }) else {
            return nil
        }
        return model.thinkingSelection(for: selectedThinkingSelection)
    }

    private static func normalizedRemoteAPIKeys(
        _ values: [String: String],
        models: [AgentSettingsModelManifest]
    ) -> [String: String] {
        var normalized: [String: String] = [:]
        for model in models {
            guard let providerID = model.provider?.id ?? model.providerID,
                  let apiKey = model.apiKey?.nilIfBlank else {
                continue
            }
            normalized[providerID.uuidString.lowercased()] = apiKey
        }
        for (providerID, apiKey) in values {
            guard let providerUUID = UUID(uuidString: providerID),
                  let normalizedAPIKey = apiKey.nilIfBlank else {
                continue
            }
            normalized[providerUUID.uuidString.lowercased()] = normalizedAPIKey
        }
        return normalized
    }
}

public struct AgentTelegramSettingsManifest: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case enabled
        case botToken
        case linkedChatID
        case linkedChatTitle
    }

    public let enabled: Bool
    public let botToken: String?
    public let linkedChatID: Int64?
    public let linkedChatTitle: String?

    public init(
        enabled: Bool = false,
        botToken: String? = nil,
        linkedChatID: Int64? = nil,
        linkedChatTitle: String? = nil
    ) {
        let normalizedToken = botToken?.nilIfBlank
        let normalizedTitle = linkedChatTitle?.nilIfBlank
        let shouldStoreConfiguration = enabled && normalizedToken != nil
        self.enabled = shouldStoreConfiguration
        self.botToken = shouldStoreConfiguration ? normalizedToken : nil
        self.linkedChatID = shouldStoreConfiguration ? linkedChatID : nil
        self.linkedChatTitle = shouldStoreConfiguration ? normalizedTitle : nil
    }

    public var isConfigured: Bool {
        enabled && botToken?.nilIfBlank != nil
    }

    public var isEnabled: Bool {
        isConfigured && linkedChatID != nil
    }
}

public struct AgentVoiceSettingsManifest: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case enabled
        case language
        case speaker
    }

    public static let defaultLanguage = "it"
    public static let defaultSpeaker = "Alice"

    public let enabled: Bool
    public let language: String?
    public let speaker: String?

    public init(
        enabled: Bool = false,
        language: String? = Self.defaultLanguage,
        speaker: String? = Self.defaultSpeaker
    ) {
        let normalizedLanguage = language?.nilIfBlank
        let normalizedSpeaker = speaker?.nilIfBlank
        self.enabled = enabled
        self.language = enabled ? normalizedLanguage : nil
        self.speaker = enabled ? normalizedSpeaker : nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            language: try container.decodeIfPresent(String.self, forKey: .language),
            speaker: try container.decodeIfPresent(String.self, forKey: .speaker)
                ?? Self.defaultSpeaker
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        if let language {
            try container.encode(language, forKey: .language)
        }
        if let speaker {
            try container.encode(speaker, forKey: .speaker)
        }
    }

    public var isConfigured: Bool {
        enabled
    }
}

public struct AgentSettingsProviderManifest: Codable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case baseURL
        case chatEndpoint
    }

    public let id: UUID
    public let name: String
    public let baseURL: String
    public let chatEndpoint: AgentRemoteChatEndpoint

    public init(
        id: UUID,
        name: String,
        baseURL: String,
        chatEndpoint: AgentRemoteChatEndpoint
    ) {
        self.id = id
        self.name = AgentRemoteProvider.normalizedName(name)
        self.baseURL = AgentRemoteProvider.normalizedBaseURL(baseURL)
        self.chatEndpoint = chatEndpoint
    }

    public init(provider: AgentRemoteProvider) {
        self.init(
            id: provider.id,
            name: provider.name,
            baseURL: provider.baseURL,
            chatEndpoint: provider.chatEndpoint
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decodeIfPresent(String.self, forKey: .name)
                ?? AgentRemoteProvider.defaultOpenRouterName,
            baseURL: try container.decodeIfPresent(String.self, forKey: .baseURL)
                ?? AgentRemoteProvider.defaultOpenRouterBaseURL,
            chatEndpoint: try container.decodeIfPresent(
                AgentRemoteChatEndpoint.self,
                forKey: .chatEndpoint
            ) ?? .chatCompletions
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(chatEndpoint, forKey: .chatEndpoint)
    }

    public var displayTitle: String {
        AgentRemoteProvider.normalizedName(name)
    }

    public func remoteProvider(modelID: String) -> AgentRemoteProvider {
        AgentRemoteProvider(
            id: id,
            name: name,
            baseURL: baseURL,
            modelID: modelID,
            chatEndpoint: chatEndpoint
        )
    }
}

private struct AgentSettingsSelectionManifest: Codable, Hashable, Sendable {
    let modelID: String?
    let thinking: AgentThinkingSelection?

    init(
        modelID: String?,
        thinking: AgentThinkingSelection?
    ) {
        self.modelID = modelID?.nilIfBlank
        self.thinking = thinking
    }

    var isEmpty: Bool {
        modelID == nil && thinking == nil
    }
}

public struct AgentGenerationParameterOverrides: Codable, Equatable, Hashable, Sendable {
    public var maxTokens: Int?
    public var maxKVSize: Int?
    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    public var minP: Double?
    public var repetitionPenalty: Double?
    public var repetitionContextSize: Int?
    public var presencePenalty: Double?
    public var presenceContextSize: Int?
    public var frequencyPenalty: Double?
    public var frequencyContextSize: Int?
    public var prefillStepSize: Int?
    public var kvBits: Int?
    public var kvGroupSize: Int?
    public var quantizedKVStart: Int?

    public init(
        maxTokens: Int? = nil,
        maxKVSize: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        minP: Double? = nil,
        repetitionPenalty: Double? = nil,
        repetitionContextSize: Int? = nil,
        presencePenalty: Double? = nil,
        presenceContextSize: Int? = nil,
        frequencyPenalty: Double? = nil,
        frequencyContextSize: Int? = nil,
        prefillStepSize: Int? = nil,
        kvBits: Int? = nil,
        kvGroupSize: Int? = nil,
        quantizedKVStart: Int? = nil
    ) {
        self.maxTokens = maxTokens
        self.maxKVSize = maxKVSize
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.repetitionPenalty = repetitionPenalty
        self.repetitionContextSize = repetitionContextSize
        self.presencePenalty = presencePenalty
        self.presenceContextSize = presenceContextSize
        self.frequencyPenalty = frequencyPenalty
        self.frequencyContextSize = frequencyContextSize
        self.prefillStepSize = prefillStepSize
        self.kvBits = kvBits
        self.kvGroupSize = kvGroupSize
        self.quantizedKVStart = quantizedKVStart
    }

    public var isEmpty: Bool {
        maxTokens == nil
            && maxKVSize == nil
            && temperature == nil
            && topP == nil
            && topK == nil
            && minP == nil
            && repetitionPenalty == nil
            && repetitionContextSize == nil
            && presencePenalty == nil
            && presenceContextSize == nil
            && frequencyPenalty == nil
            && frequencyContextSize == nil
            && prefillStepSize == nil
            && kvBits == nil
            && kvGroupSize == nil
            && quantizedKVStart == nil
    }

    public var nilIfEmpty: AgentGenerationParameterOverrides? {
        isEmpty ? nil : self
    }

    public func normalized() -> Self {
        Self(
            maxTokens: maxTokens.map { min(max($0, 1), 1_048_576) },
            maxKVSize: maxKVSize.map { min(max($0, 1), 1_048_576) },
            temperature: temperature.map { min(max($0, 0), 2) },
            topP: topP.map { min(max($0, 0.01), 1) },
            topK: topK.map { min(max($0, 0), 10_000) },
            minP: minP.map { min(max($0, 0), 1) },
            repetitionPenalty: repetitionPenalty.map { min(max($0, 0), 3) },
            repetitionContextSize: repetitionContextSize.map { min(max($0, 0), 8192) },
            presencePenalty: presencePenalty.map { min(max($0, -2), 2) },
            presenceContextSize: presenceContextSize.map { min(max($0, 0), 8192) },
            frequencyPenalty: frequencyPenalty.map { min(max($0, -2), 2) },
            frequencyContextSize: frequencyContextSize.map { min(max($0, 0), 8192) },
            prefillStepSize: prefillStepSize.map { min(max($0, 1), 8192) },
            kvBits: kvBits.map { min(max($0, 2), 8) },
            kvGroupSize: kvGroupSize.map { min(max($0, 1), 256) },
            quantizedKVStart: quantizedKVStart.map { min(max($0, 0), 262_144) }
        )
    }
}

public struct AgentSettingsModelManifest: Codable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case llmID
        case modelID
        case providerID
        case provider
        case context
        case generation
        case thinking
    }

    private struct ContextManifest: Codable, Hashable, Sendable {
        let configuredWindowLimit: Int?

        init(configuredWindowLimit: Int?) {
            self.configuredWindowLimit = configuredWindowLimit.map {
                min(max($0, 1), 1_048_576)
            }
        }

        var isEmpty: Bool {
            configuredWindowLimit == nil
        }
    }

    private struct GenerationManifest: Codable, Hashable, Sendable {
        let overrides: AgentGenerationParameterOverrides?

        init(overrides: AgentGenerationParameterOverrides?) {
            self.overrides = overrides?.normalized().nilIfEmpty
        }

        var isEmpty: Bool {
            overrides == nil
        }
    }

    private struct ThinkingManifest: Codable, Hashable, Sendable {
        private enum CodingKeys: String, CodingKey {
            case options
            case defaultSelection = "default"
        }

        let options: [AgentThinkingSelection]?
        let defaultSelection: AgentThinkingSelection?

        init(
            options: [AgentThinkingSelection]?,
            defaultSelection: AgentThinkingSelection?
        ) {
            let normalizedOptions = AgentSettingsModelManifest.normalizedThinkingOptions(
                options ?? []
            )
            self.options = normalizedOptions.isEmpty ? nil : normalizedOptions
            self.defaultSelection = AgentSettingsModelManifest.normalizedDefaultThinkingSelection(
                defaultSelection,
                options: normalizedOptions
            )
        }

        var isEmpty: Bool {
            options == nil && defaultSelection == nil
        }
    }

    public let id: String
    public let kind: AgentModelProviderKind
    public let title: String?
    public let llmID: String?
    public let modelID: String
    public let providerID: UUID?
    public let provider: AgentRemoteProvider?
    public let configuredContextWindowLimit: Int?
    public let generationParameterOverrides: AgentGenerationParameterOverrides?
    public let apiKey: String?
    public let thinkingOptions: [AgentThinkingSelection]?
    public let defaultThinkingSelection: AgentThinkingSelection?

    public init(
        id: String? = nil,
        kind: AgentModelProviderKind,
        title: String? = nil,
        llmID: String? = nil,
        modelID: String,
        providerID: UUID? = nil,
        provider: AgentRemoteProvider? = nil,
        configuredContextWindowLimit: Int? = nil,
        generationParameterOverrides: AgentGenerationParameterOverrides? = nil,
        apiKey: String? = nil,
        thinkingOptions: [AgentThinkingSelection]? = nil,
        defaultThinkingSelection: AgentThinkingSelection? = nil
    ) {
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLLMID = llmID?.nilIfBlank
        let normalizedID = id?.nilIfBlank
            ?? normalizedLLMID
            ?? normalizedModelID
        let normalizedGenerationParameterOverrides = generationParameterOverrides?
            .normalized()
            .nilIfEmpty
        let normalizedThinkingOptions = Self.normalizedThinkingOptions(thinkingOptions ?? [])
        let normalizedDefaultThinkingSelection = Self.normalizedDefaultThinkingSelection(
            defaultThinkingSelection,
            options: normalizedThinkingOptions
        )
        self.id = normalizedID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind
        self.title = title?.nilIfBlank
        self.llmID = normalizedLLMID
        self.modelID = normalizedModelID
        self.providerID = kind == .remoteAPI ? (provider?.id ?? providerID) : nil
        self.provider = provider
        self.configuredContextWindowLimit = configuredContextWindowLimit.map {
            min(max($0, 1), 1_048_576)
        }
        self.generationParameterOverrides = normalizedGenerationParameterOverrides
        self.apiKey = apiKey?.nilIfBlank
        self.thinkingOptions = normalizedThinkingOptions.isEmpty ? nil : normalizedThinkingOptions
        self.defaultThinkingSelection = normalizedDefaultThinkingSelection
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let context = try container.decodeIfPresent(ContextManifest.self, forKey: .context)
        let generation = try container.decodeIfPresent(
            GenerationManifest.self,
            forKey: .generation
        )
        let thinking = try container.decodeIfPresent(ThinkingManifest.self, forKey: .thinking)
        let provider = try container.decodeIfPresent(AgentRemoteProvider.self, forKey: .provider)
        let providerID = try container.decodeIfPresent(UUID.self, forKey: .providerID)

        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id),
            kind: try container.decode(AgentModelProviderKind.self, forKey: .kind),
            title: try container.decodeIfPresent(String.self, forKey: .title),
            llmID: try container.decodeIfPresent(String.self, forKey: .llmID),
            modelID: try container.decode(String.self, forKey: .modelID),
            providerID: providerID,
            provider: provider,
            configuredContextWindowLimit: context?.configuredWindowLimit,
            generationParameterOverrides: generation?.overrides,
            apiKey: nil,
            thinkingOptions: thinking?.options,
            defaultThinkingSelection: thinking?.defaultSelection
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(llmID, forKey: .llmID)
        try container.encode(modelID, forKey: .modelID)
        if kind == .remoteAPI {
            try container.encodeIfPresent(providerID ?? provider?.id, forKey: .providerID)
        }

        let context = ContextManifest(
            configuredWindowLimit: configuredContextWindowLimit
        )
        if !context.isEmpty {
            try container.encode(context, forKey: .context)
        }

        let generation = GenerationManifest(
            overrides: generationParameterOverrides
        )
        if !generation.isEmpty {
            try container.encode(generation, forKey: .generation)
        }

        let thinking = ThinkingManifest(
            options: thinkingOptions,
            defaultSelection: defaultThinkingSelection
        )
        if !thinking.isEmpty {
            try container.encode(thinking, forKey: .thinking)
        }
    }

    public var displayTitle: String {
        if let title {
            return title
        }
        if let provider {
            return provider.displayTitleWithModelID
        }
        return modelID
    }

    public var availableThinkingSelections: [AgentThinkingSelection] {
        thinkingOptions ?? []
    }

    public var supportsThinking: Bool {
        !availableThinkingSelections.isEmpty
    }

    public var resolvedDefaultThinkingSelection: AgentThinkingSelection? {
        guard supportsThinking else {
            return nil
        }
        if let defaultThinkingSelection,
           availableThinkingSelections.contains(defaultThinkingSelection) {
            return defaultThinkingSelection
        }
        return availableThinkingSelections.first
    }

    public func thinkingSelection(
        for selection: AgentThinkingSelection?
    ) -> AgentThinkingSelection? {
        guard supportsThinking else {
            return nil
        }
        if let selection,
           availableThinkingSelections.contains(selection) {
            return selection
        }
        return resolvedDefaultThinkingSelection
    }

    public func matches(_ value: String) -> Bool {
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedValue.isEmpty else {
            return false
        }
        let foldedValue = normalizedValue.lowercased()
        return id.lowercased() == foldedValue
            || llmID?.lowercased() == foldedValue
            || modelID.lowercased() == foldedValue
    }

    public func normalized(
        providersByID: [UUID: AgentSettingsProviderManifest] = [:]
    ) -> AgentSettingsModelManifest? {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let resolvedProvider = provider
            ?? providerID.flatMap { providersByID[$0]?.remoteProvider(modelID: modelID) }
        if kind == .remoteAPI,
           resolvedProvider == nil {
            return nil
        }
        return AgentSettingsModelManifest(
            id: id,
            kind: kind,
            title: title,
            llmID: llmID,
            modelID: modelID,
            providerID: resolvedProvider?.id ?? providerID,
            provider: resolvedProvider,
            configuredContextWindowLimit: configuredContextWindowLimit,
            generationParameterOverrides: generationParameterOverrides,
            apiKey: apiKey,
            thinkingOptions: thinkingOptions,
            defaultThinkingSelection: defaultThinkingSelection
        )
    }

    private static func normalizedThinkingOptions(
        _ options: [AgentThinkingSelection]
    ) -> [AgentThinkingSelection] {
        var seen = Set<AgentThinkingSelection>()
        return options.filter { option in
            seen.insert(option).inserted
        }
    }

    private static func normalizedDefaultThinkingSelection(
        _ selection: AgentThinkingSelection?,
        options: [AgentThinkingSelection]
    ) -> AgentThinkingSelection? {
        guard !options.isEmpty else {
            return nil
        }
        if let selection,
           options.contains(selection) {
            return selection
        }
        return options.first
    }
}

public enum AgentSettingsManifestStore {
    public static let settingsFilename = "settings.json"
    private static let defaultSettingsCache = DefaultSettingsCache()

    public static func load() -> AgentSettingsManifest? {
        try? loadRequired()
    }

    public static func preload() {
        _ = load()
    }

    public static func loadRequired() throws -> AgentSettingsManifest {
        try defaultSettingsCache.load {
            try loadRequired(from: settingsURL())
        }
    }

    public static func loadRequired(
        from url: URL
    ) throws -> AgentSettingsManifest {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AgentSettingsManifestStoreError.missingFile(url)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AgentSettingsManifestStoreError.unreadableFile(url, error)
        }

        let manifest: AgentSettingsManifest
        do {
            manifest = try JSONDecoder().decode(AgentSettingsManifest.self, from: data)
        } catch {
            throw AgentSettingsManifestStoreError.invalidFile(url, error)
        }

        guard manifest.version >= AgentSettingsManifest.minimumSupportedVersion,
              manifest.version <= AgentSettingsManifest.currentVersion else {
            throw AgentSettingsManifestStoreError.unsupportedVersion(
                url,
                manifest.version,
                AgentSettingsManifest.currentVersion
            )
        }
        return manifest
    }

    public static func save(
        _ manifest: AgentSettingsManifest,
        to url: URL = settingsURL()
    ) throws {
        let directoryURL = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: [.atomic])
        if url.standardizedFileURL.path == settingsURL().standardizedFileURL.path {
            defaultSettingsCache.store(manifest)
        }
    }

    public static func settingsURL(fileManager: FileManager = .default) -> URL {
        MLXAppStorageDirectory.appSupportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(settingsFilename)
            .standardizedFileURL
    }

    private final class DefaultSettingsCache: @unchecked Sendable {
        private enum State {
            case notLoaded
            case loaded(AgentSettingsManifest)
            case failed(Error)
        }

        private let lock = OSAllocatedUnfairLock()
        private var state: State = .notLoaded

        func load(
            _ loader: () throws -> AgentSettingsManifest
        ) throws -> AgentSettingsManifest {
            lock.lock()
            switch state {
            case let .loaded(manifest):
                lock.unlock()
                return manifest
            case let .failed(error):
                lock.unlock()
                throw error
            case .notLoaded:
                break
            }

            do {
                let manifest = try loader()
                state = .loaded(manifest)
                lock.unlock()
                return manifest
            } catch {
                state = .failed(error)
                lock.unlock()
                throw error
            }
        }

        func store(_ manifest: AgentSettingsManifest) {
            lock.lock()
            state = .loaded(manifest)
            lock.unlock()
        }
    }
}

public enum AgentSettingsManifestStoreError: LocalizedError {
    case missingFile(URL)
    case unreadableFile(URL, Error)
    case invalidFile(URL, Error)
    case unsupportedVersion(URL, Int, Int)

    public var errorDescription: String? {
        switch self {
        case let .missingFile(url):
            return "Missing mlx-coder settings file: \(url.path)"
        case let .unreadableFile(url, error):
            return "Unable to read mlx-coder settings file \(url.path): \(error.localizedDescription)"
        case let .invalidFile(url, error):
            return "Invalid mlx-coder settings file \(url.path): \(error.localizedDescription)"
        case let .unsupportedVersion(url, found, expected):
            return "Unsupported mlx-coder settings file \(url.path): version \(found), expected \(expected)"
        }
    }
}
