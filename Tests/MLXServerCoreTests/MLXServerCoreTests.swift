//
//  MLXServerCoreTests.swift
//  mlx-server
//

import Testing
@testable import MLXServerCore
import Foundation
import MLXLMCommon

@Test
func exposesSharedVersionDescription() {
    #expect(MLXServerCore.serviceName == "mlx-server")
    #expect(MLXServerCore.version == "0.1.1")
    #expect(MLXServerCore.versionDescription == "mlx-server 0.1.1")
}

@Test
func validatesDefaultConfiguration() throws {
    let configuration = try MLXServerConfiguration().validated()

    #expect(configuration.host == "127.0.0.1")
    #expect(configuration.port == 8080)
}

@Test
func rejectsInvalidPort() {
    #expect(throws: MLXServerConfigurationError.invalidPort(0)) {
        try MLXServerConfiguration(port: 0).validated()
    }
}

@Test
func startsRuntimeWithNoLoadedModels() async {
    let runtime = MLXServerRuntime()
    let loadedModelIDs = await runtime.loadedModelIDs

    #expect(loadedModelIDs.isEmpty)
}

@Test
func serverSupportFilesDefaultToHomeMlxServerDirectory() {
    let supportDirectory = MLXServerUserHomeDirectory.current()
        .appendingPathComponent(".mlx-server", isDirectory: true)
        .standardizedFileURL

    #expect(MLXServerSettingsStore.defaultSupportDirectoryURL() == supportDirectory)
    #expect(MLXServerSettingsStore.settingsURL() == supportDirectory.appendingPathComponent("settings.json"))
    #expect(MLXServerModelsManifestStore.modelsURL() == supportDirectory.appendingPathComponent("models.json"))
}

@Test
func diskKVCacheDefaultsToBalancedLimit() {
    let configuration = MLXServerDiskKVCacheConfiguration()
    let supportDirectory = MLXServerSettingsStore.defaultSupportDirectoryURL()

    #expect(configuration.isEnabled)
    #expect(configuration.limitBytes == MLXServerDiskKVCacheConfiguration.defaultLimitBytes)
    #expect(configuration.directory == supportDirectory.appendingPathComponent("KVCaches", isDirectory: true))
}

@Test
func diskKVCacheRejectsUnreasonableLimit() {
    #expect(throws: MLXServerSettingsError.invalidDiskKVCacheLimit) {
        try MLXServerDiskKVCacheSettings(limitGB: -1).validated()
    }
    #expect(throws: MLXServerSettingsError.invalidDiskKVCacheLimit) {
        try MLXServerDiskKVCacheSettings(
            limitGB: MLXServerDiskKVCacheSettings.maximumLimitGB + 1
        ).validated()
    }
    #expect(throws: MLXServerSettingsError.invalidDiskKVCacheLimit) {
        try MLXServerDiskKVCacheSettings(limitGB: .infinity).validated()
    }
}

@Test
func diskKVCachePromptTokenIdentityWinsOverChatSignature() {
    let firstIdentity = MLXServerDiskKVCacheIdentity(
        modelID: "mlx-community/test-a",
        runtimeKind: .llm,
        chatKeySignature: "chat-a",
        transcriptSignature: "transcript-a",
        cacheLayoutSignature: "standard",
        promptTokenDigest: "same-rendered-prompt",
        promptTokenCount: 42
    )
    let secondIdentity = MLXServerDiskKVCacheIdentity(
        modelID: "mlx-community/test-a",
        runtimeKind: .llm,
        chatKeySignature: "chat-b",
        transcriptSignature: "transcript-b",
        cacheLayoutSignature: "standard",
        promptTokenDigest: "same-rendered-prompt",
        promptTokenCount: 42
    )
    let thirdIdentity = MLXServerDiskKVCacheIdentity(
        modelID: "mlx-community/test-a",
        runtimeKind: .llm,
        chatKeySignature: "chat-b",
        transcriptSignature: "transcript-b",
        cacheLayoutSignature: "standard",
        promptTokenDigest: "same-rendered-prompt",
        promptTokenCount: 43
    )

    #expect(firstIdentity.entryKey == secondIdentity.entryKey)
    #expect(firstIdentity.entryKey != thirdIdentity.entryKey)
}

@Test
func savesAndLoadsServerSettingsJSON() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mlx-server-settings-\(UUID().uuidString)", isDirectory: true)
    let settingsURL = directory.appendingPathComponent("settings.json")
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let settings = MLXServerSettings(
        host: " 127.0.0.1 ",
        port: 9090,
        webServerThreadCount: 4,
        loadOneModelAtATime: true,
        http2PriorKnowledge: true,
        apiKey: " test-key ",
        metricsLogPath: " /tmp/mlx-server.metrics.jsonl ",
        kvCache: MLXServerKVCacheSettings(
            mode: .quantized,
            quantizedBits: 4,
            quantizedGroupSize: 64,
            quantizedStart: 2_048
        ),
        diskKVCache: MLXServerDiskKVCacheSettings(
            enabled: true,
            directoryPath: " /tmp/mlx-server-kv ",
            limitGB: 42
        ),
        huggingFaceCache: MLXServerHuggingFaceCacheSettings(
            directoryPath: " /tmp/huggingface/hub ",
            bookmark: " dGVzdA== "
        )
    )

    try MLXServerSettingsStore.save(settings, to: settingsURL)
    let loaded = try MLXServerSettingsStore.loadRequired(from: settingsURL)

    #expect(loaded.host == "127.0.0.1")
    #expect(loaded.port == 9090)
    #expect(loaded.webServerThreadCount == 4)
    #expect(loaded.loadOneModelAtATime)
    #expect(loaded.http2PriorKnowledge)
    #expect(loaded.apiKey == "test-key")
    #expect(loaded.metricsLogPath == "/tmp/mlx-server.metrics.jsonl")
    #expect(loaded.kvCache.mode == .quantized)
    #expect(loaded.kvCache.quantizedBits == 4)
    #expect(loaded.kvCache.quantizedGroupSize == 64)
    #expect(loaded.kvCache.quantizedStart == 2_048)
    #expect(loaded.diskKVCache.directoryPath == "/tmp/mlx-server-kv")
    #expect(loaded.diskKVCache.limitGB == 42)
    #expect(loaded.huggingFaceCache.directoryPath == "/tmp/huggingface/hub")
    #expect(loaded.huggingFaceCache.bookmark == "dGVzdA==")
    #expect(loaded.huggingFaceCache.bookmarkData == Data("test".utf8))
}

@Test
func serverSettingsLoadsOlderJSONWithoutHuggingFaceCache() throws {
    let data = Data(
        """
        {
          "host": "127.0.0.1",
          "port": 8080,
          "load_one_model_at_a_time": true,
          "disk_kv_cache": {
            "enabled": true,
            "limit_gb": 100
          }
        }
        """.utf8
    )

    let settings = try JSONDecoder().decode(MLXServerSettings.self, from: data).validated()

    #expect(settings.huggingFaceCache.directoryPath == nil)
    #expect(settings.huggingFaceCache.bookmark == nil)
    #expect(settings.kvCache.mode == .standard)
    #expect(settings.webServerThreadCount == MLXServerSettings.defaultWebServerThreadCount)
}

@Test
func generationDefaultsApplyQuantizedKVCacheSettings() {
    let defaults = MLXServerModelGenerationDefaults(maxOutputTokens: 256)
    let parameters = defaults.generateParameters(
        kvCacheSettings: MLXServerKVCacheSettings(
            mode: .quantized,
            quantizedBits: 4,
            quantizedGroupSize: 64,
            quantizedStart: 1_024
        )
    )

    #expect(parameters.maxTokens == 256)
    #expect(parameters.kvBits == 4)
    #expect(parameters.kvGroupSize == 64)
    #expect(parameters.quantizedKVStart == 1_024)
}

@Test
func serverSettingsRejectInvalidWebServerThreadCount() {
    let settings = MLXServerSettings(webServerThreadCount: 0)

    #expect(throws: MLXServerSettingsError.invalidWebServerThreadCount(0)) {
        try settings.validated()
    }
}

@Test
func missingServerSettingsReportsSetupInstruction() {
    let settingsURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("missing-\(UUID().uuidString)")
        .appendingPathComponent("settings.json")

    #expect(throws: MLXServerSettingsError.missingSettings(settingsURL)) {
        try MLXServerSettingsStore.loadRequired(from: settingsURL)
    }
}

@Test
func diskKVCacheEvictsLeastRecentlyUsedEntries() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mlx-server-tests-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let store = MLXServerDiskKVCacheStore(
        configuration: MLXServerDiskKVCacheConfiguration(
            directory: directory,
            limitBytes: 24
        )
    )
    let firstIdentity = MLXServerDiskKVCacheIdentity(
        modelID: "mlx-community/test-a",
        runtimeKind: .llm,
        chatKeySignature: "chat",
        transcriptSignature: "first",
        cacheLayoutSignature: "standard"
    )
    let secondIdentity = MLXServerDiskKVCacheIdentity(
        modelID: "mlx-community/test-a",
        runtimeKind: .llm,
        chatKeySignature: "chat",
        transcriptSignature: "second",
        cacheLayoutSignature: "standard"
    )

    let firstTarget = try #require(try store.preparePersistenceTarget(for: firstIdentity))
    try Data(repeating: 1, count: 32).write(to: firstTarget.temporaryURL)
    try store.commitPersistedCache(identity: firstIdentity, target: firstTarget)

    let secondTarget = try #require(try store.preparePersistenceTarget(for: secondIdentity))
    try Data(repeating: 2, count: 32).write(to: secondTarget.temporaryURL)
    try store.commitPersistedCache(identity: secondIdentity, target: secondTarget)

    #expect(!FileManager.default.fileExists(atPath: firstTarget.cacheURL.path))
    #expect(!FileManager.default.fileExists(atPath: firstTarget.metadataURL.path))
    #expect(FileManager.default.fileExists(atPath: secondTarget.cacheURL.path))
    #expect(FileManager.default.fileExists(atPath: secondTarget.metadataURL.path))
}

@Test
func savesAndLoadsModelsJSON() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mlx-server-models-\(UUID().uuidString)", isDirectory: true)
    let modelsURL = directory.appendingPathComponent("models.json")
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let manifest = MLXServerModelsManifest(
        defaultModelID: "mlx-community/test-model",
        models: [
            MLXServerModelRecord(
                id: "mlx-community/test-model",
                displayName: "Test Model",
                repositoryID: "mlx-community/test-model",
                revision: "main",
                runtimeKind: .llm,
                generationDefaults: MLXServerModelGenerationDefaults(
                    contextWindow: 262_144,
                    maxOutputTokens: 4_096,
                    temperature: 0.2,
                    topP: 0.9,
                    topK: 40,
                    repetitionPenalty: 1.1,
                    presencePenalty: 0.1,
                    frequencyPenalty: 0.2
                ),
                thinking: .effort(
                    levels: [.low, .medium, .high],
                    supportsPreserveThinking: true
                )
            )
        ]
    )

    try MLXServerModelsManifestStore.save(manifest, to: modelsURL)
    let loaded = try MLXServerModelsManifestStore.loadRequired(from: modelsURL)
    let catalog = try loaded.catalog
    let model = try catalog.resolve(id: nil)

    #expect(catalog.defaultModelID == "mlx-community/test-model")
    #expect(model.id == "mlx-community/test-model")
    #expect(model.displayName == "Test Model")
    #expect(model.configuration.name == "mlx-community/test-model")
    #expect(model.generationDefaults.contextWindow == 262_144)
    #expect(model.generationDefaults.maxOutputTokens == 4_096)
    #expect(model.generationDefaults.temperature == 0.2)
    #expect(model.generationDefaults.topP == 0.9)
    #expect(model.generationDefaults.topK == 40)
    #expect(model.generationDefaults.repetitionPenalty == 1.1)
    #expect(model.generationDefaults.presencePenalty == 0.1)
    #expect(model.generationDefaults.frequencyPenalty == 0.2)
    #expect(model.thinking.supportsThinking)
    #expect(model.thinking.supportsReasoningEffort)
    #expect(model.thinking.supportsPreserveThinking)
    #expect(model.thinking.availableSelections == [.off, .low, .medium, .high])
    #expect(model.thinking.defaultSelection == .medium)
}

@Test
func missingModelsReportsSetupInstruction() {
    let modelsURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("missing-\(UUID().uuidString)")
        .appendingPathComponent("models.json")

    #expect(throws: MLXServerModelsManifestError.missingModels(modelsURL)) {
        try MLXServerModelsManifestStore.loadRequired(from: modelsURL)
    }
}

@Test
func rejectsUnconfiguredModelID() throws {
    let catalog = try MLXServerModelCatalog(
        manifest: MLXServerModelsManifest(
            models: [
                MLXServerModelRecord(
                    id: "mlx-community/test-model",
                    displayName: "Test Model",
                    repositoryID: "mlx-community/test-model"
                )
            ]
        )
    )

    #expect(throws: MLXServerModelsManifestError.modelNotConfigured("other-model")) {
        try catalog.resolve(id: "other-model")
    }
}

@Test
func buildsGenerationRequestWithConfiguredModel() {
    let request = MLXServerGenerationRequest(
        model: testModel(),
        messages: [
            .system("You are concise."),
            .user("ciao")
        ]
    )

    #expect(request.model.id == "mlx-community/test-model")
    #expect(request.messages.count == 2)
    #expect(request.runtimeKind == .llm)
}

@Test
func appliesModelGenerationDefaults() {
    let defaults = MLXServerModelGenerationDefaults(
        maxOutputTokens: 1_024,
        temperature: 0.3,
        topP: 0.8,
        topK: 20,
        repetitionPenalty: 1.1,
        presencePenalty: 0.4,
        frequencyPenalty: 0.5
    )
    let parameters = defaults.generateParameters()

    #expect(parameters.maxTokens == 1_024)
    #expect(parameters.temperature == 0.3)
    #expect(parameters.topP == 0.8)
    #expect(parameters.topK == 20)
    #expect(parameters.repetitionPenalty == 1.1)
    #expect(parameters.presencePenalty == 0.4)
    #expect(parameters.frequencyPenalty == 0.5)
}

@Test
func maxTokensCanOverrideModelDefaultOutputLimit() {
    let defaults = MLXServerModelGenerationDefaults(
        maxOutputTokens: 1_024,
        temperature: 0.3,
        topP: 0.8,
        topK: 20,
        repetitionPenalty: 1.1,
        presencePenalty: 0.4,
        frequencyPenalty: 0.5
    )
    let parameters = defaults.generateParameters(
        maxTokens: 128
    )

    #expect(parameters.maxTokens == 128)
    #expect(parameters.temperature == 0.3)
    #expect(parameters.topP == 0.8)
    #expect(parameters.topK == 20)
    #expect(parameters.repetitionPenalty == 1.1)
    #expect(parameters.presencePenalty == 0.4)
    #expect(parameters.frequencyPenalty == 0.5)
}

@Test
func modelThinkingConfigurationNormalizesEffortLevels() {
    let configuration = MLXServerModelThinkingConfiguration(
        supportsThinking: true,
        supportsReasoningEffort: true,
        supportsPreserveThinking: false,
        availableSelections: [.off, .high, .low, .enabled],
        defaultSelection: .xhigh
    )
    .validated()

    #expect(configuration.availableSelections == [.off, .low, .high])
    #expect(configuration.defaultSelection == .low)
    #expect(configuration.selection(for: "high") == .high)
    #expect(configuration.selection(for: "none") == .off)
}

@Test
func modelThinkingConfigurationFallsBackToGenericEnable() {
    let configuration = MLXServerModelThinkingConfiguration.generic

    #expect(configuration.selection(for: "high") == .enabled)
    #expect(configuration.selection(for: nil) == .off)
    #expect(configuration.additionalContext(for: .enabled)["enable_thinking"] as? Bool == true)
}

@Test
func selectsVLMRuntimeWhenMediaIsAttached() throws {
    let imageURL = try #require(URL(string: "https://example.com/image.png"))
    let request = MLXServerGenerationRequest(
        model: testModel(),
        messages: [
            .user("Describe this image.", imageURLs: [imageURL])
        ]
    )

    #expect(request.requiresVisionRuntime)
    #expect(request.runtimeKind == .vlm)
}

private func testModel(
    id: String = "mlx-community/test-model",
    runtimeKind: MLXServerModelRuntimeKind = .llm,
    generationDefaults: MLXServerModelGenerationDefaults = .init(),
    thinking: MLXServerModelThinkingConfiguration = .disabled
) -> MLXServerModelDescriptor {
    MLXServerModelDescriptor(
        id: id,
        displayName: "Test Model",
        runtimeKind: runtimeKind,
        configuration: ModelConfiguration(id: id),
        generationDefaults: generationDefaults,
        thinking: thinking
    )
}
