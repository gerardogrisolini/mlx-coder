//
//  MLXServerModelSetupRunner.swift
//  mlx-server
//

import Foundation
import HuggingFace
import MLXServerCore

public enum MLXServerModelSetupRunner {
    public static let option = "--setup-models"
    private static let recommendedContextWindow = 65_536
    private static let interactiveLineReader = MLXServerSetupInteractiveLineReader()

    public static func shouldRunSetup(arguments: [String]) -> Bool {
        arguments.contains(option)
    }

    public static func argumentsAfterRemovingSetup(arguments: [String]) -> [String] {
        arguments.filter { $0 != option }
    }

    @MainActor
    public static func run(arguments: [String], configureRetentionPolicy: Bool = true) async throws {
        _ = arguments
        guard supportsInteractiveInput() else {
            throw MLXServerModelSetupError.nonInteractiveTerminal
        }

        let modelsURL = MLXServerModelsManifestStore.modelsURL()
        FileHandle.standardError.writeString(
            """
            mlx-server models setup
            Configuring models.json at:
            \(modelsURL.path)

            """
        )

        if configureRetentionPolicy {
            try configureModelRetentionPolicy()
        }
        try await MLXServerHuggingFaceCachePermissionRequester.ensureAccessIfNeeded()

        var manifest = MLXServerModelsManifest()
        let modelsFileExists = FileManager.default.fileExists(atPath: modelsURL.path)
        if modelsFileExists {
            do {
                manifest = try MLXServerModelsManifestStore.loadRequired(from: modelsURL)
                refreshExistingModelRuntimeKinds(in: &manifest)
                printExistingModels(manifest)
                try reconfigureExistingModelsIfRequested(in: &manifest)
            } catch {
                let shouldOverwrite = try promptYesNo(
                    "models.json exists but is invalid. Rewrite it?",
                    defaultValue: true
                )
                guard shouldOverwrite else {
                    throw error
                }
            }
        }

        try importCachedModelsIfRequested(into: &manifest)

        let shouldConfigureRemoteModel = try promptYesNo(
            "Search and download more models from Hugging Face?",
            defaultValue: manifest.models.isEmpty
        )
        if shouldConfigureRemoteModel {
            repeat {
                let configuredModel = try await configureRemoteModel()
                upsert(record: configuredModel.record, in: &manifest)
                try updateDefaultModel(
                    afterAdding: configuredModel.record,
                    in: &manifest
                )
            } while try promptYesNo("Add another model?", defaultValue: false)
        }

        try selectDefaultModelIfRequested(in: &manifest)
        try MLXServerModelsManifestStore.save(manifest, to: modelsURL)
        FileHandle.standardError.writeString("Updated: models.json\n")
        try syncActiveAgentIntegrationsWithDefaultModel(from: manifest)
        FileHandle.standardError.writeString("\nModels setup completed.\n\n")
    }

    private static func configureModelRetentionPolicy() throws {
        let settingsURL = MLXServerSettingsStore.settingsURL()
        let settingsExists = FileManager.default.fileExists(atPath: settingsURL.path)
        var settings = settingsExists
            ? try MLXServerSettingsStore.loadRequired(from: settingsURL)
            : MLXServerSettings()

        settings.loadOneModelAtATime = try promptYesNo(
            "Should the server load only one model at a time?",
            defaultValue: settings.loadOneModelAtATime
        )

        try MLXServerSettingsStore.save(settings, to: settingsURL)
        FileHandle.standardError.writeString("Updated: settings.json\n\n")
    }

    private static func refreshExistingModelRuntimeKinds(in manifest: inout MLXServerModelsManifest) {
        let candidates = MLXServerCachedModelScanner.candidates(
            cache: MLXServerHuggingFaceCacheAccessStore.cache
        )
        for modelIndex in manifest.models.indices {
            let repositoryID = manifest.models[modelIndex].repositoryID
            let revision = manifest.models[modelIndex].revision
            guard let candidate = candidates.first(where: {
                $0.repositoryID == repositoryID && $0.revision == revision
            }) else {
                continue
            }
            manifest.models[modelIndex].runtimeKind = inferredRuntimeKind(from: candidate)
        }
    }

    private static func reconfigureExistingModelsIfRequested(
        in manifest: inout MLXServerModelsManifest
    ) throws {
        guard !manifest.models.isEmpty else {
            return
        }
        guard try promptYesNo(
            "Reconfigure parameters for already configured models?",
            defaultValue: false
        ) else {
            return
        }

        let candidates = MLXServerCachedModelScanner.candidates(
            cache: MLXServerHuggingFaceCacheAccessStore.cache
        )
        let existingModels = manifest.models
        for model in existingModels {
            let updatedModel = try reconfigureExistingModel(
                model,
                cachedCandidate: cachedCandidate(for: model, in: candidates)
            )
            replaceExistingModel(
                oldID: model.id,
                with: updatedModel,
                in: &manifest
            )
        }
    }

    private static func importCachedModelsIfRequested(into manifest: inout MLXServerModelsManifest) throws {
        let candidates = MLXServerCachedModelScanner.candidates(
            cache: MLXServerHuggingFaceCacheAccessStore.cache
        )
        guard !candidates.isEmpty else {
            return
        }
        let importableCandidates = candidates.filter { candidate in
            !manifest.models.contains { model in
                model.repositoryID == candidate.repositoryID
                    && model.revision == candidate.revision
            }
        }
        guard !importableCandidates.isEmpty else {
            FileHandle.standardError.writeString(
                "Downloaded models are already configured in models.json.\n\n"
            )
            return
        }

        FileHandle.standardError.writeString(
            """
            Found downloaded models in the Hugging Face cache that are not configured yet:

            """
        )
        for (index, candidate) in importableCandidates.enumerated() {
            FileHandle.standardError.writeString(
                "\(index + 1). \(candidate.repositoryID) [\(candidate.revision)]\n"
            )
        }
        FileHandle.standardError.writeString("\n")

        guard try promptYesNo(
            "Import them into models.json?",
            defaultValue: true
        ) else {
            return
        }

        for candidate in importableCandidates {
            guard try promptYesNo(
                "Import \(candidate.repositoryID)?",
                defaultValue: true
            ) else {
                continue
            }
            let configuredModel = try configureCachedModel(candidate)
            upsert(record: configuredModel.record, in: &manifest)
            try updateDefaultModel(
                afterAdding: configuredModel.record,
                in: &manifest
            )
        }
    }

    private static func configureRemoteModel() async throws -> ConfiguredModelRecord {
        let client = MLXServerHuggingFaceCacheAccessStore.hubClient()
        let selectedModel = try await selectHuggingFaceModel(client: client)
        let repositoryID = selectedModel.id.rawValue
        let revision = selectedModel.sha ?? "main"

        FileHandle.standardError.writeString("\nDownloading \(repositoryID) [\(revision)]...\n")
        let snapshotURL = try await client.downloadSnapshot(
            of: selectedModel.id,
            revision: revision,
            progressHandler: { progress in
                Self.printDownloadProgress(progress)
            }
        )
        FileHandle.standardError.writeString("\nDownload completed: \(snapshotURL.path)\n")

        return try configureModelRecord(
            repositoryID: repositoryID,
            revision: revision,
            snapshotURL: snapshotURL,
            defaultRuntimeKind: inferredRuntimeKind(
                fromSnapshot: snapshotURL,
                fallback: inferredRuntimeKind(from: selectedModel)
            )
        )
    }

    private static func configureCachedModel(
        _ candidate: MLXServerCachedModelCandidate
    ) throws -> ConfiguredModelRecord {
        try configureModelRecord(
            repositoryID: candidate.repositoryID,
            revision: candidate.revision,
            snapshotURL: candidate.snapshotURL,
            defaultRuntimeKind: inferredRuntimeKind(from: candidate)
        )
    }

    private static func reconfigureExistingModel(
        _ model: MLXServerModelRecord,
        cachedCandidate: MLXServerCachedModelCandidate?
    ) throws -> MLXServerModelRecord {
        let importedDefaults = cachedCandidate.map {
            MLXServerModelParameterImporter.importDefaults(from: $0.snapshotURL)
        } ?? .init()
        let modelContextLimit = importedDefaults.contextWindow
        let fallbackDefaults = setupDefaults(
            from: importedDefaults,
            modelContextLimit: modelContextLimit
        )
        let effectiveDefaults = generationDefaults(
            model.generationDefaults,
            fallingBackTo: fallbackDefaults
        )
        let detectedThinking = cachedCandidate.map {
            MLXServerModelParameterImporter.importThinking(
                from: $0.snapshotURL,
                repositoryID: model.repositoryID
            )
        }?.validated() ?? model.thinking.validated()
        let runtimeKind = cachedCandidate.map { inferredRuntimeKind(from: $0) } ?? model.runtimeKind
        let thinkingLabel = cachedCandidate == nil ? "Current thinking" : "Detected thinking"

        FileHandle.standardError.writeString(
            """

            Configured model: \(model.id)
            Repository: \(model.repositoryID)
            Model context limit: \(contextLimitSummary(modelContextLimit))
            Current parameters: \(generationDefaultsSummary(effectiveDefaults))
            \(thinkingLabel): \(thinkingSummary(detectedThinking))

            """
        )

        guard try promptYesNo(
            "Edit this model's parameters?",
            defaultValue: false
        ) else {
            return model
        }

        let id = try promptString(
            "Model ID exposed by the server",
            defaultValue: model.id,
            allowEmpty: false
        )
        let generationDefaults = try configureGenerationDefaults(
            effectiveDefaults,
            modelContextLimit: modelContextLimit
        )

        return try MLXServerModelRecord(
            id: id,
            displayName: repositoryDisplayName(model.repositoryID),
            repositoryID: model.repositoryID,
            revision: model.revision,
            runtimeKind: runtimeKind,
            enabled: model.enabled,
            generationDefaults: generationDefaults,
            thinking: detectedThinking
        ).validated()
    }

    private static func configureModelRecord(
        repositoryID: String,
        revision: String,
        snapshotURL: URL,
        defaultRuntimeKind: MLXServerModelRuntimeKind
    ) throws -> ConfiguredModelRecord {
        let importedDefaults = MLXServerModelParameterImporter.importDefaults(from: snapshotURL)
        let modelContextLimit = importedDefaults.contextWindow
        let proposedDefaults = setupDefaults(
            from: importedDefaults,
            modelContextLimit: modelContextLimit
        )
        let importedThinking = MLXServerModelParameterImporter.importThinking(
            from: snapshotURL,
            repositoryID: repositoryID
        ).validated()

        FileHandle.standardError.writeString(
            """

            Model: \(repositoryID)
            Model context limit: \(contextLimitSummary(modelContextLimit))
            Proposed parameters: \(generationDefaultsSummary(proposedDefaults))
            Detected thinking: \(thinkingSummary(importedThinking))

            """
        )

        let shouldConfigureParameters = try promptYesNo(
            "Edit this model's parameters?",
            defaultValue: false
        )

        let id: String
        let generationDefaults: MLXServerModelGenerationDefaults
        if shouldConfigureParameters {
            id = try promptString(
                "Model ID exposed by the server",
                defaultValue: repositoryID,
                allowEmpty: false
            )
            generationDefaults = try configureGenerationDefaults(
                proposedDefaults,
                modelContextLimit: modelContextLimit
            )
        } else {
            id = repositoryID
            generationDefaults = proposedDefaults.validated()
        }

        let record = try MLXServerModelRecord(
            id: id,
            displayName: repositoryDisplayName(repositoryID),
            repositoryID: repositoryID,
            revision: revision,
            runtimeKind: defaultRuntimeKind,
            enabled: true,
            generationDefaults: generationDefaults,
            thinking: importedThinking
        ).validated()

        return ConfiguredModelRecord(
            record: record
        )
    }

    private static func configureGenerationDefaults(
        _ defaults: MLXServerModelGenerationDefaults,
        modelContextLimit: Int?
    ) throws -> MLXServerModelGenerationDefaults {
        let contextPrompt = [
            "Context window",
            "(model limit: \(contextLimitSummary(modelContextLimit)); recommended: \(recommendedContextWindow))"
        ].joined(separator: " ")
        let contextWindow = try promptInt(
            contextPrompt,
            defaultValue: defaults.contextWindow ?? defaultContextWindow(modelContextLimit: modelContextLimit),
            allowedRange: contextWindowAllowedRange(modelContextLimit: modelContextLimit)
        )
        let maxOutputTokens = try promptInt(
            "max_output_tokens",
            defaultValue: defaults.maxOutputTokens ?? 32_768,
            allowedRange: 1...Int.max
        )
        let temperature = try promptFloat(
            "Temperature",
            defaultValue: defaults.temperature ?? 0.6,
            allowedRange: 0...Float.greatestFiniteMagnitude
        )
        let topP = try promptFloat(
            "top_p",
            defaultValue: defaults.topP ?? 1.0,
            allowedRange: 0...1
        )
        let topK = try promptInt(
            "top_k",
            defaultValue: defaults.topK ?? 0,
            allowedRange: 0...Int.max
        )
        let repetitionPenalty = try promptFloat(
            "repetition_penalty",
            defaultValue: defaults.repetitionPenalty ?? 1.0,
            allowedRange: 0...Float.greatestFiniteMagnitude
        )
        let presencePenalty = try promptFloat(
            "presence_penalty",
            defaultValue: defaults.presencePenalty ?? 0,
            allowedRange: -2...2
        )
        let frequencyPenalty = try promptFloat(
            "frequency_penalty",
            defaultValue: defaults.frequencyPenalty ?? 0,
            allowedRange: -2...2
        )
        let prefillStepSize = try promptInt(
            "prefill_step_size",
            defaultValue: defaults.prefillStepSize ?? MLXServerModelGenerationDefaults.defaultPrefillStepSize,
            allowedRange: 1...Int.max
        )

        return MLXServerModelGenerationDefaults(
            contextWindow: contextWindow,
            maxOutputTokens: maxOutputTokens,
            temperature: temperature,
            topP: topP,
            topK: topK,
            repetitionPenalty: repetitionPenalty,
            presencePenalty: presencePenalty,
            frequencyPenalty: frequencyPenalty,
            prefillStepSize: prefillStepSize
        )
    }

    private static func setupDefaults(
        from importedDefaults: MLXServerModelGenerationDefaults,
        modelContextLimit: Int?
    ) -> MLXServerModelGenerationDefaults {
        MLXServerModelGenerationDefaults(
            contextWindow: defaultContextWindow(modelContextLimit: modelContextLimit),
            maxOutputTokens: importedDefaults.maxOutputTokens,
            temperature: importedDefaults.temperature,
            topP: importedDefaults.topP,
            topK: importedDefaults.topK,
            repetitionPenalty: importedDefaults.repetitionPenalty,
            presencePenalty: importedDefaults.presencePenalty,
            frequencyPenalty: importedDefaults.frequencyPenalty,
            prefillStepSize: importedDefaults.prefillStepSize
                ?? MLXServerModelGenerationDefaults.defaultPrefillStepSize
        ).validated()
    }

    private static func defaultContextWindow(modelContextLimit: Int?) -> Int {
        guard let modelContextLimit else {
            return recommendedContextWindow
        }
        return min(recommendedContextWindow, max(1, modelContextLimit))
    }

    private static func contextLimitSummary(_ modelContextLimit: Int?) -> String {
        modelContextLimit.map(String.init) ?? "not detected"
    }

    private static func contextWindowAllowedRange(modelContextLimit: Int?) -> ClosedRange<Int> {
        let upperBound = modelContextLimit.map { max(1, $0) } ?? Int.max
        return 1...upperBound
    }

    private static func generationDefaults(
        _ preferred: MLXServerModelGenerationDefaults,
        fallingBackTo fallback: MLXServerModelGenerationDefaults
    ) -> MLXServerModelGenerationDefaults {
        MLXServerModelGenerationDefaults(
            contextWindow: preferred.contextWindow ?? fallback.contextWindow,
            maxOutputTokens: preferred.maxOutputTokens ?? fallback.maxOutputTokens,
            temperature: preferred.temperature ?? fallback.temperature,
            topP: preferred.topP ?? fallback.topP,
            topK: preferred.topK ?? fallback.topK,
            repetitionPenalty: preferred.repetitionPenalty ?? fallback.repetitionPenalty,
            presencePenalty: preferred.presencePenalty ?? fallback.presencePenalty,
            frequencyPenalty: preferred.frequencyPenalty ?? fallback.frequencyPenalty,
            prefillStepSize: preferred.prefillStepSize ?? fallback.prefillStepSize
        ).validated()
    }

    private static func generationDefaultsSummary(
        _ defaults: MLXServerModelGenerationDefaults
    ) -> String {
        let values = [
            defaults.contextWindow.map { "context=\($0)" },
            defaults.maxOutputTokens.map { "max_output_tokens=\($0)" },
            defaults.temperature.map { "temperature=\(formatFloat($0))" },
            defaults.topP.map { "top_p=\(formatFloat($0))" },
            defaults.topK.map { "top_k=\($0)" },
            defaults.repetitionPenalty.map { "repetition_penalty=\(formatFloat($0))" },
            defaults.presencePenalty.map { "presence_penalty=\(formatFloat($0))" },
            defaults.frequencyPenalty.map { "frequency_penalty=\(formatFloat($0))" },
            defaults.prefillStepSize.map { "prefill_step_size=\($0)" }
        ].compactMap { $0 }

        return values.isEmpty ? "default runtime" : values.joined(separator: ", ")
    }

    private static func thinkingSummary(
        _ thinking: MLXServerModelThinkingConfiguration
    ) -> String {
        let normalized = thinking.validated()
        guard normalized.supportsThinking else {
            return "off"
        }

        var parts = ["default=\(normalized.defaultSelection.rawValue)"]
        if normalized.supportsReasoningEffort {
            let levels = MLXServerModelThinkingConfiguration
                .normalizedEffortLevels(from: normalized.availableSelections)
                .map(\.rawValue)
                .joined(separator: ", ")
            parts.append("levels=\(levels)")
        } else {
            parts.append("mode=on/off")
        }
        if normalized.supportsPreserveThinking {
            parts.append("preserve=true")
        }
        return parts.joined(separator: ", ")
    }

    private static func selectHuggingFaceModel(client: HubClient) async throws -> Model {
        while true {
            let query = try promptString(
                "Hugging Face MLX search",
                defaultValue: nil,
                allowEmpty: true
            ).trimmedNonEmpty

            let models: [Model]
            do {
                models = try await searchHuggingFaceModels(
                    client: client,
                    query: query
                )
            } catch {
                FileHandle.standardError.writeString(
                    "Hugging Face search failed: \(describeHuggingFaceError(error))\n"
                )
                FileHandle.standardError.writeString("Try a different search.\n")
                continue
            }

            guard !models.isEmpty else {
                FileHandle.standardError.writeString("No MLX model found.\n")
                continue
            }

            FileHandle.standardError.writeString("\n")
            for (index, model) in models.enumerated() {
                let downloads = model.downloads.map { "\($0) download" } ?? "download n/a"
                let likes = model.likes.map { "\($0) like" } ?? "like n/a"
                FileHandle.standardError.writeString(
                    "\(index + 1). \(model.id.rawValue) - \(downloads), \(likes)\n"
                )
            }

            let selection = try promptInt(
                "Select model",
                defaultValue: 1,
                allowedRange: 1...models.count
            )
            return models[selection - 1]
        }
    }

    private static func searchHuggingFaceModels(
        client: HubClient,
        query: String?
    ) async throws -> [Model] {
        let response = try await client.listModels(
            search: query,
            filter: "mlx",
            sort: "downloads",
            direction: .descending,
            limit: 10,
            full: true
        )
        return response.items.filter(isUsableMLXModel)
    }

    private static func describeHuggingFaceError(_ error: Error) -> String {
        if let error = error as? HTTPClientError {
            return error.description
        }
        return error.localizedDescription
    }

    private static func printDownloadProgress(_ progress: Progress) {
        let fraction = progress.fractionCompleted.isFinite
            ? min(max(progress.fractionCompleted, 0), 1)
            : 0
        let percent = Int((fraction * 100).rounded(.down))
        let completed = max(progress.completedUnitCount, 0)
        let total = max(progress.totalUnitCount, 0)
        let sizeDetail = total > 1
            ? " \(formatBytes(completed)) / \(formatBytes(total))"
            : ""
        FileHandle.standardError.writeString("\rDownload: \(percent)%\(sizeDetail)")
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: bytes,
            countStyle: .file
        )
    }

    private static func isUsableMLXModel(_ model: Model) -> Bool {
        let tags = model.tags ?? []
        let hasMLXTag = tags.contains { $0.localizedCaseInsensitiveContains("mlx") }
        let hasModelFiles = model.siblings?.contains { sibling in
            let filename = sibling.relativeFilename.lowercased()
            return filename == "config.json"
                || filename.hasSuffix(".safetensors")
                || filename.hasSuffix(".gguf")
        } ?? true
        return hasMLXTag && hasModelFiles && model.isDisabled != true
    }

    private static func inferredRuntimeKind(from model: Model) -> MLXServerModelRuntimeKind {
        let searchable = ((model.tags ?? []) + [model.pipelineTag, model.library].compactMap { $0 })
            .joined(separator: " ")
            .lowercased()
        if searchable.contains("vision")
            || searchable.contains("image")
            || searchable.contains("vlm") {
            return .vlm
        }
        return .llm
    }

    private static func inferredRuntimeKind(from candidate: MLXServerCachedModelCandidate) -> MLXServerModelRuntimeKind {
        inferredRuntimeKind(
            fromSnapshot: candidate.snapshotURL,
            fallback: inferredRuntimeKind(fromRepositoryID: candidate.repositoryID)
        )
    }

    private static func inferredRuntimeKind(
        fromSnapshot snapshotURL: URL,
        fallback: MLXServerModelRuntimeKind
    ) -> MLXServerModelRuntimeKind {
        if let probe = decodeRuntimeKindProbe(from: snapshotURL),
           let preferredRuntimeKind = probe.preferredTextRuntimeKind {
            return preferredRuntimeKind
        }

        if hasVisionProcessorFiles(in: snapshotURL) {
            return .vlm
        }

        return fallback
    }

    private static func inferredRuntimeKind(fromRepositoryID repositoryID: String) -> MLXServerModelRuntimeKind {
        let searchable = repositoryID.lowercased()
        if searchable.contains("vision")
            || searchable.contains("image")
            || searchable.contains("vlm") {
            return .vlm
        }
        return .llm
    }

    private static func decodeRuntimeKindProbe(from snapshotURL: URL) -> ModelRuntimeKindProbe? {
        let configURL = snapshotURL.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL) else {
            return nil
        }
        return try? JSONDecoder().decode(ModelRuntimeKindProbe.self, from: data)
    }

    private static func cachedCandidate(
        for model: MLXServerModelRecord,
        in candidates: [MLXServerCachedModelCandidate]
    ) -> MLXServerCachedModelCandidate? {
        candidates.first {
            $0.repositoryID == model.repositoryID && $0.revision == model.revision
        } ?? candidates.first {
            $0.repositoryID == model.repositoryID
        }
    }

    private static func hasVisionProcessorFiles(in snapshotURL: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: snapshotURL.appendingPathComponent("preprocessor_config.json").path
        )
            || FileManager.default.fileExists(
                atPath: snapshotURL.appendingPathComponent("image_processor_config.json").path
            )
            || FileManager.default.fileExists(
                atPath: snapshotURL.appendingPathComponent("processor_config.json").path
            )
    }

    private static func upsert(
        record: MLXServerModelRecord,
        in manifest: inout MLXServerModelsManifest
    ) {
        if let index = manifest.models.firstIndex(where: { $0.id == record.id }) {
            manifest.models[index] = record
        } else {
            manifest.models.append(record)
        }
    }

    private static func replaceExistingModel(
        oldID: String,
        with record: MLXServerModelRecord,
        in manifest: inout MLXServerModelsManifest
    ) {
        let wasDefault = manifest.defaultModelID == oldID
        if let replacementIndex = manifest.models.firstIndex(where: { $0.id == oldID }) {
            manifest.models[replacementIndex] = record
            let duplicateIndices = manifest.models.indices.reversed().filter {
                $0 != replacementIndex && manifest.models[$0].id == record.id
            }
            for index in duplicateIndices {
                manifest.models.remove(at: index)
            }
        } else {
            upsert(record: record, in: &manifest)
        }
        if wasDefault {
            manifest.defaultModelID = record.id
        }
    }

    private static func updateDefaultModel(
        afterAdding record: MLXServerModelRecord,
        in manifest: inout MLXServerModelsManifest
    ) throws {
        if manifest.defaultModelID == nil || manifest.models.count == 1 {
            manifest.defaultModelID = record.id
        }
    }

    private static func selectDefaultModelIfRequested(
        in manifest: inout MLXServerModelsManifest
    ) throws {
        let enabledModels = manifest.models.filter(\.enabled)
        guard !enabledModels.isEmpty else {
            return
        }

        let currentDefaultModel = enabledModels.first { $0.id == manifest.defaultModelID }
            ?? enabledModels[0]
        manifest.defaultModelID = currentDefaultModel.id

        guard enabledModels.count > 1 else {
            return
        }

        FileHandle.standardError.writeString("\nEnabled models:\n")
        for (index, model) in enabledModels.enumerated() {
            let marker = model.id == currentDefaultModel.id ? " *" : ""
            FileHandle.standardError.writeString("\(index + 1). \(model.id)\(marker)\n")
        }
        FileHandle.standardError.writeString("\n")

        guard try promptYesNo(
            "Change default model?",
            defaultValue: false
        ) else {
            return
        }

        while true {
            let answer = try promptString(
                "Default model",
                defaultValue: currentDefaultModel.id,
                allowEmpty: false
            )
            if let index = Int(answer),
               enabledModels.indices.contains(index - 1) {
                manifest.defaultModelID = enabledModels[index - 1].id
                return
            }
            if let model = enabledModels.first(where: { $0.id == answer }) {
                manifest.defaultModelID = model.id
                return
            }
            FileHandle.standardError.writeString("Invalid model selection.\n")
        }
    }

    private static func syncActiveAgentIntegrationsWithDefaultModel(
        from manifest: MLXServerModelsManifest
    ) throws {
        let validated = try manifest.validated()
        let enabledModels = validated.models.filter(\.enabled)
        guard let defaultModel = enabledModels.first(where: { $0.id == validated.defaultModelID }) else {
            return
        }

        let status = MLXServerAgentIntegrationService.status()
        guard status.codexCLIEnabled
            || status.codexAppEnabled
            || status.codexXcodeAppEnabled
            || status.xcodeClaudeCodeEnabled else {
            return
        }

        let configuration = MLXServerAgentIntegrationConfiguration(
            baseURL: MLXServerAgentIntegrationService.defaultServerBaseURL(),
            modelID: defaultModel.id,
            contextWindow: defaultModel.generationDefaults.contextWindow,
            apiKey: MLXServerSettingsStore.loadOrDefault().apiKey
        )

        if status.codexCLIEnabled {
            try MLXServerAgentIntegrationService.configureCodexCLIProfile(
                configuration: configuration
            )
        }
        if status.codexAppEnabled {
            try MLXServerAgentIntegrationService.configureCodexAppProfile(
                target: .desktop,
                configuration: configuration
            )
        }
        if status.codexXcodeAppEnabled {
            try MLXServerAgentIntegrationService.configureCodexAppProfile(
                target: .xcode,
                configuration: configuration
            )
        }
        if status.xcodeClaudeCodeEnabled {
            try MLXServerAgentIntegrationService.configureXcodeClaudeCode(
                configuration: configuration
            )
        }

        FileHandle.standardError.writeString("Updated active agent integrations.\n")
    }

    private static func printExistingModels(_ manifest: MLXServerModelsManifest) {
        guard !manifest.models.isEmpty else {
            return
        }
        FileHandle.standardError.writeString("Configured models:\n")
        for model in manifest.models {
            let marker = model.id == manifest.defaultModelID ? "*" : " "
            FileHandle.standardError.writeString("\(marker) \(model.id) -> \(model.repositoryID)\n")
        }
        FileHandle.standardError.writeString("\n")
    }

    private static func promptString(
        _ prompt: String,
        defaultValue: String?,
        allowEmpty: Bool
    ) throws -> String {
        while true {
            let suffix = defaultValue.map { " [\($0)]" } ?? ""
            guard let line = interactiveLineReader.readLine(prompt: "\(prompt)\(suffix): ") else {
                throw MLXServerModelSetupError.inputClosed
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty, let defaultValue {
                return defaultValue
            }
            if trimmed.isEmpty, allowEmpty {
                return ""
            }
            if !trimmed.isEmpty {
                return trimmed
            }
        }
    }

    private static func promptInt(
        _ prompt: String,
        defaultValue: Int,
        allowedRange: ClosedRange<Int>
    ) throws -> Int {
        while true {
            let value = try promptString(
                prompt,
                defaultValue: String(defaultValue),
                allowEmpty: false
            )
            guard let parsed = Int(value), allowedRange.contains(parsed) else {
                FileHandle.standardError.writeString("Invalid value.\n")
                continue
            }
            return parsed
        }
    }

    private static func promptFloat(
        _ prompt: String,
        defaultValue: Float,
        allowedRange: ClosedRange<Float>
    ) throws -> Float {
        while true {
            let value = try promptString(
                prompt,
                defaultValue: formatFloat(defaultValue),
                allowEmpty: false
            )
            guard let parsed = Float(value.replacingOccurrences(of: ",", with: ".")),
                  allowedRange.contains(parsed) else {
                FileHandle.standardError.writeString("Invalid value.\n")
                continue
            }
            return parsed
        }
    }

    private static func formatFloat(_ value: Float) -> String {
        String(format: "%.4g", Double(value))
    }

    private static func promptYesNo(
        _ prompt: String,
        defaultValue: Bool
    ) throws -> Bool {
        let defaultLabel = defaultValue ? "Y/n" : "y/N"
        while true {
            guard let line = interactiveLineReader.readLine(prompt: "\(prompt) [\(defaultLabel)]: ") else {
                throw MLXServerModelSetupError.inputClosed
            }
            let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.isEmpty {
                return defaultValue
            }
            if ["y", "yes"].contains(normalized) {
                return true
            }
            if ["n", "no"].contains(normalized) {
                return false
            }
        }
    }

    private static func supportsInteractiveInput() -> Bool {
        MLXServerSetupInteractiveLineReader.supportsInteractiveInput()
    }
}

private func repositoryDisplayName(_ repositoryID: String) -> String {
    repositoryID.split(separator: "/", maxSplits: 1).last.map(String.init) ?? repositoryID
}

enum MLXServerModelSetupError: LocalizedError {
    case nonInteractiveTerminal
    case inputClosed

    var errorDescription: String? {
        switch self {
        case .nonInteractiveTerminal:
            return "mlx-server --setup-models requires an interactive terminal."
        case .inputClosed:
            return "Input closed during mlx-server model setup."
        }
    }
}

private struct ConfiguredModelRecord: Sendable {
    var record: MLXServerModelRecord
}

private struct MLXServerCachedModelCandidate: Sendable {
    var repositoryID: String
    var revision: String
    var snapshotURL: URL

    var displayName: String {
        repositoryID.split(separator: "/", maxSplits: 1).last.map(String.init) ?? repositoryID
    }
}

private enum MLXServerCachedModelScanner {
    static func candidates(
        cache: HubCache = MLXServerHuggingFaceCacheAccessStore.cache,
        fileManager: FileManager = .default
    ) -> [MLXServerCachedModelCandidate] {
        guard let repositoryDirectories = try? fileManager.contentsOfDirectory(
            at: cache.cacheDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return repositoryDirectories
            .filter { isDirectory($0, fileManager: fileManager) }
            .flatMap { repositoryDirectory in
                candidates(
                    in: repositoryDirectory,
                    fileManager: fileManager
                )
            }
            .sorted {
                $0.repositoryID.localizedStandardCompare($1.repositoryID) == .orderedAscending
            }
    }

    private static func candidates(
        in repositoryDirectory: URL,
        fileManager: FileManager
    ) -> [MLXServerCachedModelCandidate] {
        guard let repositoryID = repositoryID(fromCacheDirectoryName: repositoryDirectory.lastPathComponent) else {
            return []
        }

        let snapshotsDirectory = repositoryDirectory.appendingPathComponent("snapshots", isDirectory: true)
        guard let snapshotDirectories = try? fileManager.contentsOfDirectory(
            at: snapshotsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return snapshotDirectories
            .filter { isDirectory($0, fileManager: fileManager) }
            .filter { isUsableSnapshot($0, fileManager: fileManager) }
            .map {
                MLXServerCachedModelCandidate(
                    repositoryID: repositoryID,
                    revision: $0.lastPathComponent,
                    snapshotURL: $0
                )
            }
    }

    private static func repositoryID(fromCacheDirectoryName name: String) -> String? {
        guard name.hasPrefix("models--") else {
            return nil
        }

        let encodedRepositoryID = String(name.dropFirst("models--".count))
        let components = encodedRepositoryID.split(separator: "--", omittingEmptySubsequences: false)
        guard components.count >= 2 else {
            return nil
        }

        let namespace = components[0]
        let repositoryName = components.dropFirst().joined(separator: "--")
        guard !namespace.isEmpty, !repositoryName.isEmpty else {
            return nil
        }
        return "\(namespace)/\(repositoryName)"
    }

    private static func isUsableSnapshot(
        _ snapshotURL: URL,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.fileExists(
            atPath: snapshotURL.appendingPathComponent("config.json").path
        ) else {
            return false
        }

        guard let enumerator = fileManager.enumerator(
            at: snapshotURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        for case let fileURL as URL in enumerator {
            let filename = fileURL.lastPathComponent.lowercased()
            if filename.hasSuffix(".safetensors")
                || filename.hasSuffix(".gguf")
                || filename == "model.safetensors.index.json" {
                return true
            }
        }
        return false
    }

    private static func isDirectory(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

private enum MLXServerModelParameterImporter {
    static func importDefaults(from snapshotURL: URL) -> MLXServerModelGenerationDefaults {
        let config = decode(ModelConfigProbe.self, from: snapshotURL.appendingPathComponent("config.json"))
        let generationConfig = decode(
            GenerationConfigProbe.self,
            from: snapshotURL.appendingPathComponent("generation_config.json")
        )

        return MLXServerModelGenerationDefaults(
            contextWindow: config?.contextWindow,
            maxOutputTokens: generationConfig?.maxOutputTokensValue,
            temperature: generationConfig?.temperature,
            topP: generationConfig?.topP,
            topK: generationConfig?.topK,
            repetitionPenalty: generationConfig?.repetitionPenalty,
            presencePenalty: generationConfig?.presencePenalty,
            frequencyPenalty: generationConfig?.frequencyPenalty,
            prefillStepSize: MLXServerModelGenerationDefaults.defaultPrefillStepSize
        )
    }

    static func importThinking(
        from snapshotURL: URL,
        repositoryID: String
    ) -> MLXServerModelThinkingConfiguration {
        var detector = ModelThinkingMetadataDetector()
        detector.scan(repositoryID)

        for filename in ["config.json", "generation_config.json", "tokenizer_config.json"] {
            let fileURL = snapshotURL.appendingPathComponent(filename)
            if let value = decode(ModelMetadataValue.self, from: fileURL) {
                detector.scan(value)
            }
        }

        let templateURL = snapshotURL.appendingPathComponent("chat_template.jinja")
        if let data = try? Data(contentsOf: templateURL),
           let template = String(data: data, encoding: .utf8) {
            detector.scan(template)
        }

        return detector.configuration.validated()
    }

    private static func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }
}

private enum ModelMetadataValue: Decodable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ModelMetadataValue])
    case object([String: ModelMetadataValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([ModelMetadataValue].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: ModelMetadataValue].self))
        }
    }
}

private struct ModelThinkingMetadataDetector {
    var supportsThinking = false
    var supportsReasoningEffort = false
    var supportsPreserveThinking = false
    var effortLevels: [MLXServerThinkingSelection] = []

    var configuration: MLXServerModelThinkingConfiguration {
        guard supportsThinking else {
            return .disabled
        }
        if supportsReasoningEffort {
            return .effort(
                levels: effortLevels,
                supportsPreserveThinking: supportsPreserveThinking
            )
        }
        return MLXServerModelThinkingConfiguration(
            supportsThinking: true,
            supportsReasoningEffort: false,
            supportsPreserveThinking: supportsPreserveThinking,
            availableSelections: [.off, .enabled],
            defaultSelection: .enabled
        )
    }

    mutating func scan(_ value: ModelMetadataValue, keyPath: [String] = []) {
        switch value {
        case .null:
            return
        case .bool(let bool):
            if bool, keyPath.contains(where: isThinkingKey) {
                supportsThinking = true
            }
            if bool, keyPath.contains(where: isEffortKey) {
                supportsThinking = true
                supportsReasoningEffort = true
            }
            if bool, keyPath.contains(where: isPreserveThinkingKey) {
                supportsThinking = true
                supportsPreserveThinking = true
            }
        case .number(let number):
            if number != 0, keyPath.contains(where: isThinkingKey) {
                supportsThinking = true
            }
        case .string(let string):
            scan(string, keyPath: keyPath)
        case .array(let array):
            for item in array {
                scan(item, keyPath: keyPath)
            }
        case .object(let object):
            for (key, nestedValue) in object {
                scanKey(key, value: nestedValue)
                scan(nestedValue, keyPath: keyPath + [key])
            }
        }
    }

    mutating func scan(_ text: String, keyPath: [String] = []) {
        if keyPath.contains(where: isEffortKey) {
            supportsThinking = true
            supportsReasoningEffort = true
            appendEffortLevel(from: text)
        }

        if keyPath.contains(where: isThinkingKey), isTruthy(text) {
            supportsThinking = true
        }

        if containsEnableThinkingReference(text) || isKnownThinkingModelIdentifier(text) {
            supportsThinking = true
        }

        if containsPreserveThinkingReference(text) || isKnownPreserveThinkingModelIdentifier(text) {
            supportsThinking = true
            supportsPreserveThinking = true
        }

        appendEffortLevel(from: text)
    }

    private mutating func scanKey(_ key: String, value: ModelMetadataValue) {
        if isThinkingKey(key), value.isTruthy {
            supportsThinking = true
        }

        if isEffortKey(key), value.isTruthy {
            supportsThinking = true
            supportsReasoningEffort = true
            appendEffortLevels(from: value)
        }

        if isPreserveThinkingKey(key), value.isTruthy {
            supportsThinking = true
            supportsPreserveThinking = true
        }

        let normalizedKey = normalizedToken(key)
        if normalizedKey == "chattemplate",
           case .string(let template) = value {
            if containsEnableThinkingReference(template) {
                supportsThinking = true
            }
            if containsPreserveThinkingReference(template) {
                supportsThinking = true
                supportsPreserveThinking = true
            }
        }
    }

    private mutating func appendEffortLevels(from value: ModelMetadataValue) {
        switch value {
        case .string(let string):
            appendEffortLevel(from: string)
        case .array(let array):
            for item in array {
                appendEffortLevels(from: item)
            }
        case .object(let object):
            for nestedValue in object.values {
                appendEffortLevels(from: nestedValue)
            }
        case .bool(let bool):
            if bool {
                supportsReasoningEffort = true
            }
        case .number, .null:
            return
        }
    }

    private mutating func appendEffortLevel(from value: String) {
        guard let selection = MLXServerThinkingSelection(protocolValue: value),
              selection.isEffortLevel,
              !effortLevels.contains(selection) else {
            return
        }
        supportsThinking = true
        supportsReasoningEffort = true
        effortLevels.append(selection)
    }

    private func isThinkingKey(_ key: String) -> Bool {
        let normalizedKey = normalizedToken(key)
        return normalizedKey == "reasoning"
            || normalizedKey == "thinking"
            || normalizedKey == "enablethinking"
            || normalizedKey == "reasoningcontent"
            || normalizedKey == "reasoningdetails"
    }

    private func isEffortKey(_ key: String) -> Bool {
        let normalizedKey = normalizedToken(key)
        return normalizedKey == "effort"
            || normalizedKey == "efforts"
            || normalizedKey == "reasoningeffort"
            || normalizedKey == "reasoningefforts"
            || normalizedKey == "thinkingeffort"
            || normalizedKey == "thinkingefforts"
            || normalizedKey == "effortlevels"
            || normalizedKey == "reasoningeffortlevels"
            || normalizedKey == "thinkinglevels"
    }

    private func isPreserveThinkingKey(_ key: String) -> Bool {
        normalizedToken(key) == "preservethinking"
    }

    private func containsEnableThinkingReference(_ value: String) -> Bool {
        normalizedToken(value).contains("enablethinking")
    }

    private func containsPreserveThinkingReference(_ value: String) -> Bool {
        normalizedToken(value).contains("preservethinking")
    }

    private func isKnownThinkingModelIdentifier(_ value: String) -> Bool {
        let normalizedValue = normalizedToken(value)
        return normalizedValue.contains("qwen3")
            || normalizedValue.contains("qwq")
            || normalizedValue.contains("reasoning")
            || normalizedValue.contains("thinking")
            || normalizedValue.contains("deepseekr1")
            || normalizedValue.contains("gptoss")
    }

    private func isKnownPreserveThinkingModelIdentifier(_ value: String) -> Bool {
        let normalizedValue = normalizedToken(value)
        return normalizedValue.contains("qwen36")
    }

    private func isTruthy(_ value: String) -> Bool {
        let normalizedValue = normalizedToken(value)
        return normalizedValue == "true"
            || normalizedValue == "enabled"
            || normalizedValue == "supported"
            || normalizedValue == "yes"
            || normalizedValue == "1"
            || normalizedValue.contains("reasoning")
            || normalizedValue.contains("thinking")
            || normalizedValue.contains("enablethinking")
    }

    private func normalizedToken(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: " ", with: "")
    }
}

private extension ModelMetadataValue {
    var isTruthy: Bool {
        switch self {
        case .null:
            false
        case .bool(let bool):
            bool
        case .number(let number):
            number != 0
        case .string(let string):
            !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .array(let array):
            !array.isEmpty
        case .object(let object):
            !object.isEmpty
        }
    }
}

private struct ModelRuntimeKindProbe: Decodable {
    var modelType: String?
    var architectures: [String]?
    var textConfig: Nested?

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case architectures
        case textConfig = "text_config"
    }

    var preferredTextRuntimeKind: MLXServerModelRuntimeKind? {
        for modelType in normalizedModelTypes {
            if Self.llmTextRuntimeModelTypes.contains(modelType) {
                return .llm
            }
        }

        for modelType in normalizedModelTypes {
            if Self.vlmOnlyModelTypes.contains(modelType) {
                return .vlm
            }
        }

        let architectureText = (architectures ?? [])
            .joined(separator: " ")
            .lowercased()
        if architectureText.contains("vision")
            || architectureText.contains("vlm")
            || architectureText.contains("llava") {
            return .vlm
        }

        return nil
    }

    private var normalizedModelTypes: [String] {
        [modelType, textConfig?.modelType]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private static let llmTextRuntimeModelTypes: Set<String> = [
        "qwen3_5",
        "qwen3_5_moe",
        "gemma3",
        "gemma3n",
        "gemma4"
    ]

    private static let vlmOnlyModelTypes: Set<String> = [
        "fastvlm",
        "glm_ocr",
        "idefics3",
        "lfm2-vl",
        "lfm2_vl",
        "llava_qwen2",
        "mistral3",
        "paligemma",
        "pixtral",
        "qwen2_5_vl",
        "qwen2_vl",
        "qwen3_vl",
        "smolvlm"
    ]

    struct Nested: Decodable {
        var modelType: String?

        enum CodingKeys: String, CodingKey {
            case modelType = "model_type"
        }
    }
}

private struct GenerationConfigProbe: Decodable {
    var maxNewTokens: Int?
    var maxOutputTokens: Int?
    var temperature: Float?
    var topP: Float?
    var topK: Int?
    var repetitionPenalty: Float?
    var presencePenalty: Float?
    var frequencyPenalty: Float?

    enum CodingKeys: String, CodingKey {
        case maxNewTokens = "max_new_tokens"
        case maxOutputTokens = "max_output_tokens"
        case temperature
        case topP = "top_p"
        case topK = "top_k"
        case repetitionPenalty = "repetition_penalty"
        case presencePenalty = "presence_penalty"
        case frequencyPenalty = "frequency_penalty"
    }

    var maxOutputTokensValue: Int? {
        maxOutputTokens ?? maxNewTokens
    }
}

private struct ModelConfigProbe: Decodable {
    var maxPositionEmbeddings: Int?
    var maxContextLength: Int?
    var contextLength: Int?
    var modelMaxLength: Int?
    var maxSequenceLength: Int?
    var maxSequenceLen: Int?
    var textConfig: Nested?

    enum CodingKeys: String, CodingKey {
        case maxPositionEmbeddings = "max_position_embeddings"
        case maxContextLength = "max_context_length"
        case contextLength = "context_length"
        case modelMaxLength = "model_max_length"
        case maxSequenceLength = "max_sequence_length"
        case maxSequenceLen = "max_sequence_len"
        case textConfig = "text_config"
    }

    var contextWindow: Int? {
        [
            maxContextLength,
            contextLength,
            modelMaxLength,
            maxSequenceLength,
            maxSequenceLen,
            maxPositionEmbeddings,
            textConfig?.contextWindow
        ]
        .compactMap { $0 }
        .max()
    }

    struct Nested: Decodable {
        var maxPositionEmbeddings: Int?
        var maxContextLength: Int?
        var contextLength: Int?
        var modelMaxLength: Int?

        enum CodingKeys: String, CodingKey {
            case maxPositionEmbeddings = "max_position_embeddings"
            case maxContextLength = "max_context_length"
            case contextLength = "context_length"
            case modelMaxLength = "model_max_length"
        }

        var contextWindow: Int? {
            [
                maxContextLength,
                contextLength,
                modelMaxLength,
                maxPositionEmbeddings
            ]
            .compactMap { $0 }
            .max()
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension FileHandle {
    func writeString(_ string: String) {
        try? write(contentsOf: Data(string.utf8))
    }
}
