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
func perModelGenerationGateReportsIdleState() async throws {
    let gate = MLXServerPerModelGenerationGate()

    // Unknown models are idle.
    #expect(await gate.isIdle(modelID: "model-a"))

    let lease = try await gate.acquire(modelID: "model-a")
    #expect(!(await gate.isIdle(modelID: "model-a")))
    #expect(await gate.isIdle(modelID: "model-b"))

    await lease.release()
    #expect(await gate.isIdle(modelID: "model-a"))
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
func assistantHistoryMessagesPreserveThinkingWhenEnabled() {
    let messages = MLXServerChatSessionTranscriptText.assistantHistoryMessages(
        from: "Ragionamento.</think>Risposta.",
        startsInThinking: true,
        preservesThinking: true
    )

    #expect(messages.count == 2)
    #expect(messages[0].content == MLXServerReasoningTranscript.reasoningSummary("Ragionamento."))
    #expect(messages[1].content == "Risposta.")
    #expect(messages[1].reasoningContent == "Ragionamento.")
}

@Test
func assistantHistoryMessagesDropThinkingWhenDisabled() {
    let messages = MLXServerChatSessionTranscriptText.assistantHistoryMessages(
        from: "Ragionamento.</think>Risposta.",
        startsInThinking: true,
        preservesThinking: false
    )

    #expect(messages == [.assistant("Risposta.")])
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
func diskKVCacheSessionKeyScopesEntryBySessionAndLayout() {
    let firstKey = testChatSessionCacheKey(sessionKey: "session-a", layout: "standard")
    let sameKey = testChatSessionCacheKey(sessionKey: "session-a", layout: "standard")
    let differentSessionKey = testChatSessionCacheKey(sessionKey: "session-b", layout: "standard")
    let differentLayoutKey = testChatSessionCacheKey(sessionKey: "session-a", layout: "quantized")

    #expect(firstKey.entryKey == sameKey.entryKey)
    #expect(firstKey.entryKey != differentSessionKey.entryKey)
    #expect(firstKey.entryKey != differentLayoutKey.entryKey)
}

@Test
func chatSessionTranscriptContinuationMatchesAssistantByRoleOnly() {
    let stored = [
        MLXServerChatMessage.system("You are concise.").transcriptFingerprint,
        MLXServerChatMessage.user("Hello").transcriptFingerprint,
        MLXServerChatTranscriptFingerprint.generatedAssistantPlaceholder
    ]
    let request = [
        MLXServerChatMessage.system("You are concise.").transcriptFingerprint,
        MLXServerChatMessage.user("Hello").transcriptFingerprint,
        MLXServerChatMessage.assistant("Client-side visible text only").transcriptFingerprint,
        MLXServerChatMessage.user("Continue").transcriptFingerprint
    ]

    #expect(
        MLXServerChatSessionTranscript.continuationSuffixStartIndex(
            stored: stored,
            request: request
        ) == 3
    )
}

@Test
func chatSessionTranscriptContinuationConsumesAssistantReplayRun() {
    let stored = [
        MLXServerChatMessage.system("You are concise.").transcriptFingerprint,
        MLXServerChatMessage.user("Hello").transcriptFingerprint,
        MLXServerChatTranscriptFingerprint.generatedAssistantPlaceholder
    ]
    let request = [
        MLXServerChatMessage.system("You are concise.").transcriptFingerprint,
        MLXServerChatMessage.user("Hello").transcriptFingerprint,
        MLXServerChatMessage.assistant("reasoning_summary:\n...").transcriptFingerprint,
        MLXServerChatMessage.assistant("Visible content").transcriptFingerprint,
        MLXServerChatMessage.user("Continue").transcriptFingerprint
    ]

    #expect(
        MLXServerChatSessionTranscript.continuationSuffixStartIndex(
            stored: stored,
            request: request
        ) == 4
    )
}

@Test
func chatSessionTranscriptRejectsDivergedUserPrefix() {
    let stored = [
        MLXServerChatMessage.system("You are concise.").transcriptFingerprint,
        MLXServerChatMessage.user("Hello").transcriptFingerprint
    ]
    let request = [
        MLXServerChatMessage.system("You are concise.").transcriptFingerprint,
        MLXServerChatMessage.user("Different").transcriptFingerprint,
        MLXServerChatMessage.user("Continue").transcriptFingerprint
    ]

    #expect(
        MLXServerChatSessionTranscript.continuationSuffixStartIndex(
            stored: stored,
            request: request
        ) == nil
    )
}

@Test
func diskKVCacheEvictsLeastRecentlyUsedSessionEntries() throws {
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
    let firstKey = testChatSessionCacheKey(sessionKey: "session-a")
    let secondKey = testChatSessionCacheKey(sessionKey: "session-b")

    let firstTarget = try #require(try store.preparePersistenceTarget(for: firstKey))
    try Data(repeating: 1, count: 32).write(to: firstTarget.temporaryURL)
    try store.commitPersistedSession(
        key: firstKey,
        toolsSignature: "none",
        contextSignature: "none",
        fingerprints: [testFingerprint("first")],
        target: firstTarget
    )

    let secondTarget = try #require(try store.preparePersistenceTarget(for: secondKey))
    try Data(repeating: 2, count: 32).write(to: secondTarget.temporaryURL)
    try store.commitPersistedSession(
        key: secondKey,
        toolsSignature: "none",
        contextSignature: "none",
        fingerprints: [testFingerprint("second")],
        target: secondTarget
    )

    #expect(!FileManager.default.fileExists(atPath: firstTarget.cacheURL.path))
    #expect(!FileManager.default.fileExists(atPath: firstTarget.metadataURL.path))
    #expect(FileManager.default.fileExists(atPath: secondTarget.cacheURL.path))
    #expect(FileManager.default.fileExists(atPath: secondTarget.metadataURL.path))
}

@Test
func diskKVCacheSkipsPersistenceForUnchangedSessionTranscript() throws {
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
    let key = testChatSessionCacheKey(sessionKey: "session-a")
    let fingerprints = [testFingerprint("first")]

    let target = try #require(try store.preparePersistenceTarget(for: key))
    try Data(repeating: 1, count: 16).write(to: target.temporaryURL)
    try store.commitPersistedSession(
        key: key,
        toolsSignature: "none",
        contextSignature: "none",
        fingerprints: fingerprints,
        target: target
    )

    #expect(!store.needsPersistence(for: key, fingerprints: fingerprints))
    #expect(store.needsPersistence(for: key, fingerprints: fingerprints + [testFingerprint("second")]))
    #expect(store.needsPersistence(for: testChatSessionCacheKey(sessionKey: "other"), fingerprints: fingerprints))
}

@Test
func diskKVCacheCommitPersistsContextTokenCount() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mlx-server-context-tokens-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let store = MLXServerDiskKVCacheStore(
        configuration: MLXServerDiskKVCacheConfiguration(
            directory: directory,
            limitBytes: 1_000_000
        )
    )
    let key = testChatSessionCacheKey(sessionKey: "session-a")
    let target = try #require(try store.preparePersistenceTarget(for: key))
    try Data(repeating: 1, count: 16).write(to: target.temporaryURL)

    try store.commitPersistedSession(
        key: key,
        toolsSignature: "none",
        contextSignature: "none",
        fingerprints: [testFingerprint("first")],
        contextTokenCount: 42,
        target: target
    )

    let metadata = try JSONDecoder().decode(
        MLXServerPersistedChatSessionMetadata.self,
        from: Data(contentsOf: target.metadataURL)
    )
    #expect(metadata.contextTokenCount == 42)
}

@Test
func diskKVCacheCommitOverwritesSameSessionEntry() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mlx-server-overwrite-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let store = MLXServerDiskKVCacheStore(
        configuration: MLXServerDiskKVCacheConfiguration(
            directory: directory,
            limitBytes: 1_000_000
        )
    )
    let key = testChatSessionCacheKey(sessionKey: "session-a")

    let firstTarget = try #require(try store.preparePersistenceTarget(for: key))
    try Data(repeating: 1, count: 16).write(to: firstTarget.temporaryURL)
    try store.commitPersistedSession(
        key: key,
        toolsSignature: "none",
        contextSignature: "none",
        fingerprints: [testFingerprint("first")],
        target: firstTarget
    )

    let secondTarget = try #require(try store.preparePersistenceTarget(for: key))
    try Data(repeating: 2, count: 32).write(to: secondTarget.temporaryURL)
    try store.commitPersistedSession(
        key: key,
        toolsSignature: "none",
        contextSignature: "none",
        fingerprints: [testFingerprint("first"), testFingerprint("second")],
        target: secondTarget
    )

    #expect(firstTarget.cacheURL == secondTarget.cacheURL)
    let attributes = try FileManager.default.attributesOfItem(atPath: firstTarget.cacheURL.path)
    #expect((attributes[.size] as? NSNumber)?.intValue == 32)
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
    let key = testChatSessionCacheKey(sessionKey: "session-a")

    let target = try #require(try store.preparePersistenceTarget(for: key))
    try Data(repeating: 1, count: 16).write(to: target.temporaryURL)
    try store.commitPersistedSession(
        key: key,
        toolsSignature: "none",
        contextSignature: "none",
        fingerprints: [testFingerprint("first")],
        target: target
    )

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

    // A fresh store (e.g. after a server restart) enumerates disk entries
    // and must clean orphan payloads up.
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
func chatSessionAdditionalContextSignatureIsStableAcrossDictionaryOrder() {
    let first: [String: any Sendable] = [
        "b": 2,
        "a": true
    ]
    let second: [String: any Sendable] = [
        "a": true,
        "b": 2
    ]

    #expect(
        MLXServerChatSessionRequestSignature.additionalContext(first)
            == MLXServerChatSessionRequestSignature.additionalContext(second)
    )
}

@Test
func diskKVCachePersistenceWriterDoesNotBlockEnqueueBehindRunningJob() {
    let writer = MLXServerDiskKVCachePersistenceWriter()
    let firstStarted = DispatchSemaphore(value: 0)
    let releaseFirst = AsyncTestSemaphore()
    let secondStarted = DispatchSemaphore(value: 0)
    let enqueueReturned = DispatchSemaphore(value: 0)

    writer.enqueue(coalescingKey: "first") {
        firstStarted.signal()
        await releaseFirst.wait()
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
    let releaseFirst = AsyncTestSemaphore()
    let replacementFinished = DispatchSemaphore(value: 0)
    let recorder = DiskKVCacheWriterExecutionRecorder()

    writer.enqueue(coalescingKey: "blocking") {
        firstStarted.signal()
        await releaseFirst.wait()
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
func diskKVCachePersistenceWriterRunsPendingJobsWithDistinctKeys() {
    let writer = MLXServerDiskKVCachePersistenceWriter()
    let firstStarted = DispatchSemaphore(value: 0)
    let releaseFirst = AsyncTestSemaphore()
    let bothFinished = DispatchSemaphore(value: 0)
    let recorder = DiskKVCacheWriterExecutionRecorder()

    writer.enqueue(coalescingKey: "blocking") {
        firstStarted.signal()
        await releaseFirst.wait()
    }
    #expect(firstStarted.wait(timeout: .now() + .seconds(2)) == .success)

    // Pending persists for different sessions on the same model must not
    // replace each other.
    writer.enqueue(coalescingKey: "session-a") {
        recorder.record("session-a")
    }
    writer.enqueue(coalescingKey: "session-b") {
        recorder.record("session-b")
        bothFinished.signal()
    }

    releaseFirst.signal()
    #expect(bothFinished.wait(timeout: .now() + .seconds(2)) == .success)
    #expect(recorder.values == ["session-a", "session-b"])
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

private func testChatSessionCacheKey(
    sessionKey: String,
    modelID: String = "mlx-community/test-a",
    runtimeKind: MLXServerModelRuntimeKind = .llm,
    layout: String = "standard"
) -> MLXServerChatSessionCacheKey {
    MLXServerChatSessionCacheKey(
        sessionKey: sessionKey,
        modelID: modelID,
        runtimeKind: runtimeKind,
        cacheLayoutSignature: layout
    )
}

private func testFingerprint(_ text: String) -> MLXServerChatTranscriptFingerprint {
    MLXServerChatMessage.user(text).transcriptFingerprint
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

/// Async-friendly semaphore for blocking persistence-writer jobs in tests.
private final class AsyncTestSemaphore: @unchecked Sendable {
    private let lock = NSLock()
    private var signalCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        lock.lock()
        if waiters.isEmpty {
            signalCount += 1
            lock.unlock()
            return
        }
        let waiter = waiters.removeFirst()
        lock.unlock()
        waiter.resume()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if signalCount > 0 {
                signalCount -= 1
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
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
