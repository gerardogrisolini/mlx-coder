//
//  MLXServerCoreTests.swift
//  mlx-server
//

import Testing
@testable import MLXServerCore
import Dispatch
import Foundation
import MLXLMCommon

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
func perModelGenerationGateSerializesSameModel() async throws {
    let gate = MLXServerPerModelGenerationGate()
    let firstLease = try await gate.acquire(modelID: "model-a")
    let secondAcquired = AsyncSignalCounter()

    let secondTask = Task {
        let secondLease = try await gate.acquire(modelID: "model-a")
        await secondAcquired.signal()
        await secondLease.release()
    }

    let acquiredBeforeRelease = await secondAcquired.waitForCount(1, attempts: 10)
    #expect(!acquiredBeforeRelease)
    await firstLease.release()
    let acquiredAfterRelease = await secondAcquired.waitForCount(1, attempts: 200)
    #expect(acquiredAfterRelease)
    try await secondTask.value
}

@Test
func perModelGenerationGateAllowsDifferentModelsConcurrently() async throws {
    let gate = MLXServerPerModelGenerationGate()
    let firstLease = try await gate.acquire(modelID: "model-a")
    let secondAcquired = AsyncSignalCounter()

    let secondTask = Task {
        let secondLease = try await gate.acquire(modelID: "model-b")
        await secondAcquired.signal()
        await secondLease.release()
    }

    let acquiredSecondModel = await secondAcquired.waitForCount(1, attempts: 200)
    #expect(acquiredSecondModel)
    await firstLease.release()
    try await secondTask.value
}

@Test
func perModelGenerationGateAcquireAllWaitsForActiveModelLeases() async throws {
    let gate = MLXServerPerModelGenerationGate()
    let firstLease = try await gate.acquire(modelID: "model-a")
    let secondLease = try await gate.acquire(modelID: "model-b")
    let acquiredAll = AsyncSignalCounter()

    let acquireAllTask = Task {
        let leases = try await gate.acquireAll()
        await acquiredAll.signal()
        await leases.releaseAll()
    }

    let acquiredAllBeforeRelease = await acquiredAll.waitForCount(1, attempts: 10)
    #expect(!acquiredAllBeforeRelease)
    await firstLease.release()
    let acquiredAllAfterOneRelease = await acquiredAll.waitForCount(1, attempts: 10)
    #expect(!acquiredAllAfterOneRelease)
    await secondLease.release()
    let acquiredAllAfterBothReleases = await acquiredAll.waitForCount(1, attempts: 200)
    #expect(acquiredAllAfterBothReleases)
    try await acquireAllTask.value
}

@Test
func transcriptKeepsDirectAnswerVisibleWhenThinkingWasRequested() {
    let text = "Ciao, risposta diretta."

    #expect(
        MLXServerChatSessionTranscriptText.visibleAssistantContent(
            from: text,
            startsInThinking: true
        ) == text
    )
    #expect(
        MLXServerChatSessionTranscriptText.visibleAssistantContentForHistory(
            from: text,
            startsInThinking: true
        ).isEmpty
    )
    #expect(
        MLXServerChatSessionTranscriptText.reasoningContent(
            from: text,
            startsInThinking: true
        ).isEmpty
    )
}

@Test
func transcriptDoesNotPersistUnclosedInitialThinkingAsAssistantHistory() {
    let text = "Analisi lunga senza tag di chiusura."

    #expect(
        MLXServerChatSessionTranscriptText.visibleAssistantContentForHistory(
            from: text,
            startsInThinking: true
        ).isEmpty
    )
}

@Test
func transcriptStillSeparatesExplicitThinkingBlock() {
    let text = "<think>Analisi.</think>Risposta."

    #expect(
        MLXServerChatSessionTranscriptText.visibleAssistantContent(
            from: text,
            startsInThinking: false
        ) == "Risposta."
    )
    #expect(
        MLXServerChatSessionTranscriptText.visibleAssistantContentForHistory(
            from: text,
            startsInThinking: false
        ) == "Risposta."
    )
    #expect(
        MLXServerChatSessionTranscriptText.reasoningContent(
            from: text,
            startsInThinking: false
        ) == "Analisi."
    )
}

@Test
func transcriptSeparatesImplicitThinkingBlockClosedByEndTag() {
    let text = "Analisi implicita.</think>Risposta."

    #expect(
        MLXServerChatSessionTranscriptText.visibleAssistantContent(
            from: text,
            startsInThinking: true
        ) == "Risposta."
    )
    #expect(
        MLXServerChatSessionTranscriptText.visibleAssistantContentForHistory(
            from: text,
            startsInThinking: true
        ) == "Risposta."
    )
    #expect(
        MLXServerChatSessionTranscriptText.reasoningContent(
            from: text,
            startsInThinking: true
        ) == "Analisi implicita."
    )
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
func diskKVCachePromptTokenIdentityUsesDigestAndCount() {
    let firstIdentity = MLXServerDiskKVCacheIdentity(
        modelID: "mlx-community/test-a",
        runtimeKind: .llm,
        cacheLayoutSignature: "standard",
        promptTokenDigest: "same-rendered-prompt",
        promptTokenCount: 42,
        promptTokenIDs: []
    )
    let secondIdentity = MLXServerDiskKVCacheIdentity(
        modelID: "mlx-community/test-a",
        runtimeKind: .llm,
        cacheLayoutSignature: "standard",
        promptTokenDigest: "same-rendered-prompt",
        promptTokenCount: 42,
        promptTokenIDs: []
    )
    let thirdIdentity = MLXServerDiskKVCacheIdentity(
        modelID: "mlx-community/test-a",
        runtimeKind: .llm,
        cacheLayoutSignature: "standard",
        promptTokenDigest: "same-rendered-prompt",
        promptTokenCount: 43,
        promptTokenIDs: []
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
func kvCacheSettingsLoadPartialJSONWithDefaults() throws {
    let data = Data(#"{"mode":"quantized"}"#.utf8)

    let settings = try JSONDecoder().decode(MLXServerKVCacheSettings.self, from: data)

    #expect(settings.mode == .quantized)
    #expect(settings.quantizedBits == MLXServerKVCacheSettings.defaultQuantizedBits)
    #expect(settings.quantizedGroupSize == MLXServerKVCacheSettings.defaultQuantizedGroupSize)
    #expect(settings.quantizedStart == MLXServerKVCacheSettings.defaultQuantizedStart)
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
        cacheLayoutSignature: "standard",
        promptTokenDigest: "first",
        promptTokenCount: 2,
        promptTokenIDs: [1, 2]
    )
    let secondIdentity = MLXServerDiskKVCacheIdentity(
        modelID: "mlx-community/test-a",
        runtimeKind: .llm,
        cacheLayoutSignature: "standard",
        promptTokenDigest: "second",
        promptTokenCount: 2,
        promptTokenIDs: [3, 4]
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
func diskKVCacheKeepsWarmIndexAcrossCommits() throws {
    let indexProbe = DiskKVCacheIndexRebuildProbe()
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mlx-server-index-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let store = MLXServerDiskKVCacheStore(
        configuration: MLXServerDiskKVCacheConfiguration(
            directory: directory,
            limitBytes: 1_000_000
        ),
        indexRebuildObserver: {
            indexProbe.recordRebuild()
        }
    )
    let firstIdentity = MLXServerDiskKVCacheIdentity(
        modelID: "mlx-community/test-a",
        runtimeKind: .llm,
        cacheLayoutSignature: "standard",
        promptTokenDigest: "first",
        promptTokenCount: 2,
        promptTokenIDs: [1, 2]
    )
    let secondIdentity = MLXServerDiskKVCacheIdentity(
        modelID: "mlx-community/test-a",
        runtimeKind: .llm,
        cacheLayoutSignature: "standard",
        promptTokenDigest: "second",
        promptTokenCount: 2,
        promptTokenIDs: [3, 4]
    )

    let firstTarget = try #require(try store.preparePersistenceTarget(for: firstIdentity))
    try Data(repeating: 1, count: 16).write(to: firstTarget.temporaryURL)
    try store.commitPersistedCache(identity: firstIdentity, target: firstTarget)
    let rebuildsAfterFirstCommit = indexProbe.rebuildCount
    #expect(rebuildsAfterFirstCommit == 1)

    let secondTarget = try #require(try store.preparePersistenceTarget(for: secondIdentity))
    try Data(repeating: 2, count: 16).write(to: secondTarget.temporaryURL)
    try store.commitPersistedCache(identity: secondIdentity, target: secondTarget)

    #expect(indexProbe.rebuildCount == rebuildsAfterFirstCommit)
    #expect(FileManager.default.fileExists(atPath: firstTarget.cacheURL.path))
    #expect(FileManager.default.fileExists(atPath: secondTarget.cacheURL.path))
}

@Test
func diskKVCacheWarmIndexUpdatesRewrittenEntryByteCount() throws {
    let indexProbe = DiskKVCacheIndexRebuildProbe()
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mlx-server-index-rewrite-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let store = MLXServerDiskKVCacheStore(
        configuration: MLXServerDiskKVCacheConfiguration(
            directory: directory,
            limitBytes: 96
        ),
        indexRebuildObserver: {
            indexProbe.recordRebuild()
        }
    )
    let firstIdentity = MLXServerDiskKVCacheIdentity(
        modelID: "mlx-community/test-a",
        runtimeKind: .llm,
        cacheLayoutSignature: "standard",
        promptTokenDigest: "first",
        promptTokenCount: 2,
        promptTokenIDs: [1, 2]
    )
    let secondIdentity = MLXServerDiskKVCacheIdentity(
        modelID: "mlx-community/test-a",
        runtimeKind: .llm,
        cacheLayoutSignature: "standard",
        promptTokenDigest: "second",
        promptTokenCount: 2,
        promptTokenIDs: [3, 4]
    )

    let firstTarget = try #require(try store.preparePersistenceTarget(for: firstIdentity))
    try Data(repeating: 1, count: 32).write(to: firstTarget.temporaryURL)
    try store.commitPersistedCache(identity: firstIdentity, target: firstTarget)
    let rebuildsAfterFirstCommit = indexProbe.rebuildCount

    let secondTarget = try #require(try store.preparePersistenceTarget(for: secondIdentity))
    try Data(repeating: 2, count: 32).write(to: secondTarget.temporaryURL)
    try store.commitPersistedCache(identity: secondIdentity, target: secondTarget)
    #expect(indexProbe.rebuildCount == rebuildsAfterFirstCommit)

    let rewrittenFirstTarget = try #require(try store.preparePersistenceTarget(for: firstIdentity))
    try Data(repeating: 3, count: 96).write(to: rewrittenFirstTarget.temporaryURL)
    try store.commitPersistedCache(identity: firstIdentity, target: rewrittenFirstTarget)

    #expect(indexProbe.rebuildCount == rebuildsAfterFirstCommit)
    #expect(FileManager.default.fileExists(atPath: firstTarget.cacheURL.path))
    #expect(!FileManager.default.fileExists(atPath: secondTarget.cacheURL.path))
    #expect(!FileManager.default.fileExists(atPath: secondTarget.metadataURL.path))
}

@Test
func diskKVCachePersistenceWriterDoesNotBlockEnqueueBehindRunningJob() {
    let writer = MLXServerDiskKVCachePersistenceWriter()
    let firstStarted = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    let secondStarted = DispatchSemaphore(value: 0)
    let enqueueReturned = DispatchSemaphore(value: 0)

    writer.enqueue(coalescingKey: "first") {
        firstStarted.signal()
        _ = releaseFirst.wait(timeout: .now() + .seconds(2))
    }
    #expect(firstStarted.wait(timeout: .now() + .seconds(2)) == .success)

    DispatchQueue.global().async {
        writer.enqueue(coalescingKey: "second") {
            secondStarted.signal()
        }
        enqueueReturned.signal()
    }

    #expect(enqueueReturned.wait(timeout: .now() + .milliseconds(200)) == .success)
    #expect(secondStarted.wait(timeout: .now() + .milliseconds(100)) == .timedOut)

    releaseFirst.signal()
    #expect(secondStarted.wait(timeout: .now() + .seconds(2)) == .success)
}

@Test
func diskKVCachePersistenceWriterCoalescesPendingJobsByKey() {
    let writer = MLXServerDiskKVCachePersistenceWriter()
    let firstStarted = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    let replacementFinished = DispatchSemaphore(value: 0)
    let recorder = DiskKVCacheWriterExecutionRecorder()

    writer.enqueue(coalescingKey: "blocking") {
        firstStarted.signal()
        _ = releaseFirst.wait(timeout: .now() + .seconds(2))
    }
    #expect(firstStarted.wait(timeout: .now() + .seconds(2)) == .success)

    writer.enqueue(coalescingKey: "same-key") {
        recorder.record("old")
    }
    writer.enqueue(coalescingKey: "same-key") {
        recorder.record("new")
        replacementFinished.signal()
    }

    releaseFirst.signal()
    #expect(replacementFinished.wait(timeout: .now() + .seconds(2)) == .success)
    #expect(recorder.values == ["new"])
}

@Test
func diskPersistenceBoundaryPolicyAlignsStoreLength() {
    // Too short: not worth a disk checkpoint.
    #expect(DiskPersistenceBoundaryPolicy.alignedStoreTokenCount(0) == 0)
    #expect(DiskPersistenceBoundaryPolicy.alignedStoreTokenCount(511) == 0)
    // Short prompts above the minimum are stored as-is.
    #expect(DiskPersistenceBoundaryPolicy.alignedStoreTokenCount(512) == 512)
    #expect(DiskPersistenceBoundaryPolicy.alignedStoreTokenCount(544) == 544)
    // Once past minimum + trim, lengths align down to the boundary.
    #expect(DiskPersistenceBoundaryPolicy.alignedStoreTokenCount(1_060) == 1_024)
    #expect(DiskPersistenceBoundaryPolicy.alignedStoreTokenCount(2_100) == 2_048)
    // Consecutive turns within one boundary produce the same store length.
    #expect(
        DiskPersistenceBoundaryPolicy.alignedStoreTokenCount(5_200)
            == DiskPersistenceBoundaryPolicy.alignedStoreTokenCount(6_100)
    )
    // Aligned-down results below the minimum fall back to the full length.
    #expect(DiskPersistenceBoundaryPolicy.alignedStoreTokenCount(1_040) == 1_040)
}

@Test
func diskKVCacheSkipsPersistenceForDominatedIdentities() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mlx-server-dedup-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let store = MLXServerDiskKVCacheStore(
        configuration: MLXServerDiskKVCacheConfiguration(
            directory: directory,
            limitBytes: 1_000_000
        )
    )
    let storedIdentity = MLXServerDiskKVCacheIdentity(
        modelID: "mlx-community/test-a",
        runtimeKind: .llm,
        cacheLayoutSignature: "standard",
        promptTokenDigest: "stored",
        promptTokenCount: 4,
        promptTokenIDs: [1, 2, 3, 4]
    )

    let target = try #require(try store.preparePersistenceTarget(for: storedIdentity))
    try Data(repeating: 1, count: 16).write(to: target.temporaryURL)
    try store.commitPersistedCache(identity: storedIdentity, target: target)

    // Identical identity: already on disk, no rewrite needed.
    #expect(!store.needsPersistence(for: storedIdentity))

    // Strict prefix of the stored entry: dominated, no write needed.
    let prefixIdentity = MLXServerDiskKVCacheIdentity(
        modelID: "mlx-community/test-a",
        runtimeKind: .llm,
        cacheLayoutSignature: "standard",
        promptTokenDigest: "prefix",
        promptTokenCount: 2,
        promptTokenIDs: [1, 2]
    )
    #expect(!store.needsPersistence(for: prefixIdentity))

    // Extension of the stored entry: new tokens, must be written.
    let extendedIdentity = MLXServerDiskKVCacheIdentity(
        modelID: "mlx-community/test-a",
        runtimeKind: .llm,
        cacheLayoutSignature: "standard",
        promptTokenDigest: "extended",
        promptTokenCount: 6,
        promptTokenIDs: [1, 2, 3, 4, 5, 6]
    )
    #expect(store.needsPersistence(for: extendedIdentity))

    // Divergent prompt: unrelated, must be written.
    let divergentIdentity = MLXServerDiskKVCacheIdentity(
        modelID: "mlx-community/test-a",
        runtimeKind: .llm,
        cacheLayoutSignature: "standard",
        promptTokenDigest: "divergent",
        promptTokenCount: 4,
        promptTokenIDs: [1, 2, 9, 9]
    )
    #expect(store.needsPersistence(for: divergentIdentity))
}

@Test
func diskKVCacheCommitPrunesSupersededPrefixEntries() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mlx-server-superseded-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let store = MLXServerDiskKVCacheStore(
        configuration: MLXServerDiskKVCacheConfiguration(
            directory: directory,
            limitBytes: 1_000_000
        )
    )
    let firstTurnIdentity = MLXServerDiskKVCacheIdentity(
        modelID: "mlx-community/test-a",
        runtimeKind: .llm,
        cacheLayoutSignature: "standard",
        promptTokenDigest: "turn-1",
        promptTokenCount: 3,
        promptTokenIDs: [1, 2, 3]
    )
    let unrelatedIdentity = MLXServerDiskKVCacheIdentity(
        modelID: "mlx-community/test-a",
        runtimeKind: .llm,
        cacheLayoutSignature: "standard",
        promptTokenDigest: "other-session",
        promptTokenCount: 3,
        promptTokenIDs: [9, 8, 7]
    )
    let secondTurnIdentity = MLXServerDiskKVCacheIdentity(
        modelID: "mlx-community/test-a",
        runtimeKind: .llm,
        cacheLayoutSignature: "standard",
        promptTokenDigest: "turn-2",
        promptTokenCount: 5,
        promptTokenIDs: [1, 2, 3, 4, 5]
    )

    let firstTarget = try #require(try store.preparePersistenceTarget(for: firstTurnIdentity))
    try Data(repeating: 1, count: 16).write(to: firstTarget.temporaryURL)
    try store.commitPersistedCache(identity: firstTurnIdentity, target: firstTarget)

    let unrelatedTarget = try #require(try store.preparePersistenceTarget(for: unrelatedIdentity))
    try Data(repeating: 2, count: 16).write(to: unrelatedTarget.temporaryURL)
    try store.commitPersistedCache(identity: unrelatedIdentity, target: unrelatedTarget)

    let secondTarget = try #require(try store.preparePersistenceTarget(for: secondTurnIdentity))
    try Data(repeating: 3, count: 16).write(to: secondTarget.temporaryURL)
    try store.commitPersistedCache(identity: secondTurnIdentity, target: secondTarget)

    // The first turn's entry is a strict prefix of the second turn's entry
    // and must be pruned; the unrelated session's entry must survive.
    #expect(!FileManager.default.fileExists(atPath: firstTarget.cacheURL.path))
    #expect(!FileManager.default.fileExists(atPath: firstTarget.metadataURL.path))
    #expect(FileManager.default.fileExists(atPath: unrelatedTarget.cacheURL.path))
    #expect(FileManager.default.fileExists(atPath: unrelatedTarget.metadataURL.path))
    #expect(FileManager.default.fileExists(atPath: secondTarget.cacheURL.path))
    #expect(FileManager.default.fileExists(atPath: secondTarget.metadataURL.path))
}

@Test
func diskKVCacheIndexRebuildRemovesOrphanedCacheFiles() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mlx-server-orphans-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let store = MLXServerDiskKVCacheStore(
        configuration: MLXServerDiskKVCacheConfiguration(
            directory: directory,
            limitBytes: 1_000_000
        )
    )
    let identity = MLXServerDiskKVCacheIdentity(
        modelID: "mlx-community/test-a",
        runtimeKind: .llm,
        cacheLayoutSignature: "standard",
        promptTokenDigest: "first",
        promptTokenCount: 2,
        promptTokenIDs: [1, 2]
    )

    let target = try #require(try store.preparePersistenceTarget(for: identity))
    try Data(repeating: 1, count: 16).write(to: target.temporaryURL)
    try store.commitPersistedCache(identity: identity, target: target)

    let modelDirectory = target.cacheURL.deletingLastPathComponent()
    let orphanedCacheURL = modelDirectory.appendingPathComponent("orphan.safetensors")
    try Data(repeating: 2, count: 16).write(to: orphanedCacheURL)
    let staleTemporaryURL = modelDirectory.appendingPathComponent("stale.tmp.safetensors")
    try Data(repeating: 3, count: 16).write(to: staleTemporaryURL)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: -3 * 60 * 60)],
        ofItemAtPath: staleTemporaryURL.path
    )
    let freshTemporaryURL = modelDirectory.appendingPathComponent("fresh.tmp.safetensors")
    try Data(repeating: 4, count: 16).write(to: freshTemporaryURL)

    // A fresh store (e.g. after a server restart) rebuilds the index from
    // disk and must clean orphans up; the original store's index is warm.
    let restartedStore = MLXServerDiskKVCacheStore(
        configuration: MLXServerDiskKVCacheConfiguration(
            directory: directory,
            limitBytes: 1_000_000
        )
    )
    restartedStore.enforceDiskLimit()

    #expect(FileManager.default.fileExists(atPath: target.cacheURL.path))
    #expect(FileManager.default.fileExists(atPath: target.metadataURL.path))
    #expect(!FileManager.default.fileExists(atPath: orphanedCacheURL.path))
    #expect(!FileManager.default.fileExists(atPath: staleTemporaryURL.path))
    #expect(FileManager.default.fileExists(atPath: freshTemporaryURL.path))
}

@Test
func diskKVCachePersistenceWriterRunsPendingJobsWithDistinctKeys() {
    let writer = MLXServerDiskKVCachePersistenceWriter()
    let firstStarted = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    let bothFinished = DispatchSemaphore(value: 0)
    let recorder = DiskKVCacheWriterExecutionRecorder()

    writer.enqueue(coalescingKey: "blocking") {
        firstStarted.signal()
        _ = releaseFirst.wait(timeout: .now() + .seconds(2))
    }
    #expect(firstStarted.wait(timeout: .now() + .seconds(2)) == .success)

    // Pending persists for different entries (e.g. concurrent sessions on the
    // same model) must not replace each other.
    writer.enqueue(coalescingKey: "entry-a") {
        recorder.record("entry-a")
    }
    writer.enqueue(coalescingKey: "entry-b") {
        recorder.record("entry-b")
        bothFinished.signal()
    }

    releaseFirst.signal()
    #expect(bothFinished.wait(timeout: .now() + .seconds(2)) == .success)
    #expect(recorder.values == ["entry-a", "entry-b"])
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

private final class DiskKVCacheIndexRebuildProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _rebuildCount = 0

    var rebuildCount: Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return _rebuildCount
    }

    func recordRebuild() {
        lock.lock()
        _rebuildCount += 1
        lock.unlock()
    }
}

private final class DiskKVCacheWriterExecutionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []

    var values: [String] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return _values
    }

    func record(_ value: String) {
        lock.lock()
        _values.append(value)
        lock.unlock()
    }
}

private actor AsyncSignalCounter {
    private var count = 0

    func signal() {
        count += 1
    }

    func waitForCount(
        _ targetCount: Int,
        attempts: Int,
        intervalNanoseconds: UInt64 = 10_000_000
    ) async -> Bool {
        for _ in 0..<attempts {
            if count >= targetCount {
                return true
            }
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        return count >= targetCount
    }
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
